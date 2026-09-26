import Foundation
import Network

/// Bonjour advertise + browse (NetService), TCP catalog exchange (Network.framework).
@MainActor
public final class LanSyncService: ObservableObject {
    public nonisolated static let serviceType = "_mdstickies._tcp"
    /// NetService wants a trailing dot on the type.
    public nonisolated static let netServiceType = "_mdstickies._tcp."

    public let peerID: UUID
    public private(set) var deviceName: String
    public let bonjourName: String

    @Published public private(set) var isAdvertising = false
    @Published public private(set) var lastStatus: String?
    @Published public private(set) var isSyncing = false

    public var catalogProvider: (() -> [SyncNotePayload])?
    public var onInboundCatalog: (([SyncNotePayload]) -> Void)?

    private var listener: NWListener?
    private var publishedPort: NWEndpoint.Port?
    private var netService: NetService?
    private var browserDelegate: BrowseDelegate?
    private var permissionBrowser: NWBrowser?

    public init(peerID: UUID? = nil, deviceName: String) {
        let id = peerID ?? Self.loadOrCreatePeerID()
        self.peerID = id
        self.deviceName = deviceName
        self.bonjourName = "MS-\(id.uuidString.prefix(8))"
    }

    public func setStatus(_ status: String?) {
        lastStatus = status
    }

    /// Updates the human-readable device label (Bonjour TXT + sync hello / `created_on`).
    public func updateDeviceName(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != deviceName else { return }
        deviceName = trimmed
        if isAdvertising {
            republishNetServiceIfNeeded()
        }
        objectWillChange.send()
    }

    nonisolated public static func loadOrCreatePeerID(defaults: UserDefaults = .standard, key: String = "lanSyncPeerID") -> UUID {
        if let raw = defaults.string(forKey: key), let id = UUID(uuidString: raw) {
            return id
        }
        let id = UUID()
        defaults.set(id.uuidString, forKey: key)
        return id
    }

    public func startAdvertising() {
        requestLocalNetworkAuthorization()
        guard listener == nil else {
            republishNetServiceIfNeeded()
            return
        }

        do {
            let parameters = NWParameters.tcp
            parameters.includePeerToPeer = true
            let listener = try NWListener(using: parameters)
            // Bonjour is published via NetService once we know the port (more reliable than NWListener.Service).

            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        self.publishedPort = listener.port
                        self.publishNetService(port: listener.port)
                        self.isAdvertising = true
                        self.lastStatus = "Discoverable on LAN (\(self.bonjourName))"
                    case .failed(let error):
                        self.isAdvertising = false
                        self.lastStatus = "Advertise failed: \(error.localizedDescription)"
                        self.tearDownListener()
                    case .cancelled:
                        self.isAdvertising = false
                    default:
                        break
                    }
                }
            }

            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in
                    await self?.handleInbound(connection)
                }
            }

            listener.start(queue: .global(qos: .userInitiated))
            self.listener = listener
        } catch {
            lastStatus = "Could not advertise: \(error.localizedDescription)"
        }
    }

    public func stopAdvertising() {
        tearDownListener()
    }

    private func tearDownListener() {
        netService?.stop()
        netService = nil
        listener?.cancel()
        listener = nil
        publishedPort = nil
        isAdvertising = false
    }

    private func republishNetServiceIfNeeded() {
        if let port = publishedPort ?? listener?.port {
            publishNetService(port: port)
        }
    }

    private func publishNetService(port: NWEndpoint.Port?) {
        guard let port else { return }
        netService?.stop()

        let service = NetService(
            domain: "local.",
            type: Self.netServiceType,
            name: bonjourName,
            port: Int32(port.rawValue)
        )
        service.setTXTRecord(
            NetService.data(fromTXTRecord: [
                "id": Data(peerID.uuidString.utf8),
                "name": Data(String(deviceName.prefix(48)).utf8),
            ])
        )
        service.publish()
        netService = service
    }

    /// Browse for a peer, connect, exchange catalogs.
    /// Press Sync on **one** device; the other only needs to be open + discoverable.
    public func syncWithPeer(timeoutSeconds: TimeInterval = 20) async throws -> [SyncNotePayload] {
        guard !isSyncing else { throw SyncProtocolError.connectionFailed("Sync already in progress.") }
        isSyncing = true
        lastStatus = "Looking for peer…"
        defer {
            isSyncing = false
            browserDelegate?.stop()
            browserDelegate = nil
        }

        startAdvertising()
        // Give our listener + peer Bonjour a moment before browsing.
        try? await Task.sleep(nanoseconds: 800_000_000)

        let endpoint: NWEndpoint
        do {
            endpoint = try await browseForPeer(timeoutSeconds: timeoutSeconds)
        } catch {
            lastStatus = Self.friendlyNetworkError(error)
            throw error
        }

        lastStatus = "Connecting…"
        let localNotes = catalogProvider?() ?? []
        do {
            let remote = try await exchangeAsClient(endpoint: endpoint, localNotes: localNotes)
            lastStatus = "Received \(remote.count) note(s) from peer (applied on this device)"
            return remote
        } catch {
            lastStatus = Self.friendlyNetworkError(error)
            throw error
        }
    }

    public func requestLocalNetworkAuthorization() {
        permissionBrowser?.cancel()
        let parameters = NWParameters()
        parameters.includePeerToPeer = true
        let descriptor = NWBrowser.Descriptor.bonjour(type: Self.serviceType, domain: "local.")
        let browser = NWBrowser(for: descriptor, using: parameters)
        permissionBrowser = browser
        browser.stateUpdateHandler = { _ in }
        browser.browseResultsChangedHandler = { _, _ in }
        browser.start(queue: .global(qos: .utility))
        DispatchQueue.global().asyncAfter(deadline: .now() + 2.0) { [weak self] in
            browser.cancel()
            Task { @MainActor in
                if self?.permissionBrowser === browser {
                    self?.permissionBrowser = nil
                }
            }
        }
    }

    public static func friendlyNetworkError(_ error: Error) -> String {
        let text = error.localizedDescription
        let ns = error as NSError
        if text.localizedCaseInsensitiveContains("noauth")
            || text.contains("-65555")
            || ns.code == -65555 {
            return "Local Network access denied. Enable Markdown Stickies under Settings → Privacy → Local Network (iPhone and Mac). Reinstall if the toggle is missing."
        }
        if case SyncProtocolError.peerNotFound = error {
            return "No peer found. Same Wi‑Fi, both apps open, Mac Sync folder on, iOS folder picked. Allow Local Network. Tap Sync on only one side."
        }
        if case SyncProtocolError.timedOut = error {
            return "Connection timed out. Try Sync again from one device only."
        }
        return text
    }

    // MARK: - Browse (NetService)

    private func browseForPeer(timeoutSeconds: TimeInterval) async throws -> NWEndpoint {
        try await withCheckedThrowingContinuation { continuation in
            let delegate = BrowseDelegate(
                ourBonjourName: bonjourName,
                ourPeerID: peerID,
                onStatus: { [weak self] text in
                    Task { @MainActor in self?.lastStatus = text }
                },
                onFound: { endpoint in
                    continuation.resume(returning: endpoint)
                },
                onFailed: { error in
                    continuation.resume(throwing: error)
                }
            )
            self.browserDelegate = delegate
            delegate.start(timeoutSeconds: timeoutSeconds)
        }
    }

    // MARK: - Connections

    private func exchangeAsClient(endpoint: NWEndpoint, localNotes: [SyncNotePayload]) async throws -> [SyncNotePayload] {
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        // Avoid racing happy-eyeballs forever on flaky .local DNS.
        parameters.expiredDNSBehavior = .allow
        let connection = NWConnection(to: endpoint, using: parameters)
        defer { connection.cancel() }

        try await startAndWaitReady(connection, timeoutSeconds: 10) { [weak self] text in
            Task { @MainActor in self?.lastStatus = text }
        }
        lastStatus = "Exchanging notes…"
        return try await receiveCatalogExchange(
            connection: connection,
            localNotes: localNotes,
            asServer: false
        )
    }

    private func startAndWaitReady(
        _ connection: NWConnection,
        timeoutSeconds: TimeInterval,
        onProgress: ((String) -> Void)? = nil
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var resumed = false
            let finish: (Result<Void, Error>) -> Void = { result in
                guard !resumed else { return }
                resumed = true
                continuation.resume(with: result)
            }

            connection.stateUpdateHandler = { state in
                switch state {
                case .setup:
                    onProgress?("Connecting… (setup)")
                case .preparing:
                    onProgress?("Connecting… (preparing)")
                case .ready:
                    finish(.success(()))
                case .waiting(let error):
                    // Often the real failure mode on LAN (firewall / path / DNS).
                    onProgress?("Connecting… (\(error.localizedDescription))")
                case .failed(let error):
                    finish(.failure(SyncProtocolError.connectionFailed(error.localizedDescription)))
                case .cancelled:
                    finish(.failure(SyncProtocolError.connectionFailed("Cancelled")))
                default:
                    break
                }
            }

            connection.start(queue: .global(qos: .userInitiated))

            if case .ready = connection.state {
                finish(.success(()))
            }

            Task {
                try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                finish(.failure(SyncProtocolError.connectionFailed(
                    "TCP connect timed out. Is the other app open and Local Network allowed?"
                )))
            }
        }
    }

    private func handleInbound(_ connection: NWConnection) async {
        do {
            try await startAndWaitReady(connection, timeoutSeconds: 12)
            let remoteCatalog = try await receiveCatalogExchange(
                connection: connection,
                localNotes: catalogProvider?() ?? [],
                asServer: true
            )
            onInboundCatalog?(remoteCatalog)
            lastStatus = "Peer pushed \(remoteCatalog.count) note(s) — applied on this device"
        } catch {
            if !isSyncing {
                lastStatus = Self.friendlyNetworkError(error)
            }
        }
        connection.cancel()
    }

    private func receiveCatalogExchange(
        connection: NWConnection,
        localNotes: [SyncNotePayload],
        asServer: Bool
    ) async throws -> [SyncNotePayload] {
        // Shared across reads so coalesced TCP frames aren't dropped.
        var buffer = Data()

        if !asServer {
            lastStatus = "Exchanging notes… (sending)"
            try await send(SyncWireMessage.hello(peerID: peerID, deviceName: deviceName), on: connection)
            try await send(SyncWireMessage.catalog(localNotes), on: connection)
            lastStatus = "Exchanging notes… (waiting for peer)"
            let reply = try await receiveMessage(on: connection, buffer: &buffer, timeoutSeconds: 30)
            guard reply.kind == .catalog, let notes = reply.notes else {
                throw SyncProtocolError.unexpectedMessage(reply.kind)
            }
            return notes
        } else {
            let hello = try await receiveMessage(on: connection, buffer: &buffer, timeoutSeconds: 30)
            guard hello.kind == .hello else {
                throw SyncProtocolError.unexpectedMessage(hello.kind)
            }
            let incoming = try await receiveMessage(on: connection, buffer: &buffer, timeoutSeconds: 30)
            guard incoming.kind == .catalog, let remoteNotes = incoming.notes else {
                throw SyncProtocolError.unexpectedMessage(incoming.kind)
            }
            try await send(SyncWireMessage.catalog(localNotes), on: connection)
            return remoteNotes
        }
    }

    private func send(_ message: SyncWireMessage, on connection: NWConnection) async throws {
        let data = try SyncFrameCodec.encode(message)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: SyncProtocolError.connectionFailed(error.localizedDescription))
                } else {
                    continuation.resume()
                }
            })
        }
    }

    private func receiveMessage(
        on connection: NWConnection,
        buffer: inout Data,
        timeoutSeconds: TimeInterval
    ) async throws -> SyncWireMessage {
        let deadline = Date().addingTimeInterval(timeoutSeconds)

        while true {
            if let message = try SyncFrameCodec.decodeOne(&buffer) {
                return message
            }
            if Date() > deadline {
                throw SyncProtocolError.timedOut
            }

            let chunk: Data = try await withCheckedThrowingContinuation { continuation in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 1024 * 1024) { content, _, isComplete, error in
                    if let error {
                        continuation.resume(throwing: SyncProtocolError.connectionFailed(error.localizedDescription))
                        return
                    }
                    if let content, !content.isEmpty {
                        continuation.resume(returning: content)
                        return
                    }
                    if isComplete {
                        continuation.resume(throwing: SyncProtocolError.connectionFailed("Connection closed"))
                    } else {
                        continuation.resume(returning: Data())
                    }
                }
            }
            if chunk.isEmpty {
                try? await Task.sleep(nanoseconds: 50_000_000)
                continue
            }
            buffer.append(chunk)
        }
    }
}

// MARK: - NetService browser

private final class BrowseDelegate: NSObject, NetServiceBrowserDelegate, NetServiceDelegate {
    private let ourBonjourName: String
    private let ourPeerID: UUID
    private let onStatus: (String) -> Void
    private let onFound: (NWEndpoint) -> Void
    private let onFailed: (Error) -> Void

    private let browser = NetServiceBrowser()
    private var pending: [NetService] = []
    private var resolving: NetService?
    private var finished = false
    private var seenCount = 0
    private var timeoutItem: DispatchWorkItem?

    init(
        ourBonjourName: String,
        ourPeerID: UUID,
        onStatus: @escaping (String) -> Void,
        onFound: @escaping (NWEndpoint) -> Void,
        onFailed: @escaping (Error) -> Void
    ) {
        self.ourBonjourName = ourBonjourName
        self.ourPeerID = ourPeerID
        self.onStatus = onStatus
        self.onFound = onFound
        self.onFailed = onFailed
        super.init()
        browser.delegate = self
    }

    func start(timeoutSeconds: TimeInterval) {
        browser.includesPeerToPeer = true
        browser.searchForServices(ofType: LanSyncService.netServiceType, inDomain: "local.")
        onStatus("Looking for peer…")

        let work = DispatchWorkItem { [weak self] in
            self?.fail(SyncProtocolError.peerNotFound)
        }
        timeoutItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + timeoutSeconds, execute: work)
    }

    func stop() {
        timeoutItem?.cancel()
        browser.stop()
        resolving?.stop()
        resolving = nil
        pending.removeAll()
    }

    private func succeed(_ endpoint: NWEndpoint) {
        guard !finished else { return }
        finished = true
        stop()
        onFound(endpoint)
    }

    private func fail(_ error: Error) {
        guard !finished else { return }
        finished = true
        stop()
        if seenCount == 0 {
            onStatus("Looking for peer… (saw 0 services)")
        } else {
            onStatus("Looking for peer… (saw \(seenCount), none usable)")
        }
        onFailed(error)
    }

    private func isSelf(_ service: NetService) -> Bool {
        if service.name == ourBonjourName { return true }
        guard let data = service.txtRecordData() else { return false }
        let txt = NetService.dictionary(fromTXTRecord: data)
        guard let idData = txt["id"],
              let idString = String(data: idData, encoding: .utf8),
              let id = UUID(uuidString: idString)
        else { return false }
        return id == ourPeerID
    }

    private func enqueue(_ service: NetService) {
        guard !isSelf(service) else { return }
        if pending.contains(where: { $0.name == service.name }) { return }
        if resolving?.name == service.name { return }
        pending.append(service)
        resolveNextIfNeeded()
    }

    private func resolveNextIfNeeded() {
        guard !finished, resolving == nil else { return }
        guard !pending.isEmpty else { return }
        let service = pending.removeFirst()
        resolving = service
        service.delegate = self
        onStatus("Looking for peer… (resolving \(service.name))")
        service.resolve(withTimeout: 8)
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        seenCount += 1
        onStatus("Looking for peer… (saw \(seenCount))")
        enqueue(service)
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
        fail(SyncProtocolError.connectionFailed("Bonjour browse failed: \(errorDict)"))
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        resolving = nil
        if let endpoint = Self.preferredEndpoint(for: sender) {
            succeed(endpoint)
            return
        }
        // Bad address — try the next advertised peer instead of aborting.
        resolveNextIfNeeded()
        if resolving == nil, pending.isEmpty {
            // Keep browsing until the overall timeout; don't fail early.
            onStatus("Looking for peer… (resolve produced no address)")
        }
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        resolving = nil
        onStatus("Looking for peer… (resolve failed, trying next)")
        resolveNextIfNeeded()
    }

    /// Prefer IPv4 host:port; fall back to Bonjour service endpoint.
    private static func preferredEndpoint(for service: NetService) -> NWEndpoint? {
        if let ipv4 = ipv4Endpoint(for: service) {
            return ipv4
        }
        return NWEndpoint.service(
            name: service.name,
            type: "_mdstickies._tcp",
            domain: "local",
            interface: nil
        )
    }

    private static func ipv4Endpoint(for service: NetService) -> NWEndpoint? {
        guard let addresses = service.addresses, service.port > 0 else { return nil }
        let port = NWEndpoint.Port(rawValue: UInt16(service.port))!

        for address in addresses {
            var storage = sockaddr_storage()
            let boundSize = min(MemoryLayout<sockaddr_storage>.size, address.count)
            let copied: Bool = address.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return false }
                memcpy(&storage, base, boundSize)
                return true
            }
            guard copied else { continue }
            guard storage.ss_family == sa_family_t(AF_INET) else { continue }

            let ipv4: IPv4Address? = withUnsafePointer(to: &storage) { ptr in
                ptr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { sin in
                    var addr = sin.pointee.sin_addr
                    return withUnsafeBytes(of: &addr) { raw in
                        IPv4Address(Data(raw))
                    }
                }
            }
            guard let ipv4 else { continue }
            return NWEndpoint.hostPort(host: .ipv4(ipv4), port: port)
        }
        return nil
    }
}
