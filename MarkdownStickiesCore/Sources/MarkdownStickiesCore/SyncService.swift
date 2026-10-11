import Combine
import Foundation
import Network

/// What the sync UI shows. The same states and wording on both apps (spec §3.12).
public enum SyncState: Equatable, Sendable {
    case idle
    case searching
    case connecting(peer: String)
    case syncing(peer: String, done: Int, total: Int)
    case waitingForConfirmation(peer: String)
    case finished(SyncOutcome, peer: String)

    public var isBusy: Bool {
        switch self {
        case .idle, .finished: return false
        default: return true
        }
    }
}

/// Runs syncs for one app: advertises the device, starts a sync with the counterpart, accepts
/// incoming syncs, allows one session at a time, and publishes the state.
///
/// The app supplies `runSession`, which performs its role (`MacSyncSession` or
/// `IOSSyncResponder`) on a connection.
@MainActor
public final class SyncService: ObservableObject {
    public typealias RunSession = @Sendable (
        _ connection: SyncConnection,
        _ progress: @escaping @Sendable (SyncProgress) -> Void
    ) async -> SyncOutcome

    @Published public private(set) var state: SyncState = .idle
    /// Peer of the last session, for wording ("Synced with Julian's iPhone").
    @Published public private(set) var lastPeerName: String?

    public let deviceID: UUID
    public private(set) var deviceName: String
    public let platform: SyncDevice

    private let runSession: RunSession
    private var advertiser: SyncAdvertiser?
    private var current: Task<Void, Never>?
    /// Called on the main actor when a session finished (to rescan, reload editors, …).
    public var onFinished: ((SyncOutcome) -> Void)?

    public init(deviceName: String, platform: SyncDevice, runSession: @escaping RunSession) {
        self.deviceID = Self.persistentDeviceID()
        self.deviceName = deviceName
        self.platform = platform
        self.runSession = runSession
    }

    /// The counterpart platform this device syncs with.
    public var peerPlatform: SyncDevice { platform == .mac ? .ios : .mac }

    public var genericPeerName: String { platform == .mac ? "iPhone or iPad" : "Mac" }

    // MARK: - Advertising

    public func startAdvertising() {
        guard advertiser == nil else { return }
        let advertiser = SyncAdvertiser(name: deviceName, platform: platform, deviceID: deviceID) { [weak self] connection in
            Task { @MainActor in self?.accept(connection) }
        }
        do {
            try advertiser.start()
            self.advertiser = advertiser
        } catch {
            // Not fatal: the other device can't start syncs, but this one still can.
        }
    }

    public func stopAdvertising() {
        advertiser?.stop()
        advertiser = nil
    }

    /// Bonjour can go stale after sleep or backgrounding; restart it.
    public func refreshAdvertising() {
        guard advertiser != nil else { return }
        stopAdvertising()
        startAdvertising()
    }

    public func updateDeviceName(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != deviceName else { return }
        deviceName = trimmed
        refreshAdvertising()
    }

    // MARK: - Sessions

    /// Finds the counterpart on the network and syncs with it.
    /// - Parameter choose: picks one peer when several are found (return `nil` to cancel).
    public func syncNow(choose: @escaping @MainActor ([SyncPeer]) async -> SyncPeer? = { $0.first }) {
        guard !state.isBusy else { return }
        state = .searching
        current = Task { [weak self] in
            guard let self else { return }
            let peers = await SyncBrowser.find(platform: self.peerPlatform, excluding: self.deviceID)
            guard !Task.isCancelled else { return self.finish(.cancelled, peer: self.genericPeerName) }
            guard !peers.isEmpty else {
                return self.finish(
                    .failed("No \(self.genericPeerName) found. Open Markdown Stickies on both devices, on the same Wi-Fi, and try again."),
                    peer: self.genericPeerName
                )
            }
            let picked = peers.count == 1 ? peers[0] : await choose(peers)
            guard let peer = picked else { return self.finish(.cancelled, peer: self.genericPeerName) }

            self.state = .connecting(peer: peer.name)
            let connection = NWSyncConnection(endpoint: peer.endpoint)
            do {
                try await connection.start()
            } catch {
                return self.finish(
                    .failed("Couldn't reach \(peer.name). Make sure both apps are open on the same Wi-Fi."),
                    peer: peer.name
                )
            }
            await self.run(on: connection, peer: peer.name)
        }
    }

    /// Cancels the running sync. Before the commit nothing is changed; steps already applied
    /// are picked up at the next sync.
    public func cancel() {
        current?.cancel()
    }

    public func dismissResult() {
        if case .finished = state { state = .idle }
    }

    /// For the bulk-delete prompt: the session waits while the app asks the user.
    public func setWaitingForConfirmation(_ waiting: Bool) {
        guard let peer = lastPeerName else { return }
        if waiting {
            state = .waitingForConfirmation(peer: peer)
        } else if case .waitingForConfirmation = state {
            state = .syncing(peer: peer, done: 0, total: 0)
        }
    }

    private func accept(_ connection: NWConnection) {
        guard !state.isBusy else {
            connection.cancel()   // one session at a time
            return
        }
        let peerName = Self.serviceName(of: connection.endpoint) ?? genericPeerName
        state = .connecting(peer: peerName)
        current = Task { [weak self] in
            guard let self else { return }
            let wrapped = NWSyncConnection(connection: connection)
            do {
                try await wrapped.start()
            } catch {
                return self.finish(.failed("The connection to \(peerName) was closed."), peer: peerName)
            }
            await self.run(on: wrapped, peer: peerName)
        }
    }

    private func run(on connection: SyncConnection, peer: String) async {
        lastPeerName = peer
        state = .syncing(peer: peer, done: 0, total: 0)
        let outcome = await withTaskCancellationHandler {
            await runSession(connection) { [weak self] progress in
                Task { @MainActor in self?.apply(progress, peer: peer) }
            }
        } onCancel: {
            connection.close()
        }
        let name: String
        if case .completed(let summary) = outcome, !summary.peerName.isEmpty {
            name = summary.peerName
        } else {
            name = peer
        }
        finish(outcome, peer: name)
    }

    private func apply(_ progress: SyncProgress, peer: String) {
        guard state.isBusy else { return }
        if case .waitingForConfirmation = state { return }
        switch progress {
        case .preparing, .finishing:
            state = .syncing(peer: peer, done: 0, total: 0)
        case .syncing(let done, let total):
            state = .syncing(peer: peer, done: done, total: total)
        }
    }

    private func finish(_ outcome: SyncOutcome, peer: String) {
        lastPeerName = peer
        state = .finished(outcome, peer: peer)
        current = nil
        onFinished?(outcome)
    }

    private static func serviceName(of endpoint: NWEndpoint) -> String? {
        if case .service(let name, _, _, _) = endpoint { return name }
        return nil
    }

    private static func persistentDeviceID() -> UUID {
        let key = "syncDeviceID"
        if let raw = UserDefaults.standard.string(forKey: key), let id = UUID(uuidString: raw) {
            return id
        }
        let id = UUID()
        UserDefaults.standard.set(id.uuidString, forKey: key)
        return id
    }
}

/// UI wording, identical in both apps (spec §3.12).
public enum SyncStatusText {
    public static func title(_ state: SyncState) -> String {
        switch state {
        case .idle: return ""
        case .searching: return "Looking for devices…"
        case .connecting(let peer): return "Connecting to \(peer)…"
        case .syncing(let peer, _, _): return "Syncing with \(peer)…"
        case .waitingForConfirmation: return "Waiting for confirmation…"
        case .finished(.completed, let peer): return "Synced with \(peer)"
        case .finished(.cancelled, _): return "Sync cancelled"
        case .finished(.failed, _): return "Sync failed"
        }
    }

    /// Second line: progress, the summary, or the reason a sync failed.
    public static func detail(_ state: SyncState) -> String {
        switch state {
        case .syncing(_, let done, let total) where total > 0:
            return "\(done) of \(total)"
        case .finished(.completed(let summary), _):
            return summaryLine(summary)
        case .finished(.cancelled, _):
            return "Nothing more was changed. Anything already synced is kept."
        case .finished(.failed(let reason), _):
            return reason
        default:
            return ""
        }
    }

    /// "3 updated · 1 new · 2 moved to Trash · 1 conflict copy", or "Already up to date".
    public static func summaryLine(_ summary: SyncSummary) -> String {
        var parts: [String] = []
        if summary.updated > 0 { parts.append("\(summary.updated) updated") }
        if summary.created > 0 { parts.append("\(summary.created) new") }
        if summary.moved > 0 { parts.append("\(summary.moved) moved") }
        if summary.trashed > 0 { parts.append("\(summary.trashed) moved to Trash") }
        if summary.conflictCopies > 0 {
            parts.append(summary.conflictCopies == 1 ? "1 conflict copy" : "\(summary.conflictCopies) conflict copies")
        }
        let skipped = summary.skipped.count + summary.failedSteps.count
        if skipped > 0 { parts.append("\(skipped) skipped") }
        return parts.isEmpty ? "Already up to date" : parts.joined(separator: " · ")
    }

    /// One line per skipped item, for the expandable list.
    public static func skippedLines(_ summary: SyncSummary) -> [String] {
        summary.skipped.map { skipLine($0.reason, peer: summary.peerName) }
            + summary.failedSteps.map { "Skipped '\(name(of: $0.action))': \($0.reason)" }
    }

    static func skipLine(_ reason: SyncSkipReason, peer: String) -> String {
        switch reason {
        case .unreadable(let device, let location):
            return "Couldn't read '\(location.filename)' on \(device == .mac ? "the Mac" : peer)"
        case .duplicateID(_, let locations):
            return "Duplicate note id: " + locations.map { "'\($0.filename)'" }.joined(separator: ", ")
        case .editedOnPeerButNoLongerSynced(let location):
            return "'\(location.filename)' was edited on \(peer) but is no longer synced on the Mac"
        case .noSyncedFolderForNewNote(let location):
            return "Not synced: '\(location.filename)', no synced folder on the Mac"
        case .excludedOnMac(let location):
            return "'\(location.filename)': folder is excluded on the Mac"
        case .capitalizationOnlyRename(_, let to):
            return "Rename to '\(to.filename)' isn't synced yet (only the capitalization changed)"
        case .targetTaken(_, let location):
            return "Couldn't place '\(location.filename)': that name is already taken"
        case .imageAddedOnPeer(let key):
            return "Images added on \(peer) aren't synced yet ('\((key.path as NSString).lastPathComponent)')"
        }
    }

    private static func name(of action: SyncAction) -> String {
        switch action {
        case .writeNote(_, let at, _, _), .writeConflictCopy(_, _, let at, _), .trashNote(_, let at, _):
            return at.filename
        case .moveNote(_, let from, _, _):
            return from.filename
        case .writeImage(let key, _, _), .trashImage(let key, _):
            return (key.path as NSString).lastPathComponent
        }
    }
}
