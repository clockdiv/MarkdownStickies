import Foundation

/// Protocol 1 messages (spec §3.6). One version, no compatibility branches.
public enum SyncWire {
    public static let protocolVersion = 1
    public static let bonjourType = "_mdstickies._tcp"
    /// File contents travel in chunks of this size (base64 inside JSON stays under the frame limit).
    public static let chunkSize = 1 << 20
    public static let maxFrameBytes = 2 << 20
    /// A receive with no frame for this long fails the session.
    public static let idleTimeout: TimeInterval = 15
    /// The busy side sends a keepalive at this interval.
    public static let keepaliveInterval: TimeInterval = 5
}

public struct SyncHello: Codable, Sendable, Equatable {
    public var protocolVersion: Int
    public var deviceID: UUID
    public var deviceName: String
    public var platform: SyncDevice
    /// iOS only.
    public var vaultID: UUID?

    public init(deviceID: UUID, deviceName: String, platform: SyncDevice, vaultID: UUID? = nil) {
        self.protocolVersion = SyncWire.protocolVersion
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.platform = platform
        self.vaultID = vaultID
    }
}

/// Mac → iOS before the manifest: which root folders exist and what else to report.
public struct SyncPrepare: Codable, Sendable, Equatable {
    public var macDeviceID: UUID
    public var roots: [VaultInfo.RootFolder]
    public var defaultRootID: UUID?
    /// Images the Mac wants reported if present (base images).
    public var knownImages: [ImageKey]
}

/// Something the Mac asks iOS to send.
public enum SyncItem: Codable, Hashable, Sendable {
    case note(UUID)
    case image(ImageKey)
}

public struct SyncChunk: Codable, Sendable, Equatable {
    public var data: Data
    public var isLast: Bool
}

public enum SyncStepOutcome: Codable, Hashable, Sendable {
    case done
    case skipped(String)
}

public struct SyncStepResult: Codable, Sendable, Equatable {
    public var stepID: Int
    public var outcome: SyncStepOutcome
}

public enum SyncMessage: Codable, Sendable {
    case hello(SyncHello)
    case prepare(SyncPrepare)
    case manifest(SyncManifest)
    case fetch(SyncItem)
    /// Answer to `fetch` when the item can't be read.
    case unavailable(String)
    case chunk(SyncChunk)
    /// Followed by content chunks when the step writes something.
    case step(SyncStep)
    case stepResult(SyncStepResult)
    /// Mac → iOS after the steps: scan again and send a fresh manifest (for the commit).
    case rescan
    case summary(SyncSummary)
    case keepalive
    /// The user cancelled on the sending device. Nothing more happens in this session.
    case cancelled
    /// The sending device can't continue; the text says why.
    case abort(String)
}

public enum SyncProgress: Sendable, Equatable {
    case preparing
    case syncing(done: Int, total: Int)
    case finishing
}

extension SyncAction {
    /// Whether the step is followed by file content on the wire.
    public var carriesContent: Bool {
        switch self {
        case .writeNote, .writeConflictCopy, .writeImage: return true
        case .moveNote, .trashNote, .trashImage: return false
        }
    }
}

/// What a step that didn't run was about, for the summary.
public struct SyncFailedStep: Codable, Hashable, Sendable {
    public var device: SyncDevice
    public var action: SyncAction
    public var reason: String
}

/// The same summary is shown on both devices.
public struct SyncSummary: Codable, Sendable, Equatable {
    public var peerName: String
    public var isFirstSync: Bool
    /// Existing files overwritten with the other side's version.
    public var updated: Int
    /// New files (including restores).
    public var created: Int
    public var moved: Int
    public var trashed: Int
    public var conflictCopies: Int
    public var skipped: [SyncSkip]
    public var failedSteps: [SyncFailedStep]

    public init(peerName: String, isFirstSync: Bool) {
        self.peerName = peerName
        self.isFirstSync = isFirstSync
        updated = 0
        created = 0
        moved = 0
        trashed = 0
        conflictCopies = 0
        skipped = []
        failedSteps = []
    }

    public var changedNothing: Bool {
        updated + created + moved + trashed + conflictCopies == 0
    }
}

public enum SyncOutcome: Sendable, Equatable {
    case completed(SyncSummary)
    case cancelled
    case failed(String)
}
