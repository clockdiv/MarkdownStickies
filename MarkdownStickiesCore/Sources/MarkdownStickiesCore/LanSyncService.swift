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
    /// Folders used for note-adjacent image discovery / apply (protocol ≥ 3).
    public var syncRootsProvider: (() -> [URL])?
    /// Apply a remote catalog and return which note IDs were written (for peer ACK).
    public var onApplyRemoteCatalog: (([SyncNotePayload], String?) -> SyncApplyAck)?
    /// Fired after a full exchange finishes (client or server), with honest feedback.
    public var onExchangeFinished: ((SyncExchangeResult, SyncExchangeRole) -> Void)?
    /// Live banner updates while a sync is in flight (client or inbound server).
    public var onProgress: ((SyncFeedback) -> Void)?
    /// Peer tapped OK on their sync result — clear our matching card.
    public var onRemoteBannerDismiss: (() -> Void)?
    /// Peer chose Sync Later / Later — abort merge UI on both sides.
    public var onRemoteMergeCancel: (() -> Void)?

    private var listener: NWListener?
    private var publishedPort: NWEndpoint.Port?
    private var netService: NetService?
    private var browserDelegate: BrowseDelegate?
    private var permissionBrowser: NWBrowser?
    private var progressStartedAt: Date?
    private var progressTimeoutSeconds: Int?
    private var progressTitle = "Syncing"
    private var inboundActive = false

    public init(peerID: UUID? = nil, deviceName: String) {
        let id = peerID ?? Self.loadOrCreatePeerID()
        self.peerID = id
        self.deviceName = deviceName
        self.bonjourName = "MS-\(id.uuidString.prefix(8))"
    }

    public func setStatus(_ status: String?) {
        lastStatus = status
    }

    /// Fire-and-forget: tell the peer to drop their sync result card (OK on this device).
    /// Must never touch the progress UI — a prior bug left Mac stuck on “Found peer…”.
    public func notifyPeerDismissBanner() {
        Task { await sendQuietWireMessage(SyncWireMessage.dismissBanner()) }
    }

    /// Fire-and-forget: abort merge session on the peer (Sync Later / Later).
    public func notifyPeerCancelMerge() {
        Task { await sendQuietWireMessage(SyncWireMessage.cancelMerge()) }
    }

    /// Push a live progress card update (also updates `lastStatus`).
    /// Requires an active `beginProgressSession` — never invent a progress card from Bonjour chatter
    /// (that left OK→dismiss stuck on “Found peer…” forever).
    public func reportProgress(
        title: String? = nil,
        message: String,
        currentItem: String? = nil,
        peerName: String? = nil,
        debugCode: String = "sync:progress"
    ) {
        guard let started = progressStartedAt else {
            lastStatus = message
            return
        }
        if let title { progressTitle = title }
        let feedback = SyncFeedback.progress(
            title: progressTitle,
            message: message,
            startedAt: started,
            timeoutSeconds: progressTimeoutSeconds,
            currentItem: currentItem,
            peerName: peerName,
            debugCode: debugCode
        )
        lastStatus = feedback.statusLine
        onProgress?(feedback)
    }

    private func beginProgressSession(title: String, timeoutSeconds: Int?) {
        progressStartedAt = Date()
        progressTimeoutSeconds = timeoutSeconds
        progressTitle = title
    }

    private func endProgressSession() {
        progressStartedAt = nil
        progressTimeoutSeconds = nil
        progressTitle = "Syncing"
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

    /// Re-assert Bonjour presence (iOS often needs this after foregrounding).
    public func ensureAdvertisingFresh() {
        requestLocalNetworkAuthorization()
        if listener == nil {
            startAdvertising()
        } else {
            republishNetServiceIfNeeded()
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

    /// Browse for a peer, connect, exchange catalogs with apply ACKs.
    /// Press Sync on **one** device; the other only needs to be open + discoverable.
    /// Retries once if the peer does not confirm all expected outbound notes.
    public func syncWithPeer(timeoutSeconds: TimeInterval = 20) async throws -> SyncExchangeResult {
        guard !isSyncing else { throw SyncProtocolError.connectionFailed("Sync already in progress.") }
        isSyncing = true
        beginProgressSession(title: "Syncing", timeoutSeconds: Int(timeoutSeconds.rounded()))
        reportProgress(message: "Looking for peer…", debugCode: "sync:looking")
        defer {
            isSyncing = false
            browserDelegate?.stop()
            browserDelegate = nil
            endProgressSession()
        }

        startAdvertising()
        // Give our listener + peer Bonjour a moment before browsing.
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        reportProgress(message: "Looking for peer…", debugCode: "sync:looking")

        // Mac→iOS often misses the phone on the first browse (iOS advertises late after wake).
        // Retry a few times instead of failing on “saw only ourselves”.
        let endpoint: NWEndpoint
        do {
            endpoint = try await browseForPeerWithRetries(
                perAttemptTimeout: min(timeoutSeconds, 12),
                attempts: 3
            )
        } catch {
            lastStatus = Self.friendlyNetworkError(error)
            throw error
        }

        reportProgress(message: "Found peer — connecting…", debugCode: "sync:found")
        do {
            var result = try await exchangeAsClient(endpoint: endpoint)
            if !result.peerConfirmedOutbound, result.peerSupportsAck, !result.unconfirmedOutboundIDs.isEmpty {
                reportProgress(
                    message: "Peer missing \(result.unconfirmedOutboundIDs.count) note(s) — retrying…",
                    peerName: result.peerDeviceName,
                    debugCode: "sync:retry"
                )
                try? await Task.sleep(nanoseconds: 400_000_000)
                result = try await exchangeAsClient(endpoint: endpoint)
            }
            let feedback = SyncFeedback.from(
                result: result,
                role: .client,
                peerName: result.peerDeviceName
            )
            lastStatus = feedback.statusLine
            onExchangeFinished?(result, .client)
            return result
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
            return "No peer found. Keep both apps open in the foreground on the same Wi‑Fi, then try Sync again. (iPhone often needs a moment after opening before Mac can see it — Sync from iPhone also works.)"
        }
        if case SyncProtocolError.timedOut = error {
            return "Connection timed out. Try Sync again from one device only."
        }
        return text
    }

    // MARK: - Browse (NetService)

    private func browseForPeerWithRetries(
        perAttemptTimeout: TimeInterval,
        attempts: Int
    ) async throws -> NWEndpoint {
        var lastError: Error = SyncProtocolError.peerNotFound
        for attempt in 1...max(1, attempts) {
            if attempt > 1 {
                reportProgress(
                    message: "Still looking for peer…",
                    debugCode: "sync:looking-retry"
                )
                ensureAdvertisingFresh()
                try? await Task.sleep(nanoseconds: 900_000_000)
            }
            browserDelegate?.stop()
            browserDelegate = nil
            do {
                return try await browseForPeer(timeoutSeconds: perAttemptTimeout)
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    private func browseForPeer(
        timeoutSeconds: TimeInterval,
        reportStatus: Bool = true
    ) async throws -> NWEndpoint {
        try await withCheckedThrowingContinuation { continuation in
            let delegate = BrowseDelegate(
                ourBonjourName: bonjourName,
                ourPeerID: peerID,
                onStatus: { [weak self] text in
                    guard reportStatus else { return }
                    Task { @MainActor in
                        self?.reportProgress(message: text, debugCode: "sync:looking")
                    }
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

    private func exchangeAsClient(endpoint: NWEndpoint) async throws -> SyncExchangeResult {
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        // Avoid racing happy-eyeballs forever on flaky .local DNS.
        parameters.expiredDNSBehavior = .allow
        let connection = NWConnection(to: endpoint, using: parameters)
        defer { connection.cancel() }

        try await startAndWaitReady(connection, timeoutSeconds: 10) { [weak self] text in
            Task { @MainActor in
                self?.reportProgress(message: text, debugCode: "sync:connecting")
            }
        }
        reportProgress(message: "Exchanging notes…", debugCode: "sync:exchange")
        let localNotes = catalogProvider?() ?? []
        return try await receiveCatalogExchange(
            connection: connection,
            localNotes: localNotes
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
        // Don't interrupt an outbound sync's progress card with inbound noise.
        if isSyncing {
            connection.cancel()
            return
        }
        inboundActive = true
        var progressStarted = false
        defer {
            inboundActive = false
            if progressStarted { endProgressSession() }
            connection.cancel()
        }
        do {
            try await startAndWaitReady(connection, timeoutSeconds: 12)
            var buffer = Data()
            let hello = try await receiveMessage(on: connection, buffer: &buffer, timeoutSeconds: 30)
            guard hello.kind == .hello else {
                throw SyncProtocolError.unexpectedMessage(hello.kind)
            }
            let next = try await receiveMessage(on: connection, buffer: &buffer, timeoutSeconds: 45)
            if next.kind == .dismissBanner {
                onRemoteBannerDismiss?()
                return
            }
            if next.kind == .cancelMerge {
                onRemoteMergeCancel?()
                return
            }
            guard next.kind == .catalog, let remoteNotes = next.notes else {
                throw SyncProtocolError.unexpectedMessage(next.kind)
            }

            progressStarted = true
            beginProgressSession(title: "Sync requested", timeoutSeconds: 45)
            let peerName = hello.deviceName ?? next.deviceName
            reportProgress(
                title: "Sync requested",
                message: "Peer connected\(peerName.map { " — \($0)" } ?? "")",
                peerName: peerName,
                debugCode: "sync:inbound-hello"
            )
            let result = try await serveCatalogExchange(
                connection: connection,
                buffer: &buffer,
                localNotes: catalogProvider?() ?? [],
                remoteNotes: remoteNotes,
                hello: hello,
                peerName: peerName
            )
            let feedback = SyncFeedback.from(
                result: result,
                role: .server,
                peerName: result.peerDeviceName
            )
            lastStatus = feedback.statusLine
            onExchangeFinished?(result, .server)
        } catch {
            // Quiet dismiss connections should not surface as sync failures.
            if progressStarted {
                let message = Self.friendlyNetworkError(error)
                lastStatus = message
                onProgress?(
                    SyncFeedback(
                        kind: .failure,
                        title: "Sync failed",
                        message: message,
                        statusLine: "Sync failed — \(message)",
                        detail: String(describing: error),
                        debugCode: "sync:inbound-error",
                        receivedCount: 0,
                        sentConfirmedCount: 0,
                        sentExpectedCount: 0
                    )
                )
            }
        }
    }

    /// Silent control message → peer: no progress card, short browse, ignore failures.
    private func sendQuietWireMessage(_ message: SyncWireMessage) async {
        guard !isSyncing, !inboundActive else { return }
        // Don't steal the sync browser while a real exchange may start.
        if browserDelegate != nil { return }
        do {
            let endpoint = try await browseForPeer(timeoutSeconds: 3, reportStatus: false)
            browserDelegate?.stop()
            browserDelegate = nil
            let parameters = NWParameters.tcp
            parameters.includePeerToPeer = true
            parameters.expiredDNSBehavior = .allow
            let connection = NWConnection(to: endpoint, using: parameters)
            defer { connection.cancel() }
            try await startAndWaitReady(connection, timeoutSeconds: 4)
            guard !isSyncing else { return }
            try await send(SyncWireMessage.hello(peerID: peerID, deviceName: deviceName), on: connection)
            try await send(message, on: connection)
            try? await Task.sleep(nanoseconds: 120_000_000)
        } catch {
            browserDelegate?.stop()
            browserDelegate = nil
            // Peer offline / old build — local dismiss still stands.
        }
    }

    private func receiveCatalogExchange(
        connection: NWConnection,
        localNotes: [SyncNotePayload]
    ) async throws -> SyncExchangeResult {
        // Shared across reads so coalesced TCP frames aren't dropped.
        var buffer = Data()

        reportProgress(
            message: "Sending \(localNotes.count) note(s)…",
            debugCode: "sync:send-catalog"
        )
        try await send(SyncWireMessage.hello(peerID: peerID, deviceName: deviceName), on: connection)
        try await send(SyncWireMessage.catalog(localNotes, deviceName: deviceName), on: connection)
        reportProgress(
            message: "Waiting for peer catalog…",
            peerName: nil,
            debugCode: "sync:wait-catalog"
        )
        let reply = try await receiveMessage(on: connection, buffer: &buffer, timeoutSeconds: 45)
        guard reply.kind == .catalog, let remoteNotes = reply.notes else {
            throw SyncProtocolError.unexpectedMessage(reply.kind)
        }

        let peerAppliedIDs = reply.appliedIDs ?? []
        let peerSupportsAck = reply.appliedIDs != nil
        let peerVersion = reply.protocolVersion ?? 1
        let peerName = reply.deviceName

        reportProgress(
            message: "Receiving \(remoteNotes.count) note(s)…",
            peerName: peerName,
            debugCode: "sync:recv-catalog"
        )
        let localAck = applyRemote(remoteNotes, peerName: peerName)
        try await send(SyncWireMessage.applied(localAck.appliedIDs), on: connection)

        // Peer catalog is *after* they applied our notes — remaining = still missing there.
        let remainingOutbound = SyncMerge.outboundIDs(ours: localNotes, theirs: remoteNotes)
        var imagesReceived = 0
        var imagesSent = 0
        if peerVersion >= 3 {
            let images = try await exchangeAssets(
                connection: connection,
                buffer: &buffer,
                asServer: false
            )
            imagesReceived = images.received
            imagesSent = images.sent
        }

        return SyncExchangeResult(
            remoteNotes: remoteNotes,
            peerAppliedIDs: peerAppliedIDs,
            localAppliedIDs: localAck.appliedIDs,
            remainingOutboundIDs: remainingOutbound,
            peerSupportsAck: peerSupportsAck,
            peerDeviceName: peerName,
            imagesReceived: imagesReceived,
            imagesSent: imagesSent,
            conflicts: localAck.conflicts,
            awaitingAuthorityMerge: localAck.awaitingAuthorityMerge
        )
    }

    /// Server half after hello + catalog were already read (so dismissBanner can short-circuit first).
    private func serveCatalogExchange(
        connection: NWConnection,
        buffer: inout Data,
        localNotes: [SyncNotePayload],
        remoteNotes: [SyncNotePayload],
        hello: SyncWireMessage,
        peerName: String?
    ) async throws -> SyncExchangeResult {
        let clientSupportsAck = (hello.protocolVersion ?? 1) >= 2
        let clientSupportsAssets = (hello.protocolVersion ?? 1) >= 3

        reportProgress(
            title: "Syncing",
            message: "Receiving \(remoteNotes.count) note(s)…",
            peerName: peerName,
            debugCode: "sync:inbound-recv"
        )
        let serverAck = applyRemote(remoteNotes, peerName: peerName)
        let freshLocal = catalogProvider?() ?? localNotes

        reportProgress(
            title: "Syncing",
            message: "Sending \(freshLocal.count) note(s)…",
            peerName: peerName,
            debugCode: "sync:inbound-send"
        )
        try await send(
            SyncWireMessage.catalog(freshLocal, appliedIDs: serverAck.appliedIDs, deviceName: deviceName),
            on: connection
        )

        var clientAppliedIDs: [UUID] = []
        var peerSupportsAck = clientSupportsAck
        if clientSupportsAck {
            do {
                let clientAck = try await receiveMessage(on: connection, buffer: &buffer, timeoutSeconds: 20)
                if clientAck.kind == .applied {
                    clientAppliedIDs = clientAck.appliedIDs ?? []
                } else {
                    peerSupportsAck = false
                }
            } catch {
                peerSupportsAck = false
            }
        }

        let remainingOutbound: [UUID]
        if peerSupportsAck {
            let predicted = SyncMerge.outboundIDs(ours: freshLocal, theirs: remoteNotes)
            let acked = Set(clientAppliedIDs)
            remainingOutbound = predicted.filter { !acked.contains($0) }
        } else {
            remainingOutbound = SyncMerge.outboundIDs(ours: freshLocal, theirs: remoteNotes)
        }

        var imagesReceived = 0
        var imagesSent = 0
        if clientSupportsAssets {
            let images = try await exchangeAssets(
                connection: connection,
                buffer: &buffer,
                asServer: true
            )
            imagesReceived = images.received
            imagesSent = images.sent
        }

        return SyncExchangeResult(
            remoteNotes: remoteNotes,
            peerAppliedIDs: clientAppliedIDs,
            localAppliedIDs: serverAck.appliedIDs,
            remainingOutboundIDs: remainingOutbound,
            peerSupportsAck: peerSupportsAck,
            peerDeviceName: peerName,
            imagesReceived: imagesReceived,
            imagesSent: imagesSent,
            conflicts: serverAck.conflicts,
            awaitingAuthorityMerge: serverAck.awaitingAuthorityMerge
        )
    }

    private struct AssetExchangeCounts {
        var received: Int
        var sent: Int
    }

    /// Mutual offer lists, then client pushes images the server needs, then server pushes images the client needs.
    private func exchangeAssets(
        connection: NWConnection,
        buffer: inout Data,
        asServer: Bool
    ) async throws -> AssetExchangeCounts {
        let roots = syncRootsProvider?() ?? []
        reportProgress(message: "Exchanging images…", debugCode: "sync:images")
        let config = ScanConfig.load()
        let localOffers = SyncImageAssets.offers(roots: roots, config: config)

        if !asServer {
            try await send(SyncWireMessage.assetOffers(localOffers), on: connection)
            let reply = try await receiveMessage(on: connection, buffer: &buffer, timeoutSeconds: 45)
            guard reply.kind == .assetOffers else {
                throw SyncProtocolError.unexpectedMessage(reply.kind)
            }
            let remoteOffers = reply.assetOffers ?? []

            let peerNeeds = SyncImageAssets.missingOffers(theirs: localOffers, ours: remoteOffers)
            let sent = try await sendAssetBlobs(offers: peerNeeds, roots: roots, on: connection)
            let received = try await receiveAssetBlobs(on: connection, buffer: &buffer, roots: roots)
            return AssetExchangeCounts(received: received, sent: sent)
        } else {
            let incoming = try await receiveMessage(on: connection, buffer: &buffer, timeoutSeconds: 45)
            guard incoming.kind == .assetOffers else {
                throw SyncProtocolError.unexpectedMessage(incoming.kind)
            }
            let remoteOffers = incoming.assetOffers ?? []
            try await send(SyncWireMessage.assetOffers(localOffers), on: connection)

            let peerNeeds = SyncImageAssets.missingOffers(theirs: localOffers, ours: remoteOffers)
            let received = try await receiveAssetBlobs(on: connection, buffer: &buffer, roots: roots)
            let sent = try await sendAssetBlobs(offers: peerNeeds, roots: roots, on: connection)
            return AssetExchangeCounts(received: received, sent: sent)
        }
    }

    private func sendAssetBlobs(
        offers: [SyncAssetOffer],
        roots: [URL],
        on connection: NWConnection
    ) async throws -> Int {
        var sent = 0
        for offer in offers {
            guard let blob = SyncImageAssets.loadBlob(offer: offer, roots: roots) else { continue }
            reportProgress(
                message: "Sending image…",
                currentItem: offer.relativePath,
                debugCode: "sync:image-out"
            )
            try await send(SyncWireMessage.assetBlobs([blob]), on: connection)
            sent += 1
        }
        try await send(SyncWireMessage.assetBlobs([]), on: connection)
        return sent
    }

    private func receiveAssetBlobs(
        on connection: NWConnection,
        buffer: inout Data,
        roots: [URL]
    ) async throws -> Int {
        var received = 0
        while true {
            let message = try await receiveMessage(on: connection, buffer: &buffer, timeoutSeconds: 90)
            guard message.kind == .assetBlobs else {
                throw SyncProtocolError.unexpectedMessage(message.kind)
            }
            let blobs = message.assetBlobs ?? []
            if blobs.isEmpty { break }
            for blob in blobs {
                reportProgress(
                    message: "Receiving image…",
                    currentItem: blob.relativePath,
                    debugCode: "sync:image-in"
                )
                if (try? SyncImageAssets.applyBlob(blob, roots: roots)) != nil {
                    received += 1
                }
            }
        }
        return received
    }

    private func applyRemote(_ remote: [SyncNotePayload], peerName: String?) -> SyncApplyAck {
        guard let onApplyRemoteCatalog else { return .empty }
        if remote.isEmpty {
            reportProgress(
                message: "No new notes to apply",
                peerName: peerName,
                debugCode: "sync:apply-empty"
            )
            return onApplyRemoteCatalog(remote, peerName)
        }
        // Show each incoming title so the UI names what's landing.
        for note in remote {
            let label = note.title.trimmingCharacters(in: .whitespacesAndNewlines)
            reportProgress(
                message: "Receiving note…",
                currentItem: label.isEmpty ? "Untitled" : label,
                peerName: peerName,
                debugCode: "sync:note-in"
            )
        }
        return onApplyRemoteCatalog(remote, peerName)
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
    /// Other peers only — our own Bonjour name used to inflate “saw 1” and confuse Mac→iOS.
    private var foreignSeenCount = 0
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
        onStatus("Found peer…")
        stop()
        onFound(endpoint)
    }

    private func fail(_ error: Error) {
        guard !finished else { return }
        finished = true
        stop()
        if foreignSeenCount == 0 {
            onStatus("Looking for peer…")
        } else {
            onStatus("Peer seen — couldn’t connect")
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
        foreignSeenCount += 1
        pending.append(service)
        resolveNextIfNeeded()
    }

    private func resolveNextIfNeeded() {
        guard !finished, resolving == nil else { return }
        guard !pending.isEmpty else { return }
        let service = pending.removeFirst()
        resolving = service
        service.delegate = self
        onStatus("Found peer — resolving…")
        service.resolve(withTimeout: 8)
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        if isSelf(service) {
            // Ignore our own advertisement — it used to show as “saw 1” with no real peer.
            return
        }
        onStatus("Looking for peer…")
        enqueue(service)
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
        fail(SyncProtocolError.connectionFailed("Bonjour browse failed: \(errorDict)"))
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        resolving = nil
        succeed(
            Self.preferredEndpoint(for: sender)
                ?? NWEndpoint.service(
                    name: sender.name,
                    type: "_mdstickies._tcp",
                    domain: "local",
                    interface: nil
                )
        )
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        resolving = nil
        // iOS often fails address resolve while the Bonjour name still works for NWConnection.
        onStatus("Found peer — connecting…")
        succeed(
            NWEndpoint.service(
                name: sender.name,
                type: "_mdstickies._tcp",
                domain: "local",
                interface: nil
            )
        )
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
