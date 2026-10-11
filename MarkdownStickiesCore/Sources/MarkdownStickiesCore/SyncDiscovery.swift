import Foundation
import Network

/// A device found on the local network.
public struct SyncPeer: Hashable, Sendable {
    public var name: String
    public var deviceID: UUID?
    public var platform: SyncDevice
    public var endpoint: NWEndpoint
}

/// Advertises this device over Bonjour and hands every incoming connection to `onConnection`.
/// The TXT record carries the platform and device id, so a Mac only talks to iOS devices
/// and the other way round.
public final class SyncAdvertiser: @unchecked Sendable {
    private let name: String
    private let platform: SyncDevice
    private let deviceID: UUID
    private let onConnection: @Sendable (NWConnection) -> Void
    private let queue = DispatchQueue(label: "MarkdownStickies.sync.advertiser")
    private var listener: NWListener?

    public init(
        name: String,
        platform: SyncDevice,
        deviceID: UUID,
        onConnection: @escaping @Sendable (NWConnection) -> Void
    ) {
        self.name = name
        self.platform = platform
        self.deviceID = deviceID
        self.onConnection = onConnection
    }

    public var isRunning: Bool { listener != nil }

    public func start() throws {
        guard listener == nil else { return }
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        let listener = try NWListener(using: parameters)
        var txt = NWTXTRecord()
        txt["platform"] = platform.rawValue
        txt["id"] = deviceID.uuidString
        txt["protocol"] = String(SyncWire.protocolVersion)
        listener.service = NWListener.Service(name: name, type: SyncWire.bonjourType, txtRecord: txt)
        listener.newConnectionHandler = { [onConnection] connection in onConnection(connection) }
        listener.stateUpdateHandler = { [weak self] state in
            if case .failed = state { self?.stop() }
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    public func stop() {
        listener?.cancel()
        listener = nil
    }
}

public enum SyncBrowser {
    /// Looks for devices of `platform` (other than this one). Returns as soon as at least one is
    /// found and the results have settled for a moment, or when `timeout` runs out.
    public static func find(
        platform: SyncDevice,
        excluding deviceID: UUID,
        timeout: TimeInterval = 8
    ) async -> [SyncPeer] {
        let browser = NWBrowser(
            for: .bonjourWithTXTRecord(type: SyncWire.bonjourType, domain: nil),
            using: .tcp
        )
        let collector = PeerCollector()
        browser.browseResultsChangedHandler = { results, _ in
            collector.update(results.compactMap { peer(from: $0, wanted: platform, excluding: deviceID) })
        }
        browser.start(queue: DispatchQueue(label: "MarkdownStickies.sync.browser"))
        defer { browser.cancel() }

        let deadline = Date().addingTimeInterval(timeout)
        var settledSince: Date?
        while Date() < deadline, !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 250_000_000)
            if collector.peers.isEmpty {
                settledSince = nil
            } else if let since = settledSince {
                if Date().timeIntervalSince(since) > 1 { break }
            } else {
                settledSince = Date()
            }
        }
        return collector.peers
    }

    private static func peer(from result: NWBrowser.Result, wanted: SyncDevice, excluding: UUID) -> SyncPeer? {
        guard case .service(let name, _, _, _) = result.endpoint,
              case .bonjour(let txt) = result.metadata,
              let platform = txt["platform"].flatMap(SyncDevice.init(rawValue:)),
              platform == wanted
        else { return nil }
        let id = txt["id"].flatMap(UUID.init(uuidString:))
        guard id != excluding else { return nil }
        return SyncPeer(name: name, deviceID: id, platform: platform, endpoint: result.endpoint)
    }
}

private final class PeerCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var current: [SyncPeer] = []

    var peers: [SyncPeer] {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    func update(_ peers: [SyncPeer]) {
        lock.lock()
        current = peers.sorted { $0.name < $1.name }
        lock.unlock()
    }
}
