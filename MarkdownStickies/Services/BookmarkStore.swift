import Foundation
import AppKit

struct ScanRoot: Identifiable, Hashable, Sendable {
    var id: String { path.path }
    let path: URL
    var isSynced: Bool
}

@MainActor
final class BookmarkStore: ObservableObject {
    @Published private(set) var roots: [ScanRoot] = []

    private let pathsKey = "scanRootPaths"
    private let syncedPathsKey = "syncedScanRootPaths"
    private let legacyBookmarksKey = "scanRootBookmarks"
    private let didMigrateKey = "didMigrateScanRootsFromSandbox"

    init() {
        load()
    }

    func load() {
        roots = []
        let synced = Set(UserDefaults.standard.array(forKey: syncedPathsKey) as? [String] ?? [])

        if UserDefaults.standard.object(forKey: pathsKey) != nil {
            // Key exists (even as []) — user choice wins; do not re-migrate.
            let paths = UserDefaults.standard.array(forKey: pathsKey) as? [String] ?? []
            roots = paths
                .map { path -> ScanRoot in
                    let url = URL(fileURLWithPath: path).standardizedFileURL
                    return ScanRoot(path: url, isSynced: synced.contains(url.path))
                }
                .filter { FileManager.default.fileExists(atPath: $0.path.path) }
        } else if !UserDefaults.standard.bool(forKey: didMigrateKey) {
            migrateLegacyOnce(synced: synced)
        }

        UserDefaults.standard.set(true, forKey: didMigrateKey)
        roots.sort { $0.path.path.localizedCaseInsensitiveCompare($1.path.path) == .orderedAscending }
        persist()
    }

    private func migrateLegacyOnce(synced: Set<String>) {
        if let stored = UserDefaults.standard.array(forKey: legacyBookmarksKey) as? [Data] {
            roots = resolveBookmarkDataList(stored, synced: synced)
            UserDefaults.standard.removeObject(forKey: legacyBookmarksKey)
        }
        if roots.isEmpty {
            migrateFromSandboxContainerPrefs(synced: synced)
        }
        persist()
    }

    private func resolveBookmarkDataList(_ stored: [Data], synced: Set<String>) -> [ScanRoot] {
        var migrated: [ScanRoot] = []
        for data in stored {
            var isStale = false
            if let url = try? URL(
                resolvingBookmarkData: data,
                options: [],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) {
                let standardized = url.standardizedFileURL
                migrated.append(ScanRoot(path: standardized, isSynced: synced.contains(standardized.path)))
            } else if let url = try? URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) {
                let standardized = url.standardizedFileURL
                migrated.append(ScanRoot(path: standardized, isSynced: synced.contains(standardized.path)))
            }
        }
        return migrated
    }

    private func migrateFromSandboxContainerPrefs(synced: Set<String>) {
        let legacyPlist = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Containers/com.markdownstickies.app/Data/Library/Preferences/com.markdownstickies.app.plist"
            )
        guard let dict = NSDictionary(contentsOf: legacyPlist) as? [String: Any] else { return }

        if let paths = dict[pathsKey] as? [String] {
            roots = paths
                .map { path -> ScanRoot in
                    let url = URL(fileURLWithPath: path).standardizedFileURL
                    return ScanRoot(path: url, isSynced: synced.contains(url.path))
                }
                .filter { FileManager.default.fileExists(atPath: $0.path.path) }
        } else if let bookmarks = dict[legacyBookmarksKey] as? [Data] {
            roots = resolveBookmarkDataList(bookmarks, synced: synced)
        }
    }

    @discardableResult
    func addFolder() -> Bool {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Add Folder"
        panel.message = "Choose a folder to scan for markdown notes"

        guard panel.runModal() == .OK, let url = panel.url else {
            return false
        }
        return addFolderURL(url)
    }

    @discardableResult
    func addFolderURL(_ url: URL) -> Bool {
        let standardized = url.standardizedFileURL
        if covers(standardized) {
            return false
        }
        roots.append(ScanRoot(path: standardized, isSynced: false))
        roots.sort { $0.path.path.localizedCaseInsensitiveCompare($1.path.path) == .orderedAscending }
        persist()
        return true
    }

    @discardableResult
    func addSecurityScopedURL(_ url: URL) -> Bool {
        addFolderURL(url)
    }

    func covers(_ url: URL) -> Bool {
        let standardized = url.standardizedFileURL.path
        return roots.contains { root in
            standardized == root.path.standardizedFileURL.path
                || standardized.hasPrefix(root.path.standardizedFileURL.path + "/")
        }
    }

    static var desktopURL: URL {
        FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
    }

    func effectiveScanURLs() -> [URL] {
        let urls = roots.map(\.path.standardizedFileURL)
        // Drop roots that are inside another scanned root (avoids duplicate FSEvents + scans).
        return urls.filter { url in
            !urls.contains { other in
                other.path != url.path && url.path.hasPrefix(other.path + "/")
            }
        }
    }

    /// Scan roots flagged for LAN sync.
    func syncedURLs() -> [URL] {
        let synced = roots.filter(\.isSynced).map(\.path.standardizedFileURL)
        return synced.filter { url in
            !synced.contains { other in
                other.path != url.path && url.path.hasPrefix(other.path + "/")
            }
        }
    }

    func setSynced(_ root: ScanRoot, enabled: Bool) {
        guard let index = roots.firstIndex(where: { $0.id == root.id }) else { return }
        roots[index].isSynced = enabled
        persist()
    }

    func remove(_ root: ScanRoot) {
        roots.removeAll { $0.id == root.id }
        persist()
    }

    func withAccess<T>(to url: URL, _ body: () throws -> T) rethrows -> T {
        try body()
    }

    private func persist() {
        UserDefaults.standard.set(roots.map(\.path.path), forKey: pathsKey)
        UserDefaults.standard.set(
            roots.filter(\.isSynced).map(\.path.path),
            forKey: syncedPathsKey
        )
    }
}
