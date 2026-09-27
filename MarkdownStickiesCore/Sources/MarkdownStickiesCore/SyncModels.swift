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
        /// Receiver finished applying the peer's catalog (IDs written).
        case applied
        /// Metadata for note-adjacent images (protocol ≥ 3).
        case assetOffers
        /// One or more image payloads; empty array = end of transfer (protocol ≥ 3).
        case assetBlobs
    }

    /// Bump when the wire shape changes in a breaking way.
    /// v2 = catalog apply ACK; v3 = post-catalog image asset exchange.
    public static let currentProtocolVersion = 3

    public var kind: Kind
    public var peerID: UUID?
    public var deviceName: String?
    public var notes: [SyncNotePayload]?
    /// Note IDs this side successfully applied from the peer's catalog.
    public var appliedIDs: [UUID]?
    public var protocolVersion: Int?
    public var assetOffers: [SyncAssetOffer]?
    public var assetBlobs: [SyncAssetBlob]?

    public init(
        kind: Kind,
        peerID: UUID? = nil,
        deviceName: String? = nil,
        notes: [SyncNotePayload]? = nil,
        appliedIDs: [UUID]? = nil,
        protocolVersion: Int? = nil,
        assetOffers: [SyncAssetOffer]? = nil,
        assetBlobs: [SyncAssetBlob]? = nil
    ) {
        self.kind = kind
        self.peerID = peerID
        self.deviceName = deviceName
        self.notes = notes
        self.appliedIDs = appliedIDs
        self.protocolVersion = protocolVersion
        self.assetOffers = assetOffers
        self.assetBlobs = assetBlobs
    }

    public static func hello(peerID: UUID, deviceName: String) -> SyncWireMessage {
        SyncWireMessage(
            kind: .hello,
            peerID: peerID,
            deviceName: deviceName,
            protocolVersion: currentProtocolVersion
        )
    }

    public static func catalog(
        _ notes: [SyncNotePayload],
        appliedIDs: [UUID] = [],
        deviceName: String? = nil
    ) -> SyncWireMessage {
        SyncWireMessage(
            kind: .catalog,
            deviceName: deviceName,
            notes: notes,
            appliedIDs: appliedIDs,
            protocolVersion: currentProtocolVersion
        )
    }

    public static func applied(_ ids: [UUID]) -> SyncWireMessage {
        SyncWireMessage(kind: .applied, appliedIDs: ids)
    }

    public static func assetOffers(_ offers: [SyncAssetOffer]) -> SyncWireMessage {
        SyncWireMessage(kind: .assetOffers, assetOffers: offers)
    }

    public static func assetBlobs(_ blobs: [SyncAssetBlob]) -> SyncWireMessage {
        SyncWireMessage(kind: .assetBlobs, assetBlobs: blobs)
    }
}

/// Result of applying a remote catalog (returned to the sync engine for ACKs).
public struct SyncApplyAck: Equatable, Sendable {
    public var appliedIDs: [UUID]
    public var errorDescription: String?

    public init(appliedIDs: [UUID] = [], errorDescription: String? = nil) {
        self.appliedIDs = appliedIDs
        self.errorDescription = errorDescription
    }

    public static let empty = SyncApplyAck()
}

/// Full sync exchange including peer confirmation of our outbound notes.
public struct SyncExchangeResult: Equatable, Sendable {
    public var remoteNotes: [SyncNotePayload]
    /// Notes the peer confirmed it wrote from our catalog this session.
    public var peerAppliedIDs: [UUID]
    /// Notes we wrote from the peer's catalog this session.
    public var localAppliedIDs: [UUID]
    /// Notes we still have that the peer would still accept after this exchange (should be empty).
    public var remainingOutboundIDs: [UUID]
    public var peerSupportsAck: Bool
    /// Peer display name when known (from hello / catalog).
    public var peerDeviceName: String?
    /// Images written from peer blobs this session (protocol ≥ 3).
    public var imagesReceived: Int
    /// Images we sent to the peer this session (protocol ≥ 3).
    public var imagesSent: Int

    public init(
        remoteNotes: [SyncNotePayload],
        peerAppliedIDs: [UUID],
        localAppliedIDs: [UUID],
        remainingOutboundIDs: [UUID],
        peerSupportsAck: Bool,
        peerDeviceName: String? = nil,
        imagesReceived: Int = 0,
        imagesSent: Int = 0
    ) {
        self.remoteNotes = remoteNotes
        self.peerAppliedIDs = peerAppliedIDs
        self.localAppliedIDs = localAppliedIDs
        self.remainingOutboundIDs = remainingOutboundIDs
        self.peerSupportsAck = peerSupportsAck
        self.peerDeviceName = peerDeviceName
        self.imagesReceived = imagesReceived
        self.imagesSent = imagesSent
    }

    /// True when the peer no longer needs any of our notes (or we cannot tell without ACK).
    public var peerConfirmedOutbound: Bool {
        remainingOutboundIDs.isEmpty
    }

    public var unconfirmedOutboundIDs: [UUID] { remainingOutboundIDs }
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
