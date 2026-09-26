import Foundation

/// YAML-ish frontmatter helpers for stable note sync IDs + metadata.
///
/// Expected shape:
/// ```
/// ---
/// id: 550E8400-E29B-41D4-A716-446655440000
/// created_on: Julian’s MacBook
/// ---
///
/// # My Note
/// ```
///
/// Display title comes from the filename; do **not** store `title` in frontmatter.
/// `folder` is only written when moving to Trash (`folder: Trash`) so deletes sync.
/// `created_on` is set at creation and then travels with the synced body.
public enum NoteFrontmatter {
    public static let idKey = "id"
    public static let folderKey = "folder"
    public static let createdOnKey = "created_on"
    /// Legacy key — no longer written; kept for reading old files.
    public static let titleKey = "title"

    /// Preferred field order inside the frontmatter block.
    private static let preferredKeyOrder = [idKey, createdOnKey, folderKey]

    /// UUID from leading frontmatter `id`, if present and valid.
    public static func syncID(in markdown: String) -> UUID? {
        guard let value = field(idKey, in: markdown) else { return nil }
        return UUID(uuidString: stripQuotes(value))
    }

    /// Relative folder path from frontmatter, if present.
    public static func folder(in markdown: String) -> String? {
        guard let value = field(folderKey, in: markdown) else { return nil }
        return normalizeFolder(stripQuotes(value))
    }

    /// Device label from frontmatter `created_on`, if present.
    public static func createdOn(in markdown: String) -> String? {
        guard let value = field(createdOnKey, in: markdown) else { return nil }
        let trimmed = stripQuotes(value).trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Display title from frontmatter `title`, if present.
    public static func displayTitle(in markdown: String) -> String? {
        guard let value = field(titleKey, in: markdown) else { return nil }
        let trimmed = stripQuotes(value).trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Leading YAML frontmatter block (including fences) and the remaining body.
    public struct DocumentParts: Equatable, Sendable {
        /// Everything through the closing `---` line (may be empty when no frontmatter).
        public var prefix: String
        /// Markdown after the frontmatter block.
        public var body: String

        public init(prefix: String, body: String) {
            self.prefix = prefix
            self.body = body
        }
    }

    public static func splitDocument(_ markdown: String) -> DocumentParts {
        guard let block = leadingFrontmatter(in: markdown) else {
            return DocumentParts(prefix: "", body: markdown)
        }
        let prefix = String(markdown[..<block.bodyStartIndex])
        let body = String(markdown[block.bodyStartIndex...])
        return DocumentParts(prefix: prefix, body: body)
    }

    public static func joinDocument(prefix: String, body: String) -> String {
        if prefix.isEmpty { return body }
        return prefix + body
    }

    /// Ensures an `id` field exists. Returns the (possibly updated) markdown.
    public static func ensuringSyncID(
        _ markdown: String,
        id preferredID: UUID = UUID()
    ) -> (markdown: String, id: UUID, didChange: Bool) {
        if let existing = syncID(in: markdown) {
            return (markdown, existing, false)
        }
        let updated = upsert(idKey, value: preferredID.uuidString, in: markdown)
        return (updated, preferredID, true)
    }

    /// On open/focus: ensure a stable `id` only.
    /// Do **not** stamp `folder` or `title` — those thrash LAN sync across devices
    /// (`folder` differs per vault layout; `title` is filename-derived).
    public static func ensuringOpenMetadata(
        _ markdown: String,
        file: URL,
        roots: [URL],
        titleHint: String? = nil
    ) -> (markdown: String, id: UUID, didChange: Bool) {
        _ = file
        _ = roots
        _ = titleHint
        return ensuringSyncID(markdown)
    }

    /// Sets frontmatter `title` (creates frontmatter / id as needed).
    public static func settingDisplayTitle(_ title: String, in markdown: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let effective = trimmed.isEmpty ? "Untitled" : trimmed
        let text = ensuringSyncID(markdown).markdown
        return upsert(titleKey, value: effective, in: text)
    }

    /// Sets or clears frontmatter `folder`. Pass `nil` / empty to remove the field.
    public static func settingFolder(_ folder: String?, in markdown: String) -> String {
        let text = ensuringSyncID(markdown).markdown
        guard let normalized = folder.flatMap({ normalizeFolder($0) }) else {
            return removingField(folderKey, in: text)
        }
        return upsert(folderKey, value: normalized, in: text)
    }

    /// Sets `created_on` only when missing. Never overwrites an existing value.
    public static func ensuringCreatedOn(_ deviceName: String, in markdown: String) -> (markdown: String, didChange: Bool) {
        if createdOn(in: markdown) != nil {
            return (markdown, false)
        }
        let trimmed = deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return (markdown, false) }
        let text = ensuringSyncID(markdown).markdown
        return (upsert(createdOnKey, value: trimmed, in: text), true)
    }

    /// Force-set `created_on`.
    public static func settingCreatedOn(_ deviceName: String, in markdown: String) -> String {
        let trimmed = deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return markdown }
        let text = ensuringSyncID(markdown).markdown
        return upsert(createdOnKey, value: trimmed, in: text)
    }

    public static let trashFolderName = "Trash"

    /// Whether a frontmatter `folder` value points at the app Trash.
    public static func isTrashFolder(_ folder: String?) -> Bool {
        guard let folder else { return false }
        let parts = folder.split(separator: "/").map(String.init)
        return parts.contains(trashFolderName) || folder == trashFolderName
    }

    /// Whether a file URL lives under a `Trash` directory segment.
    public static func isTrashed(file: URL) -> Bool {
        file.pathComponents.contains(trashFolderName)
    }

    /// Deepest scan root that contains `file`, if any.
    public static func matchingRoot(for file: URL, roots: [URL]) -> URL? {
        let filePath = file.standardizedFileURL.path
        return roots
            .map(\.standardizedFileURL)
            .filter { root in
                filePath == root.path
                    || filePath.hasPrefix(root.path.hasSuffix("/") ? root.path : root.path + "/")
            }
            .max(by: { $0.path.count < $1.path.count })
    }

    /// `{root}/Trash`, creating the directory if needed.
    public static func trashDirectory(in root: URL) throws -> URL {
        let trash = root.appendingPathComponent(trashFolderName, isDirectory: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        return trash
    }

    /// Moves a note into `{vault}/Trash/`, marks frontmatter `folder` with Trash
    /// (only place we still write `folder` — so sync can move the peer into Trash),
    /// and bumps mtime.
    public static func moveToTrash(file: URL, roots: [URL]) throws -> URL {
        let fm = FileManager.default
        guard let root = matchingRoot(for: file, roots: roots) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let trash = try trashDirectory(in: root)
        var dest = trash.appendingPathComponent(file.lastPathComponent)
        if fm.fileExists(atPath: dest.path) {
            let stem = dest.deletingPathExtension().lastPathComponent
            var index = 2
            repeat {
                dest = trash.appendingPathComponent("\(stem)-\(index).md")
                index += 1
            } while fm.fileExists(atPath: dest.path)
        }
        if file.standardizedFileURL != dest.standardizedFileURL {
            try fm.moveItem(at: file, to: dest)
        }

        var text = try String(contentsOf: dest, encoding: .utf8)
        text = ensuringSyncID(text).markdown
        // Stable trash marker for sync (not the local vault display name).
        text = settingFolder(trashFolderName, in: text)
        try text.write(to: dest, atomically: true, encoding: .utf8)
        return dest.standardizedFileURL
    }

    /// Frontmatter `folder` value for a note file: scan-root name, plus subfolders when nested
    /// (`Notes`, `Notes/projects`, `Notes/Trash`). Never `"/"` alone.
    public static func relativeFolder(file: URL, roots: [URL]) -> String? {
        relativeFolder(directory: file.deletingLastPathComponent(), roots: roots)
    }

    /// Frontmatter `folder` value for a directory under scan `roots`.
    public static func relativeFolder(directory: URL, roots: [URL]) -> String? {
        let fileDir = directory.standardizedFileURL
        let match = roots
            .map(\.standardizedFileURL)
            .filter { root in
                let rootPath = root.path
                let dirPath = fileDir.path
                return dirPath == rootPath
                    || dirPath.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/")
            }
            .max(by: { $0.path.count < $1.path.count })

        guard let root = match else {
            return normalizeFolder(fileDir.lastPathComponent)
        }

        let rootName = root.lastPathComponent
        if fileDir.path == root.path {
            return normalizeFolder(rootName)
        }
        let relative = String(fileDir.path.dropFirst(root.path.count))
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let nested = normalizeFolder(relative) else {
            return normalizeFolder(rootName)
        }
        return normalizeFolder("\(rootName)/\(nested)")
    }

    /// New note body with frontmatter and an H1.
    /// `title` / `folder` are optional — prefer filename + on-disk path for those;
    /// only `id` (+ optional `created_on`) are required for sync.
    public static func initialDocument(
        title: String,
        id: UUID = UUID(),
        folder: String? = nil,
        createdOn: String? = nil
    ) -> String {
        let heading = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let effective = heading.isEmpty ? "Untitled" : heading
        var fields = ["\(idKey): \(id.uuidString)"]
        if let created = createdOn?.trimmingCharacters(in: .whitespacesAndNewlines), !created.isEmpty {
            fields.append("\(createdOnKey): \(created)")
        }
        // Intentionally omit folder/title from default frontmatter (sync thrash).
        _ = folder
        let block = fields.joined(separator: "\n")
        return """
        ---
        \(block)
        ---

        # \(effective)

        """
    }

    // MARK: - Private

    private struct FrontmatterBlock {
        let fieldLines: [String]
        let bodyStartIndex: String.Index
        let fieldsStartIndex: String.Index
    }

    /// Empty / "/" / "." → nil; strips leading/trailing slashes.
    public static func normalizeFolder(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        s = stripQuotes(s).trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasPrefix("/") { s.removeFirst() }
        while s.hasSuffix("/") { s.removeLast() }
        if s.isEmpty || s == "." { return nil }
        // Collapse duplicate slashes in the middle.
        while s.contains("//") {
            s = s.replacingOccurrences(of: "//", with: "/")
        }
        return s
    }

    private static func field(_ key: String, in markdown: String) -> String? {
        guard let block = leadingFrontmatter(in: markdown) else { return nil }
        for line in block.fieldLines {
            guard let (k, value) = parseField(line), k == key else { continue }
            return value
        }
        return nil
    }

    private static func removingField(_ key: String, in markdown: String) -> String {
        guard let block = leadingFrontmatter(in: markdown) else { return markdown }
        let fields = block.fieldLines.filter { parseField($0)?.key != key }
        if fields.count == block.fieldLines.count { return markdown }
        let prefix = String(markdown[..<block.fieldsStartIndex])
        let body = String(markdown[block.bodyStartIndex...])
        if fields.isEmpty {
            return prefix + "---\n" + body
        }
        return prefix + fields.joined(separator: "\n") + "\n---\n" + body
    }

    /// Insert or replace a frontmatter field. Creates a frontmatter block when missing.
    private static func upsert(_ key: String, value: String, in markdown: String) -> String {
        let line = "\(key): \(value)"
        if let block = leadingFrontmatter(in: markdown) {
            var fields = block.fieldLines
            var replaced = false
            for i in fields.indices {
                if let (k, _) = parseField(fields[i]), k == key {
                    fields[i] = line
                    replaced = true
                    break
                }
            }
            if !replaced {
                fields.insert(line, at: insertionIndex(for: key, in: fields))
            }
            let prefix = String(markdown[..<block.fieldsStartIndex])
            let body = String(markdown[block.bodyStartIndex...])
            let fieldBlock = fields.joined(separator: "\n")
            return prefix + fieldBlock + "\n---\n" + body
        }

        if key == idKey {
            if markdown.isEmpty { return "---\n\(line)\n---\n" }
            if markdown.first?.isNewline == true { return "---\n\(line)\n---\n" + markdown }
            return "---\n\(line)\n---\n\n" + markdown
        }
        let withID = ensuringSyncID(markdown).markdown
        return upsert(key, value: value, in: withID)
    }

    private static func insertionIndex(for key: String, in fields: [String]) -> Int {
        let keyRank = preferredKeyOrder.firstIndex(of: key) ?? preferredKeyOrder.count
        for (i, line) in fields.enumerated() {
            guard let existing = parseField(line)?.key else { continue }
            let existingRank = preferredKeyOrder.firstIndex(of: existing) ?? preferredKeyOrder.count
            if keyRank < existingRank {
                return i
            }
        }
        // After last preferred key, or at end.
        if let idIndex = fields.firstIndex(where: { parseField($0)?.key == idKey }) {
            var insertAt = fields.index(after: idIndex)
            for k in preferredKeyOrder where k != idKey && k != key {
                if let idx = fields.firstIndex(where: { parseField($0)?.key == k }), idx >= insertAt {
                    insertAt = fields.index(after: idx)
                }
            }
            // Place according to rank among preferred keys already present.
            for k in preferredKeyOrder {
                guard k != key else { break }
                if let idx = fields.firstIndex(where: { parseField($0)?.key == k }) {
                    insertAt = max(insertAt, fields.index(after: idx))
                }
            }
            return insertAt
        }
        return 0
    }

    private static func leadingFrontmatter(in markdown: String) -> FrontmatterBlock? {
        var index = markdown.startIndex
        while index < markdown.endIndex, markdown[index].isNewline {
            index = markdown.index(after: index)
        }
        guard index < markdown.endIndex else { return nil }

        guard markdown[index...].hasPrefix("---") else { return nil }
        let afterFence = markdown.index(index, offsetBy: 3)
        guard afterFence == markdown.endIndex || markdown[afterFence].isNewline else {
            return nil
        }

        let fieldsStart = advancePastNewline(in: markdown, from: afterFence)
        var fields: [String] = []
        var cursor = fieldsStart

        while cursor < markdown.endIndex {
            let (line, next) = readLine(in: markdown, from: cursor)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "---" {
                return FrontmatterBlock(
                    fieldLines: fields,
                    bodyStartIndex: next,
                    fieldsStartIndex: fieldsStart
                )
            }
            fields.append(line)
            cursor = next
        }
        return nil
    }

    private static func readLine(in text: String, from start: String.Index) -> (String, String.Index) {
        var end = start
        while end < text.endIndex, !text[end].isNewline {
            end = text.index(after: end)
        }
        let line = String(text[start..<end])
        return (line, advancePastNewline(in: text, from: end))
    }

    private static func advancePastNewline(in text: String, from index: String.Index) -> String.Index {
        guard index < text.endIndex else { return index }
        if text[index] == "\r" {
            let next = text.index(after: index)
            if next < text.endIndex, text[next] == "\n" {
                return text.index(after: next)
            }
            return next
        }
        if text[index] == "\n" {
            return text.index(after: index)
        }
        return index
    }

    private static func parseField(_ line: String) -> (key: String, value: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
        guard let colon = trimmed.firstIndex(of: ":") else { return nil }
        let key = trimmed[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
        let value = trimmed[trimmed.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return nil }
        return (key, String(value))
    }

    private static func stripQuotes(_ value: String) -> String {
        guard value.count >= 2 else { return value }
        if (value.hasPrefix("\"") && value.hasSuffix("\""))
            || (value.hasPrefix("'") && value.hasSuffix("'")) {
            return String(value.dropFirst().dropLast())
        }
        return value
    }
}
