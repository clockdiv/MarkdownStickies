import Foundation

/// `.stickies-vault` at the top of the iOS vault (spec §2.5).
public struct VaultInfo: Codable, Equatable, Sendable {
    public struct RootFolder: Codable, Hashable, Sendable {
        public var rootID: UUID
        public var folderName: String
        /// False once the root is no longer synced on the Mac. Its folder is still scanned,
        /// so its notes can leave the sync set cleanly.
        public var isSynced: Bool

        public init(rootID: UUID, folderName: String, isSynced: Bool) {
            self.rootID = rootID
            self.folderName = folderName
            self.isSynced = isSynced
        }
    }

    public var vaultID: UUID
    public var macDeviceID: UUID?
    public var roots: [RootFolder]

    public init(vaultID: UUID = UUID(), macDeviceID: UUID? = nil, roots: [RootFolder] = []) {
        self.vaultID = vaultID
        self.macDeviceID = macDeviceID
        self.roots = roots
    }
}

/// Builds the iOS manifest from the vault: root folders plus the Inbox (vault top level).
/// iOS never reads scan.conf; the Mac decides what is allowed.
public enum VaultScanner {
    public static let infoFilename = ".stickies-vault"

    public enum Failure: Error, Equatable, Sendable {
        case vaultUnreadable
        /// A known root folder was renamed, moved or deleted. The sync must stop.
        case missingRootFolder(String)
    }

    // MARK: - Vault info

    public static func loadOrCreateInfo(vault: URL) throws -> VaultInfo {
        let url = vault.appendingPathComponent(infoFilename)
        if FileManager.default.fileExists(atPath: url.path) {
            return try JSONDecoder().decode(VaultInfo.self, from: Data(contentsOf: url))
        }
        let info = VaultInfo()
        try saveInfo(info, vault: vault)
        return info
    }

    public static func saveInfo(_ info: VaultInfo, vault: URL) throws {
        try JSONEncoder.sorted.encode(info).write(to: vault.appendingPathComponent(infoFilename), options: .atomic)
    }

    /// Takes the Mac's root list (session step 2). New roots get their folder (created if needed);
    /// a known synced root whose folder is missing stops the sync; a missing folder of a removed
    /// root is just forgotten.
    public static func applyingRoots(_ macRoots: [VaultInfo.RootFolder], to info: VaultInfo, vault: URL) throws -> VaultInfo {
        let fm = FileManager.default
        var info = info
        var roots: [VaultInfo.RootFolder] = []
        for root in macRoots {
            let folder = vault.appendingPathComponent(root.folderName, isDirectory: true)
            let known = info.roots.contains { $0.rootID == root.rootID }
            var isDirectory: ObjCBool = false
            let exists = fm.fileExists(atPath: folder.path, isDirectory: &isDirectory) && isDirectory.boolValue
            if known, !exists {
                guard root.isSynced else { continue }
                throw Failure.missingRootFolder(root.folderName)
            }
            if !exists {
                guard root.isSynced else { continue }
                try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            }
            roots.append(root)
        }
        info.roots = roots
        return info
    }

    /// File URL of a location in the vault (`nil` for unknown roots).
    public static func url(for location: NoteLocation, vault: URL, info: VaultInfo) -> URL? {
        guard let rootID = location.rootID else { return vault.appendingPathComponent(location.path) }
        guard let folder = info.roots.first(where: { $0.rootID == rootID })?.folderName else { return nil }
        return vault.appendingPathComponent(folder, isDirectory: true).appendingPathComponent(location.path)
    }

    public static func url(for key: ImageKey, vault: URL, info: VaultInfo) -> URL? {
        url(for: NoteLocation(rootID: key.rootID, path: key.path), vault: vault, info: info)
    }

    // MARK: - Scan

    /// - Parameter knownImages: images the Mac asks about (its base images and references).
    public static func scan(vault: URL, info: VaultInfo, knownImages: Set<ImageKey> = []) throws -> SyncManifest {
        let fm = FileManager.default
        guard (try? fm.contentsOfDirectory(atPath: vault.path)) != nil else { throw Failure.vaultUnreadable }

        var notes: [ManifestNote] = []
        var unreadable: [NoteLocation] = []

        for root in info.roots {
            let folder = vault.appendingPathComponent(root.folderName, isDirectory: true)
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw Failure.missingRootFolder(root.folderName)
            }
            for file in files(under: folder) {
                guard let relative = SyncSetBuilder.relativePath(of: file, under: folder) else { continue }
                if let placeholder = placeholderTarget(relative) {
                    unreadable.append(NoteLocation(rootID: root.rootID, path: placeholder))
                    continue
                }
                guard case .success(let path) = PathRules.validate(relative, as: .note) else { continue }
                let location = NoteLocation(rootID: root.rootID, path: path)
                switch SyncSetBuilder.readNote(at: file, location: location) {
                case .tracked(let note): notes.append(note)
                case .untracked, .unreadable: unreadable.append(location)
                }
            }
        }

        // Inbox: tracked notes at the top level of the vault.
        let topLevel = (try? fm.contentsOfDirectory(at: vault, includingPropertiesForKeys: [.isRegularFileKey])) ?? []
        for file in topLevel {
            guard (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                  case .success(let name) = PathRules.validate(file.lastPathComponent, as: .note),
                  case .tracked(let note) = SyncSetBuilder.readNote(at: file, location: .inbox(name))
            else { continue }
            notes.append(note)
        }

        var imageKeys = knownImages
        for note in notes {
            guard let rootID = note.location.rootID else { continue }
            imageKeys.formUnion(note.imageRefs.map { ImageKey(rootID: rootID, path: $0) })
        }
        let images = imageKeys.sorted().compactMap { key -> ManifestImage? in
            guard let folder = info.roots.first(where: { $0.rootID == key.rootID })?.folderName else { return nil }
            return SyncSetBuilder.imageEntry(key, in: vault.appendingPathComponent(folder, isDirectory: true))
        }

        return SyncManifest(
            notes: notes.sorted { $0.location < $1.location },
            unreadable: unreadable.sorted(),
            images: images
        )
    }

    // MARK: - Private

    /// Regular files below `folder`, including hidden ones (for iCloud placeholders),
    /// but not inside hidden folders.
    private static func files(under folder: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey]
        ) else { return [] }
        var result: [URL] = []
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
            if values?.isDirectory == true {
                if url.lastPathComponent.hasPrefix(".") { enumerator.skipDescendants() }
                continue
            }
            if values?.isRegularFile == true { result.append(url.standardizedFileURL) }
        }
        return result
    }

    /// `docs/.idea.md.icloud` → `docs/idea.md` (an evicted iCloud file).
    private static func placeholderTarget(_ relative: String) -> String? {
        let name = (relative as NSString).lastPathComponent
        guard name.hasPrefix("."), name.hasSuffix(".icloud") else { return nil }
        let inner = String(name.dropFirst().dropLast(".icloud".count))
        guard inner.lowercased().hasSuffix(".md") else { return nil }
        let directory = (relative as NSString).deletingLastPathComponent
        return directory.isEmpty ? inner : directory + "/" + inner
    }
}
