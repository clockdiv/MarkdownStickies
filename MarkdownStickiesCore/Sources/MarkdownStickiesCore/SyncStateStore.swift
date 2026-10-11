import Foundation

/// The Mac's sync state for one iOS device and vault (spec §2.6):
///
/// ```
/// <directory>/
///   base.json
///   roots.json
///   base-text/<stickies-id>.md
///   conflict-base/<conflict-copy-id>.md
/// ```
///
/// Lives in Application Support, never in project folders. Every file is written atomically.
public struct SyncStateStore: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory.standardizedFileURL
    }

    /// `<Application Support>/<app>/SyncState/<deviceID>/<vaultID>`.
    public static func directory(in appSupport: URL, deviceID: UUID, vaultID: UUID) -> URL {
        appSupport
            .appendingPathComponent("SyncState", isDirectory: true)
            .appendingPathComponent(deviceID.uuidString, isDirectory: true)
            .appendingPathComponent(vaultID.uuidString, isDirectory: true)
    }

    /// True once a sync with this device and vault has been committed.
    public var hasBase: Bool {
        FileManager.default.fileExists(atPath: baseURL.path)
    }

    // MARK: - Base

    public func loadBase() throws -> SyncBase {
        guard hasBase else { return .empty }
        return try JSONDecoder().decode(StoredBase.self, from: Data(contentsOf: baseURL)).base
    }

    public func saveBase(_ base: SyncBase) throws {
        try write(JSONEncoder.sorted.encode(StoredBase(base)), to: baseURL)
    }

    // MARK: - Base text (for three-way merges)

    public func saveBaseText(_ data: Data, for id: UUID) throws {
        try write(data, to: baseTextURL(id))
    }

    public func baseText(for id: UUID) -> Data? {
        try? Data(contentsOf: baseTextURL(id))
    }

    public func removeBaseText(for id: UUID) {
        try? FileManager.default.removeItem(at: baseTextURL(id))
    }

    /// Keeps the original's base text as the conflict copy's merge base.
    public func snapshotConflictBase(copy copyID: UUID, original originalID: UUID) throws {
        guard let text = baseText(for: originalID) else { return }
        try write(text, to: conflictBaseURL(copyID))
    }

    public func conflictBase(for copyID: UUID) -> Data? {
        try? Data(contentsOf: conflictBaseURL(copyID))
    }

    public func removeConflictBase(for copyID: UUID) {
        try? FileManager.default.removeItem(at: conflictBaseURL(copyID))
    }

    /// Removes conflict snapshots whose copy no longer exists.
    public func pruneConflictBases(keeping copyIDs: Set<UUID>) {
        let folder = directory.appendingPathComponent("conflict-base", isDirectory: true)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return }
        for name in names {
            let id = UUID(uuidString: (name as NSString).deletingPathExtension)
            if id.map({ !copyIDs.contains($0) }) ?? true {
                try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
            }
        }
    }

    // MARK: - Roots

    public func loadRoots() throws -> [RootRecord] {
        guard FileManager.default.fileExists(atPath: rootsURL.path) else { return [] }
        return try JSONDecoder().decode([RootRecord].self, from: Data(contentsOf: rootsURL))
    }

    public func saveRoots(_ roots: [RootRecord]) throws {
        try write(JSONEncoder.sorted.encode(roots), to: rootsURL)
    }

    // MARK: - Private

    private var baseURL: URL { directory.appendingPathComponent("base.json") }
    private var rootsURL: URL { directory.appendingPathComponent("roots.json") }

    private func baseTextURL(_ id: UUID) -> URL {
        directory.appendingPathComponent("base-text/\(id.uuidString).md")
    }

    private func conflictBaseURL(_ id: UUID) -> URL {
        directory.appendingPathComponent("conflict-base/\(id.uuidString).md")
    }

    private func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}

/// A synced Mac root and its folder name in the iOS vault. Kept after the root is removed,
/// so its name is never given to another root.
public struct RootRecord: Codable, Hashable, Sendable {
    public var rootID: UUID
    public var macPath: String
    public var iosFolderName: String
    public var isSynced: Bool

    public init(rootID: UUID, macPath: String, iosFolderName: String, isSynced: Bool) {
        self.rootID = rootID
        self.macPath = macPath
        self.iosFolderName = iosFolderName
        self.isSynced = isSynced
    }

    /// Updates the records for the currently synced roots.
    ///
    /// Existing roots keep their folder name. New roots get their folder's name, with
    /// ` (2)`, ` (3)`, … if any record (current or removed) already uses it, compared ignoring case.
    public static func assign(existing: [RootRecord], synced: [(rootID: UUID, macPath: String)]) -> [RootRecord] {
        var records = existing.map { record -> RootRecord in
            var record = record
            record.isSynced = synced.contains { $0.rootID == record.rootID }
            return record
        }
        var used = Set(records.map { PathRules.collisionKey($0.iosFolderName) })

        for root in synced where !records.contains(where: { $0.rootID == root.rootID }) {
            let base = folderName(for: root.macPath)
            var name = base
            var index = 2
            while used.contains(PathRules.collisionKey(name)) {
                name = "\(base) (\(index))"
                index += 1
            }
            used.insert(PathRules.collisionKey(name))
            records.append(RootRecord(rootID: root.rootID, macPath: root.macPath, iosFolderName: name, isSynced: true))
        }
        return records
    }

    /// The Mac folder's name, made valid as a single, visible path component.
    private static func folderName(for macPath: String) -> String {
        var name = PathRules.normalized((macPath as NSString).lastPathComponent)
            .replacingOccurrences(of: ":", with: "-")
        while name.hasPrefix(".") { name.removeFirst() }
        return name.isEmpty ? "Notes" : name
    }
}

/// `SyncBase` as stored on disk: arrays instead of dictionaries with non-string keys,
/// so the JSON stays readable.
private struct StoredBase: Codable {
    struct NoteEntry: Codable {
        var id: UUID
        var note: SyncBase.Note
    }

    struct ImageEntry: Codable {
        var key: ImageKey
        var hash: String
    }

    var notes: [NoteEntry]
    var images: [ImageEntry]

    init(_ base: SyncBase) {
        notes = base.notes.map { NoteEntry(id: $0.key, note: $0.value) }.sorted { $0.id.uuidString < $1.id.uuidString }
        images = base.images.map { ImageEntry(key: $0.key, hash: $0.value) }.sorted { $0.key < $1.key }
    }

    var base: SyncBase {
        SyncBase(
            notes: Dictionary(notes.map { ($0.id, $0.note) }, uniquingKeysWith: { first, _ in first }),
            images: Dictionary(images.map { ($0.key, $0.hash) }, uniquingKeysWith: { first, _ in first })
        )
    }
}

extension JSONEncoder {
    static var sorted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
