import Foundation

/// `~/.markdown-stickies/` — shared config / state for the Mac app (and optional for iOS).
public enum MarkdownStickiesConfig {
    public static var homeDirectoryURL: URL {
        #if os(macOS)
        FileManager.default.homeDirectoryForCurrentUser
        #else
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        #endif
    }

    public static var directoryURL: URL {
        homeDirectoryURL.appendingPathComponent(".markdown-stickies", isDirectory: true)
    }

    public static var scanConfigURL: URL {
        directoryURL.appendingPathComponent("scan.conf", isDirectory: false)
    }

    public static var noteStateURL: URL {
        directoryURL.appendingPathComponent("note-state.json", isDirectory: false)
    }

    @discardableResult
    public static func ensureDirectory() throws -> URL {
        let dir = directoryURL
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

/// One INCLUDE / EXCLUDE line from `scan.conf`.
public struct ScanRule: Equatable, Sendable, Identifiable {
    public enum Kind: String, Equatable, Hashable, Sendable {
        case include
        case exclude
    }

    /// Stable across reload when kind+pattern+order match (index baked in at parse/edit time).
    public var id: String
    public var kind: Kind
    /// Pattern as written (`~/projects`, `**/README.md`, absolute path, …).
    public var pattern: String

    public init(id: String = UUID().uuidString, kind: Kind, pattern: String) {
        self.id = id
        self.kind = kind
        self.pattern = pattern
    }
}

/// Parsed `scan.conf`: ordered INCLUDE/EXCLUDE rules (last match wins).
public struct ScanConfig: Equatable, Sendable {
    public var rules: [ScanRule]

    public init(rules: [ScanRule] = []) {
        self.rules = rules
    }

    public static let empty = ScanConfig()

    /// Default starter file (comments only — no rules → scan everything under Settings folders).
    public static let defaultFileText = """
        # Markdown Stickies — ~/.markdown-stickies/scan.conf
        #
        # INCLUDE folders = what Settings lists and scans.
        # EXCLUDE = drop noise (README, vendor trees, …).
        # Rules run top → bottom; last match wins.
        #
        # Use ~ for your home folder. Globs: * = one segment, ** = any depth.
        #
        # INCLUDE
        # ~/projects
        #
        # EXCLUDE
        # **/README.md
        # **/CHANGELOG.md
        #
        """

    // MARK: - Parse / serialize

    public static func parse(_ text: String) -> ScanConfig {
        var rules: [ScanRule] = []
        var current: ScanRule.Kind?

        for rawLine in text.components(separatedBy: .newlines) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if trimmed.hasPrefix("#") { continue }

            let header = trimmed.uppercased()
            if header == "INCLUDE" {
                current = .include
                continue
            }
            if header == "EXCLUDE" {
                current = .exclude
                continue
            }

            guard let kind = current else { continue }
            let pattern = trimmed
            guard !pattern.isEmpty else { continue }
            let id = "\(kind.rawValue):\(rules.count):\(pattern)"
            rules.append(ScanRule(id: id, kind: kind, pattern: pattern))
        }
        return ScanConfig(rules: rules)
    }

    public func serialize() -> String {
        var lines: [String] = [
            "# Markdown Stickies — scan filter",
            "# Rules run top → bottom. Last match wins.",
            "#",
        ]
        var lastKind: ScanRule.Kind?
        for rule in rules {
            let pattern = rule.pattern.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !pattern.isEmpty else { continue }
            if rule.kind != lastKind {
                if lastKind != nil { lines.append("") }
                lines.append(rule.kind == .include ? "INCLUDE" : "EXCLUDE")
                lastKind = rule.kind
            }
            lines.append(pattern)
        }
        if lines.count <= 3 {
            return Self.defaultFileText
        }
        lines.append("")
        return lines.joined(separator: "\n")
    }

    public static func load(from url: URL = MarkdownStickiesConfig.scanConfigURL) -> ScanConfig {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return .empty
        }
        return parse(text)
    }

    public func save(to url: URL = MarkdownStickiesConfig.scanConfigURL) throws {
        try MarkdownStickiesConfig.ensureDirectory()
        try serialize().write(to: url, atomically: true, encoding: .utf8)
    }

    /// Ensures `scan.conf` exists (writes the commented starter if missing).
    public static func ensureFileExists() {
        let url = MarkdownStickiesConfig.scanConfigURL
        let fm = FileManager.default
        guard !fm.fileExists(atPath: url.path) else { return }
        _ = try? MarkdownStickiesConfig.ensureDirectory()
        try? defaultFileText.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - Matching

    /// Directory INCLUDE rules that can be used as filesystem scan roots (no globs).
    public func includeDirectoryURLs() -> [URL] {
        rules.compactMap { rule -> URL? in
            guard rule.kind == .include else { return nil }
            return ScanGlob.directoryURL(forPattern: rule.pattern)
        }
    }

    /// `true` if this `.md` file should appear in the library.
    /// Files are only discovered under INCLUDE directories; rules then apply last-match-wins
    /// (initial allow = true). Empty rules → allow (legacy / empty config).
    public func allows(fileURL: URL) -> Bool {
        guard !rules.isEmpty else { return true }
        let path = fileURL.standardizedFileURL.path
        var allowed = true
        for rule in rules {
            if ScanGlob.matches(path: path, pattern: rule.pattern) {
                allowed = (rule.kind == .include)
            }
        }
        return allowed
    }
}

/// gitignore-style glob matching for absolute paths, `~`, `*`, and `**`.
public enum ScanGlob {
    public static func expandTilde(_ pattern: String) -> String {
        let trimmed = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        let home = MarkdownStickiesConfig.homeDirectoryURL.path
        if trimmed == "~" {
            return home
        }
        if trimmed.hasPrefix("~/") {
            return home + String(trimmed.dropFirst())
        }
        return trimmed
    }

    /// Prefer `~/…` when the path is under the home directory.
    public static func compactHomePath(_ url: URL) -> String {
        let home = MarkdownStickiesConfig.homeDirectoryURL.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        if path == home { return "~" }
        if path.hasPrefix(home + "/") {
            return "~" + String(path.dropFirst(home.count))
        }
        return path
    }

    /// Concrete directory from a pattern (no globs). Nil for basenames / wildcards.
    public static func directoryURL(forPattern pattern: String) -> URL? {
        let raw = expandTilde(pattern)
        guard !raw.isEmpty, !raw.contains("*"), !raw.contains("?") else { return nil }
        if !raw.contains("/"), raw != "~" {
            // Basename-only (e.g. README.md) is not a scan root.
            return nil
        }
        var path = raw
        while path.hasSuffix("/") { path = String(path.dropLast()) }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) {
            return isDir.boolValue ? url : nil
        }
        // Allow not-yet-created folders listed in the file.
        return url
    }

    public static func matches(path: String, pattern: String) -> Bool {
        let raw = expandTilde(pattern)
        guard !raw.isEmpty else { return false }

        let pathStd = URL(fileURLWithPath: path).standardizedFileURL.path
        let hasGlob = raw.contains("*")
        let hasSlash = raw.contains("/")

        // Basename-only (e.g. README.md or *.md) — match last path component.
        if !hasSlash {
            let name = URL(fileURLWithPath: pathStd).lastPathComponent
            if hasGlob {
                return matchGlob(name, pattern: raw)
            }
            return name.caseInsensitiveCompare(raw) == .orderedSame
        }

        let patternStd: String = {
            if raw.hasPrefix("/") {
                return URL(fileURLWithPath: raw).standardizedFileURL.path
            }
            // Relative patterns still treated as absolute-from-root style globs on full path.
            // Prefer matching against full path with leading **/ if pattern doesn't start with /
            return raw
        }()

        if !hasGlob {
            // Exact file, or directory prefix (with or without trailing slash).
            var dir = patternStd
            while dir.hasSuffix("/") { dir = String(dir.dropLast()) }
            let dirURL = URL(fileURLWithPath: dir).standardizedFileURL
            let dirPath = dirURL.path
            if pathStd == dirPath { return true }
            if pathStd.hasPrefix(dirPath + "/") { return true }
            return false
        }

        // Glob against full absolute path. If pattern is not absolute, also try **/pattern.
        if patternStd.hasPrefix("/") {
            return matchGlob(pathStd, pattern: patternStd)
        }
        if matchGlob(pathStd, pattern: patternStd) { return true }
        if matchGlob(pathStd, pattern: "**/" + patternStd) { return true }
        return false
    }

    /// Match `string` against gitignore-like `pattern` (`*` one segment, `**` any depth).
    public static func matchGlob(_ string: String, pattern: String) -> Bool {
        guard let regex = try? regex(for: pattern) else { return false }
        let range = NSRange(string.startIndex..<string.endIndex, in: string)
        return regex.firstMatch(in: string, options: [], range: range) != nil
    }

    private static func regex(for pattern: String) throws -> NSRegularExpression {
        var result = ""
        let chars = Array(pattern)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "*" {
                if i + 1 < chars.count, chars[i + 1] == "*" {
                    // **/ → optional path prefix ending in /
                    if i + 2 < chars.count, chars[i + 2] == "/" {
                        result += "(?:.*/)?"
                        i += 3
                        continue
                    }
                    // ** → any characters including /
                    result += ".*"
                    i += 2
                    continue
                }
                result += "[^/]*"
                i += 1
                continue
            }
            if c == "?" {
                result += "[^/]"
                i += 1
                continue
            }
            if "\\.[]{}()+-^$|".contains(c) {
                result.append("\\")
            }
            result.append(c)
            i += 1
        }
        return try NSRegularExpression(pattern: "^" + result + "$", options: [])
    }
}
