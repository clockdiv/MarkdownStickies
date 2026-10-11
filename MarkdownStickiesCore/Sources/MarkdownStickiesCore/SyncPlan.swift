import Foundation

public enum SyncDevice: String, Codable, Hashable, Sendable {
    case mac
    case ios
}

/// What a step expects to find at its target before it runs. A mismatch skips the step.
public enum SyncExpectation: Codable, Hashable, Sendable {
    case absent
    case hash(String)
}

/// Where the bytes of a write come from. Resolved by the session when the step runs.
public enum SyncContentSource: Codable, Hashable, Sendable {
    /// The Mac's current file for this note (after earlier Mac steps).
    case macNote(UUID)
    /// The iOS file for this note, fetched in session step 5.
    case iosNote(UUID)
    /// The iOS version of `original`, rewritten as conflict copy `copy`
    /// (`stickies-id: copy`, `stickies-conflict-of: original`).
    case iosNoteAsConflictCopy(original: UUID, copy: UUID)
    case macImage(ImageKey)
    case iosImage(ImageKey)
}

public enum SyncAction: Codable, Hashable, Sendable {
    case writeNote(id: UUID, at: NoteLocation, expect: SyncExpectation, source: SyncContentSource)
    /// Always "must not exist". Only ever planned on the Mac.
    case writeConflictCopy(id: UUID, original: UUID, at: NoteLocation, source: SyncContentSource)
    case moveNote(id: UUID, from: NoteLocation, to: NoteLocation, expectHash: String)
    case trashNote(id: UUID, at: NoteLocation, expectHash: String)
    case writeImage(key: ImageKey, expect: SyncExpectation, source: SyncContentSource)
    case trashImage(key: ImageKey, expectHash: String)

    /// Execution order within a device: conflict copies, writes, moves, trash.
    var phase: Int {
        switch self {
        case .writeConflictCopy: return 0
        case .writeNote, .writeImage: return 1
        case .moveNote: return 2
        case .trashNote, .trashImage: return 3
        }
    }
}

public struct SyncStep: Codable, Hashable, Sendable, Identifiable {
    public var id: Int
    public var device: SyncDevice
    public var action: SyncAction
    /// Steps that must have succeeded first. On the Mac side of a dependency, a failure drops
    /// the iOS step before it's sent; on iOS, the device skips it.
    public var dependsOn: [Int]
}

/// Why something was left out of this sync. The base stays unchanged for it.
public enum SyncSkipReason: Codable, Hashable, Sendable {
    /// A file exists at the note's location but couldn't be read.
    case unreadable(SyncDevice, NoteLocation)
    /// Several files on one device carry the same `stickies-id`.
    case duplicateID(SyncDevice, [NoteLocation])
    /// The note left the Mac's sync set, but iOS has unsynced edits.
    case editedOnPeerButNoLongerSynced(NoteLocation)
    /// A new iOS note can't be placed: the Mac has no synced root.
    case noSyncedFolderForNewNote(NoteLocation)
    /// The iOS location isn't allowed on the Mac (scan.conf, skipped folders, deeper root).
    case excludedOnMac(NoteLocation)
    /// A rename on iOS that only changes capitalization (not supported on the Mac yet).
    case capitalizationOnlyRename(from: NoteLocation, to: NoteLocation)
    /// Another file already uses the target location.
    case targetTaken(SyncDevice, NoteLocation)
    /// An image that exists only on iOS (added there through Files).
    case imageAddedOnPeer(ImageKey)
}

public struct SyncSkip: Codable, Hashable, Sendable {
    public var noteID: UUID?
    public var reason: SyncSkipReason
}

public struct SyncPlan: Codable, Sendable {
    /// Mac steps first, then iOS steps; each device's steps in execution order.
    public var steps: [SyncStep]
    public var skipped: [SyncSkip]
    /// Notes the plan moves to the trash, per device.
    public var trashedNoteCount: [SyncDevice: Int]
    /// True when the bulk-delete guard applies: the user must confirm before anything runs.
    public var needsConfirmation: Bool
    /// Notes and images whose base must not change at commit (skipped this sync).
    public var frozenNoteIDs: Set<UUID>
    public var frozenImages: Set<ImageKey>

    public var macSteps: [SyncStep] { steps.filter { $0.device == .mac } }
    public var iosSteps: [SyncStep] { steps.filter { $0.device == .ios } }
}
