import AppKit
import Foundation
import MarkdownStickiesCore

/// One row in Settings — mirrors a line in `scan.conf`.
struct ScanRoot: Identifiable, Hashable, Sendable {
    var id: String { ruleID }
    let ruleID: String
    let kind: ScanRule.Kind
    let pattern: String
    /// Resolved directory for INCLUDE folder rules (nil for excludes / globs / files).
    let path: URL?
    var isSynced: Bool

    var isIncludeDirectory: Bool { kind == .include && path != nil }
}

/// Single source of truth: `~/.markdown-stickies/scan.conf` (+ sync flags in UserDefaults).
@MainActor
final class ScanConfigStore: ObservableObject {
    @Published private(set) var config: ScanConfig = .empty
    @Published private(set) var roots: [ScanRoot] = []
    @Published var lastError: String?

    private let syncedPathsKey = "syncedScanRootPaths"
    private let legacyPathsKey = "scanRootPaths"
    private let didMigrateBookmarksKey = "didMigrateScanRootsToScanConf"

    init() {
        ScanConfig.ensureFileExists()
        migrateLegacyBookmarksIfNeeded()
        reload()
    }

    func reload() {
        config = ScanConfig.load()
        rebuildRoots()
        lastError = nil
    }

    func effectiveScanURLs() -> [URL] {
        let urls = roots.compactMap(\.path?.standardizedFileURL)
        return Self.dedupeNested(urls)
    }

    func syncedURLs() -> [URL] {
        let urls = roots.filter(\.isSynced).compactMap(\.path?.standardizedFileURL)
        return Self.dedupeNested(urls)
    }

    func setSynced(_ root: ScanRoot, enabled: Bool) {
        guard root.isIncludeDirectory, let path = root.path else { return }
        var synced = syncedPathSet()
        if enabled {
            synced.insert(path.standardizedFileURL.path)
        } else {
            synced.remove(path.standardizedFileURL.path)
        }
        UserDefaults.standard.set(Array(synced), forKey: syncedPathsKey)
        rebuildRoots()
    }

    @discardableResult
    func addFolder() -> Bool {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Add Folder"
        panel.message = "Choose a folder to INCLUDE in markdown scanning"

        guard panel.runModal() == .OK, let url = panel.url else { return false }
        return addIncludeFolder(url)
    }

    @discardableResult
    func addIncludeFolder(_ url: URL) -> Bool {
        let standardized = url.standardizedFileURL
        let pattern = ScanGlob.compactHomePath(standardized)
        if config.rules.contains(where: {
            $0.kind == .include && ScanGlob.expandTilde($0.pattern) == standardized.path
        }) {
            return false
        }
        var rules = config.rules
        let id = "include:\(rules.count):\(pattern)"
        rules.append(ScanRule(id: id, kind: .include, pattern: pattern))
        replaceRules(rules)
        return true
    }

    @discardableResult
    func addExcludeFolder() -> Bool {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Exclude Folder"
        panel.message = "Choose a folder to EXCLUDE from scanning"

        guard panel.runModal() == .OK, let url = panel.url else { return false }
        let pattern = ScanGlob.compactHomePath(url.standardizedFileURL)
        var rules = config.rules
        let id = "exclude:\(rules.count):\(pattern)"
        rules.append(ScanRule(id: id, kind: .exclude, pattern: pattern))
        replaceRules(rules)
        return true
    }

    func addExcludePattern(_ pattern: String = "**/README.md") {
        var rules = config.rules
        let id = "exclude:\(rules.count):\(pattern)"
        rules.append(ScanRule(id: id, kind: .exclude, pattern: pattern))
        replaceRules(rules)
    }

    func updateRule(id: String, kind: ScanRule.Kind? = nil, pattern: String? = nil) {
        var rules = config.rules
        guard let index = rules.firstIndex(where: { $0.id == id }) else { return }
        if let kind { rules[index].kind = kind }
        if let pattern { rules[index].pattern = pattern }
        // Keep id stable while editing so the text field doesn't lose focus.
        replaceRules(rules, reassignIDs: false)
    }

    func removeRule(id: String) {
        replaceRules(config.rules.filter { $0.id != id })
    }

    func remove(_ root: ScanRoot) {
        removeRule(id: root.ruleID)
    }

    func moveRule(from offsets: IndexSet, to offset: Int) {
        var rules = config.rules
        rules.move(fromOffsets: offsets, toOffset: offset)
        replaceRules(rules)
    }

    func replaceRules(_ rules: [ScanRule], reassignIDs: Bool = true) {
        if reassignIDs {
            config = ScanConfig(rules: rules.enumerated().map { index, rule in
                ScanRule(
                    id: "\(rule.kind.rawValue):\(index):\(rule.pattern)",
                    kind: rule.kind,
                    pattern: rule.pattern
                )
            })
        } else {
            config = ScanConfig(rules: rules)
        }
        persist()
        rebuildRoots()
    }

    func covers(_ url: URL) -> Bool {
        let standardized = url.standardizedFileURL.path
        return effectiveScanURLs().contains { root in
            standardized == root.path || standardized.hasPrefix(root.path + "/")
        }
    }

    static var desktopURL: URL {
        FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
    }

    private func persist() {
        do {
            try config.save()
            lastError = nil
        } catch {
            lastError = "Could not save scan.conf: \(error.localizedDescription)"
        }
    }

    private func rebuildRoots() {
        let synced = syncedPathSet()
        roots = config.rules.map { rule in
            let dir = rule.kind == .include ? ScanGlob.directoryURL(forPattern: rule.pattern) : nil
            let isSynced = dir.map { synced.contains($0.standardizedFileURL.path) } ?? false
            return ScanRoot(
                ruleID: rule.id,
                kind: rule.kind,
                pattern: rule.pattern,
                path: dir,
                isSynced: isSynced
            )
        }
    }

    private func syncedPathSet() -> Set<String> {
        Set(UserDefaults.standard.array(forKey: syncedPathsKey) as? [String] ?? [])
    }

    private static func dedupeNested(_ urls: [URL]) -> [URL] {
        urls.filter { url in
            !urls.contains { other in
                other.path != url.path && url.path.hasPrefix(other.path + "/")
            }
        }
    }

    private func migrateLegacyBookmarksIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: didMigrateBookmarksKey) else { return }
        defer { UserDefaults.standard.set(true, forKey: didMigrateBookmarksKey) }

        var loaded = ScanConfig.load()
        let hasIncludeDir = loaded.rules.contains {
            $0.kind == .include && ScanGlob.directoryURL(forPattern: $0.pattern) != nil
        }
        guard !hasIncludeDir else { return }

        let legacyPaths = UserDefaults.standard.array(forKey: legacyPathsKey) as? [String] ?? []
        guard !legacyPaths.isEmpty else { return }

        var rules = loaded.rules
        for path in legacyPaths {
            let url = URL(fileURLWithPath: path).standardizedFileURL
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let pattern = ScanGlob.compactHomePath(url)
            if !rules.contains(where: { $0.kind == .include && $0.pattern == pattern }) {
                let id = "include:\(rules.count):\(pattern)"
                rules.insert(ScanRule(id: id, kind: .include, pattern: pattern), at: 0)
            }
        }
        loaded = ScanConfig(rules: rules)
        try? loaded.save()
    }
}
