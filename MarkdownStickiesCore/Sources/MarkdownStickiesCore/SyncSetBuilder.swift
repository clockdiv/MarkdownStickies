import Foundation

/// A folder added in the Mac app.
public struct SyncRoot: Hashable, Sendable {
    public var id: UUID
    public var url: URL
    public var isSynced: Bool

    public init(id: UUID, url: URL, isSynced: Bool) {
        self.id = id
        self.url = url.standardizedFileURL
        self.isSynced = isSynced
    }
}

/// The Mac's sync set and manifest (spec §2.4), plus the path rules the planner needs.
public struct MacSyncSet: Sendable {
    public var manifest: SyncManifest
    /// All roots added in the app, synced or not (used for "deepest root" decisions).
    public var roots: [SyncRoot]
    /// Root paths by id, including roots that were removed (for probing base locations).
    public var rootPaths: [UUID: URL]
    public var config: ScanConfig

    /// File URL of a location, if its root is known.
    public func url(for location: NoteLocation) -> URL? {
        guard let rootID = location.rootID, let root = rootPaths[rootID] else { return nil }
        return root.appendingPathComponent(location.path)
    }

    public func url(for key: ImageKey) -> URL? {
        rootPaths[key.rootID]?.appendingPathComponent(key.path)
    }

    /// Whether a location coming from iOS may be written on the Mac: a synced root, a valid
    /// path, allowed by scan.conf, not in a built-in skipped folder or the legacy `Trash/`,
    /// and not inside a deeper root.
    public func allows(_ location: NoteLocation) -> Bool {
        guard let rootID = location.rootID,
              let root = roots.first(where: { $0.id == rootID && $0.isSynced }),
              case .success(let path) = PathRules.validate(location.path, as: .note)
        else { return false }

        let components = path.split(separator: "/").map(String.init)
        if components.first == SyncSetBuilder.legacyTrashFolder { return false }
        if components.dropLast().contains(where: NoteScanner.builtinSkippedDirectories.contains) { return false }

        let candidate = root.url.appendingPathComponent(path)
        guard SyncSetBuilder.owningRoot(of: candidate, among: roots)?.id == rootID else { return false }
        return config.allows(fileURL: candidate)
    }
}

public enum SyncSetBuilder {
    public static let maxImageBytes = 20 * 1024 * 1024
    static let legacyTrashFolder = "Trash"

    /// Builds the Mac manifest.
    ///
    /// - Parameters:
    ///   - roots: all roots added in the app; only synced ones contribute notes.
    ///   - rootPaths: root paths by id from the sync state, including removed roots.
    ///   - base: used to probe base locations for "left" and "unreadable" notes.
    ///   - extraImages: images to report besides the ones the Mac's notes reference
    ///     (the base images, and images the iOS notes reference).
    public static func build(
        roots: [SyncRoot],
        rootPaths: [UUID: URL] = [:],
        config: ScanConfig,
        base: SyncBase,
        extraImages: Set<ImageKey> = []
    ) -> MacSyncSet {
        var allPaths = rootPaths.mapValues(\.standardizedFileURL)
        for root in roots { allPaths[root.id] = root.url }

        var notes: [ManifestNote] = []
        var unreadable: [NoteLocation] = []
        let synced = roots.filter(\.isSynced)

        for scanned in NoteScanner.scan(roots: synced.map(\.url), config: config) {
            guard let root = owningRoot(of: scanned.path, among: roots), root.isSynced,
                  let relative = relativePath(of: scanned.path, under: root.url),
                  case .success(let path) = PathRules.validate(relative, as: .note),
                  path.split(separator: "/").first.map(String.init) != legacyTrashFolder
            else { continue }

            let location = NoteLocation(rootID: root.id, path: path)
            switch readNote(at: scanned.path, location: location) {
            case .tracked(let note): notes.append(note)
            case .untracked: break
            case .unreadable: unreadable.append(location)
            }
        }

        // Base notes not found in the set: still on disk (left / unreadable) or really gone?
        let found = Set(notes.map(\.id))
        var left: [LeftNote] = []
        for (id, entry) in base.notes where !found.contains(id) {
            guard let rootID = entry.location.rootID, let rootURL = allPaths[rootID] else { continue }
            let url = rootURL.appendingPathComponent(entry.location.path)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            switch readNote(at: url, location: entry.location) {
            case .tracked(let note) where note.id == id:
                left.append(LeftNote(id: id, location: entry.location))
            case .untracked:
                left.append(LeftNote(id: id, location: entry.location))   // key removed
            case .unreadable:
                if !unreadable.contains(entry.location) { unreadable.append(entry.location) }
            case .tracked:
                break   // another note took the place; this one is gone
            }
        }

        var imageKeys = extraImages.union(base.images.keys)
        for note in notes {
            guard let rootID = note.location.rootID else { continue }
            imageKeys.formUnion(note.imageRefs.map { ImageKey(rootID: rootID, path: $0) })
        }
        let syncedURLs = Dictionary(synced.map { ($0.id, $0.url) }, uniquingKeysWith: { first, _ in first })
        let images = imageKeys.sorted().compactMap { key -> ManifestImage? in
            guard let rootURL = syncedURLs[key.rootID] else { return nil }
            return imageEntry(key, in: rootURL)
        }

        return MacSyncSet(
            manifest: SyncManifest(
                notes: notes.sorted { $0.location < $1.location },
                unreadable: unreadable.sorted(),
                left: left.sorted { $0.location < $1.location },
                images: images
            ),
            roots: roots,
            rootPaths: allPaths,
            config: config
        )
    }

    // MARK: - Shared helpers (also used by VaultScanner)

    enum ReadResult {
        case tracked(ManifestNote)
        case untracked
        case unreadable
    }

    static func readNote(at url: URL, location: NoteLocation) -> ReadResult {
        guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else {
            return .unreadable
        }
        guard let id = StickiesFrontmatter.id(in: data) else { return .untracked }
        let directory = (location.path as NSString).deletingLastPathComponent
        return .tracked(ManifestNote(
            id: id,
            location: location,
            fileHash: NoteHashing.fileHash(data),
            restHash: NoteHashing.restHash(data),
            color: StickiesFrontmatter.value(for: StickiesFrontmatter.colorKey, in: data),
            imageRefs: location.isInbox ? [] : ImageReferences.paths(in: text, noteDirectory: directory)
        ))
    }

    /// An image entry if the file exists inside `rootURL`, is a regular file and isn't too big.
    static func imageEntry(_ key: ImageKey, in rootURL: URL) -> ManifestImage? {
        guard case .success(let url) = PathRules.resolve(key.path, as: .image, in: rootURL),
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true,
              (values.fileSize ?? 0) <= maxImageBytes,
              let data = try? Data(contentsOf: url)
        else { return nil }
        return ManifestImage(key: key, hash: NoteHashing.fileHash(data))
    }

    static func owningRoot(of url: URL, among roots: [SyncRoot]) -> SyncRoot? {
        let path = url.standardizedFileURL.path
        return roots
            .filter { path.hasPrefix($0.url.path.hasSuffix("/") ? $0.url.path : $0.url.path + "/") }
            .max { $0.url.path.count < $1.url.path.count }
    }

    static func relativePath(of url: URL, under root: URL) -> String? {
        let rootPath = root.standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(prefix) else { return nil }
        return String(path.dropFirst(prefix.count))
    }
}
