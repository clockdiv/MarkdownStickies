import Foundation

/// One note as exchanged over LAN sync.
public struct SyncNotePayload: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var title: String
    public var modifiedAt: Date
    public var body: String

    public init(id: UUID, title: String, modifiedAt: Date, body: String) {
        self.id = id
        self.title = title
        self.modifiedAt = modifiedAt
        self.body = body
    }
}

/// Length-prefixed JSON envelope for the sync TCP stream.
public struct SyncWireMessage: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case hello
        case catalog
    }

    public var kind: Kind
    public var peerID: UUID?
    public var deviceName: String?
    public var notes: [SyncNotePayload]?

    public init(kind: Kind, peerID: UUID? = nil, deviceName: String? = nil, notes: [SyncNotePayload]? = nil) {
        self.kind = kind
        self.peerID = peerID
        self.deviceName = deviceName
        self.notes = notes
    }

    public static func hello(peerID: UUID, deviceName: String) -> SyncWireMessage {
        SyncWireMessage(kind: .hello, peerID: peerID, deviceName: deviceName)
    }

    public static func catalog(_ notes: [SyncNotePayload]) -> SyncWireMessage {
        SyncWireMessage(kind: .catalog, notes: notes)
    }
}

public enum SyncMerge {
    public enum Decision: Equatable, Sendable {
        /// Remote is newer (or local missing) — write remote body.
        case applyRemote(SyncNotePayload)
        /// Local is newer, equal, or identical — keep local file as-is.
        case keepLocal
    }

    /// Prefer newer mtime. Identical bodies skip content transfer, but still converge
    /// divergent titles with a deterministic winner (avoids A↔B rename ping-pong).
    /// Equal mtime + different bodies also converge deterministically (e.g. `created_on`
    /// renamed on one peer while content already matched).
    public static func decide(local: SyncNotePayload?, remote: SyncNotePayload) -> Decision {
        guard let local else { return .applyRemote(remote) }
        if local.body == remote.body {
            return decideTitleOnly(local: local, remote: remote)
        }

        let remoteSec = floor(remote.modifiedAt.timeIntervalSince1970)
        let localSec = floor(local.modifiedAt.timeIntervalSince1970)
        if remoteSec > localSec { return .applyRemote(remote) }
        if remoteSec < localSec { return .keepLocal }
        if remote.modifiedAt > local.modifiedAt { return .applyRemote(remote) }
        if remote.modifiedAt < local.modifiedAt { return .keepLocal }
        // Equal mtime, different bodies → stable winner on both peers.
        if remote.body > local.body { return .applyRemote(remote) }
        return .keepLocal
    }

    /// Same content, different display titles → one stable winner on both peers.
    private static func decideTitleOnly(local: SyncNotePayload, remote: SyncNotePayload) -> Decision {
        let localSlug = NoteFilename.slugify(local.title)
        let remoteSlug = NoteFilename.slugify(remote.title)
        if localSlug == remoteSlug { return .keepLocal }

        // Newer file wins the name when mtimes differ.
        let remoteSec = floor(remote.modifiedAt.timeIntervalSince1970)
        let localSec = floor(local.modifiedAt.timeIntervalSince1970)
        if remoteSec > localSec { return .applyRemote(remote) }
        if remoteSec < localSec { return .keepLocal }
        if remote.modifiedAt > local.modifiedAt { return .applyRemote(remote) }
        if remote.modifiedAt < local.modifiedAt { return .keepLocal }

        // Equal mtime: lexicographic slug so both sides pick the same name.
        if remoteSlug > localSlug { return .applyRemote(remote) }
        return .keepLocal
    }

    public static func decisions(
        localByID: [UUID: SyncNotePayload],
        remote: [SyncNotePayload]
    ) -> [Decision] {
        remote.map { decide(local: localByID[$0.id], remote: $0) }
    }

    /// IDs from `ours` that the peer would accept (missing there, or our body newer).
    public static func outboundIDs(
        ours: [SyncNotePayload],
        theirs: [SyncNotePayload]
    ) -> [UUID] {
        let theirByID = Dictionary(uniqueKeysWithValues: theirs.map { ($0.id, $0) })
        return ours.compactMap { our in
            if case .applyRemote = decide(local: theirByID[our.id], remote: our) {
                return our.id
            }
            return nil
        }
    }
}

public enum SyncFrameCodec {
    public static let maxFrameBytes = 32 * 1024 * 1024

    public static func encode(_ message: SyncWireMessage) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let payload = try encoder.encode(message)
        var length = UInt32(payload.count).bigEndian
        var frame = Data(bytes: &length, count: 4)
        frame.append(payload)
        return frame
    }

    /// Consume one complete frame from `buffer` if available.
    public static func decodeOne(_ buffer: inout Data) throws -> SyncWireMessage? {
        guard buffer.count >= 4 else { return nil }

        let beLength = buffer.prefix(4).withUnsafeBytes { ptr -> UInt32 in
            ptr.load(as: UInt32.self)
        }
        let frameLength = Int(UInt32(bigEndian: beLength))
        guard frameLength >= 0, frameLength <= maxFrameBytes else {
            throw SyncProtocolError.invalidFrameLength(frameLength)
        }
        guard buffer.count >= 4 + frameLength else { return nil }

        let payload = buffer.subdata(in: 4..<(4 + frameLength))
        buffer.removeSubrange(0..<(4 + frameLength))

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try decoder.decode(SyncWireMessage.self, from: payload)
    }

    /// Consume all complete frames currently in `buffer`.
    public static func drain(_ buffer: inout Data) throws -> [SyncWireMessage] {
        var messages: [SyncWireMessage] = []
        while let message = try decodeOne(&buffer) {
            messages.append(message)
        }
        return messages
    }
}

public enum SyncProtocolError: Error, LocalizedError, Sendable {
    case invalidFrameLength(Int)
    case unexpectedMessage(SyncWireMessage.Kind)
    case peerNotFound
    case timedOut
    case connectionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidFrameLength(let n):
            return "Invalid sync frame length (\(n))."
        case .unexpectedMessage(let kind):
            return "Unexpected sync message: \(kind.rawValue)."
        case .peerNotFound:
            return "No Markdown Stickies peer found on the local network."
        case .timedOut:
            return "Sync timed out waiting for a peer."
        case .connectionFailed(let detail):
            return "Could not connect to peer: \(detail)"
        }
    }
}
