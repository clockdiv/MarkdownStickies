import Foundation

/// Where a note lives, the same way on both devices: a synced root plus a relative path.
///
/// The Mac's root `rootID` maps to one root folder in the iOS vault, so equal locations
/// mean the same file on both sides. `rootID == nil` is the iOS Inbox (vault top level).
public struct NoteLocation: Codable, Hashable, Sendable, Comparable {
    /// `nil` = iOS Inbox.
    public var rootID: UUID?
    /// NFC, relative to the root folder (or the vault top level for the Inbox).
    public var path: String

    public init(rootID: UUID?, path: String) {
        self.rootID = rootID
        self.path = PathRules.normalized(path)
    }

    public static func inbox(_ filename: String) -> NoteLocation {
        NoteLocation(rootID: nil, path: filename)
    }

    public var isInbox: Bool { rootID == nil }

    public var filename: String { (path as NSString).lastPathComponent }

    /// Same folder, another file name.
    public func sibling(named filename: String) -> NoteLocation {
        let directory = (path as NSString).deletingLastPathComponent
        let path = directory.isEmpty ? filename : directory + "/" + filename
        return NoteLocation(rootID: rootID, path: path)
    }

    /// For collision checks: case-folded, so `Idea.md` and `idea.md` collide.
    public var collisionKey: String {
        (rootID?.uuidString ?? "inbox") + "/" + PathRules.collisionKey(path)
    }

    public static func < (lhs: NoteLocation, rhs: NoteLocation) -> Bool {
        let l = lhs.rootID?.uuidString ?? ""
        let r = rhs.rootID?.uuidString ?? ""
        return l != r ? l < r : lhs.path < rhs.path
    }
}

/// An image, identified by its synced root and its full relative path.
public struct ImageKey: Codable, Hashable, Sendable, Comparable {
    public var rootID: UUID
    public var path: String

    public init(rootID: UUID, path: String) {
        self.rootID = rootID
        self.path = PathRules.normalized(path)
    }

    public static func < (lhs: ImageKey, rhs: ImageKey) -> Bool {
        lhs.rootID != rhs.rootID ? lhs.rootID.uuidString < rhs.rootID.uuidString : lhs.path < rhs.path
    }
}

/// One tracked note as one device sees it.
public struct ManifestNote: Codable, Hashable, Sendable {
    public var id: UUID
    public var location: NoteLocation
    public var fileHash: String
    public var restHash: String
    /// Raw `stickies-color` value, `nil` when absent.
    public var color: String?
    /// Images this version references, relative to its root (see `ImageReferences`).
    public var imageRefs: [String]

    public init(
        id: UUID,
        location: NoteLocation,
        fileHash: String,
        restHash: String,
        color: String? = nil,
        imageRefs: [String] = []
    ) {
        self.id = id
        self.location = location
        self.fileHash = fileHash
        self.restHash = restHash
        self.color = color
        self.imageRefs = imageRefs
    }
}

public struct ManifestImage: Codable, Hashable, Sendable {
    public var key: ImageKey
    public var hash: String

    public init(key: ImageKey, hash: String) {
        self.key = key
        self.hash = hash
    }
}

/// A note that is no longer in the Mac's sync set although its file is still on disk
/// (excluded, Sync turned off, moved out of the synced roots, or `stickies-id` removed).
public struct LeftNote: Codable, Hashable, Sendable {
    public var id: UUID
    public var location: NoteLocation

    public init(id: UUID, location: NoteLocation) {
        self.id = id
        self.location = location
    }
}

/// Everything one device reports about its notes and images.
public struct SyncManifest: Codable, Sendable {
    /// Tracked notes. Duplicates (two files with one id) are listed as they are.
    public var notes: [ManifestNote]
    /// Files that exist but couldn't be read: unreadable, cloud placeholders, or no `stickies-id`.
    /// A note is never treated as deleted while its base location is listed here.
    public var unreadable: [NoteLocation]
    /// Mac only: base notes whose file still exists but that left the sync set.
    public var left: [LeftNote]
    /// Images present on this device: those its notes reference, plus (on iOS) those the
    /// Mac asked about because they are in the base.
    public var images: [ManifestImage]

    public init(
        notes: [ManifestNote] = [],
        unreadable: [NoteLocation] = [],
        left: [LeftNote] = [],
        images: [ManifestImage] = []
    ) {
        self.notes = notes
        self.unreadable = unreadable
        self.left = left
        self.images = images
    }
}

/// What both devices were last confirmed to have, per note and image. Stored on the Mac only.
public struct SyncBase: Codable, Sendable, Equatable {
    public struct Note: Codable, Hashable, Sendable {
        public var location: NoteLocation
        public var fileHash: String
        public var restHash: String
        public var color: String?

        public init(location: NoteLocation, fileHash: String, restHash: String, color: String? = nil) {
            self.location = location
            self.fileHash = fileHash
            self.restHash = restHash
            self.color = color
        }
    }

    public var notes: [UUID: Note]
    public var images: [ImageKey: String]

    public init(notes: [UUID: Note] = [:], images: [ImageKey: String] = [:]) {
        self.notes = notes
        self.images = images
    }

    public static let empty = SyncBase()
}
