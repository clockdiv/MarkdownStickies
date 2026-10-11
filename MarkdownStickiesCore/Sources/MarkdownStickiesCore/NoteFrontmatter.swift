import Foundation

/// Document-level frontmatter helpers for the editors: split and join the YAML block, and the
/// initial document of a new note. The `stickies-*` keys are read and written by
/// `StickiesFrontmatter`; old keys (`id`, `conflict_resolved`, `folder`, …) are left alone.
public enum NoteFrontmatter {
    public static let createdOnKey = "created_on"
    /// Name of the legacy in-root trash folder (`<root>/Trash/`), hidden from the app.
    public static let trashFolderName = "Trash"

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

    /// Splits off the frontmatter block, using the strict rule of `StickiesFrontmatter`
    /// (line 1 is `---`, a closing `---`, the first line inside is `key: value`).
    public static func splitDocument(_ markdown: String) -> DocumentParts {
        let bytes = Array(markdown.utf8)
        guard let block = StickiesFrontmatter.block(in: bytes) else {
            return DocumentParts(prefix: "", body: markdown)
        }
        let prefix = String(decoding: bytes[..<block.bodyStart], as: UTF8.self)
        let body = String(decoding: bytes[block.bodyStart...], as: UTF8.self)
        return DocumentParts(prefix: prefix, body: body)
    }

    public static func joinDocument(prefix: String, body: String) -> String {
        if prefix.isEmpty { return body }
        return prefix + body
    }

    /// New note: frontmatter with `stickies-id` (and `created_on`), then an H1.
    public static func initialDocument(
        title: String,
        id: UUID = UUID(),
        createdOn: String? = nil
    ) -> String {
        let heading = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let effective = heading.isEmpty ? "Untitled" : heading
        var fields = ["\(StickiesFrontmatter.idKey): \(id.uuidString)"]
        if let created = createdOn?.trimmingCharacters(in: .whitespacesAndNewlines), !created.isEmpty {
            fields.append("\(createdOnKey): \(created)")
        }
        return "---\n" + fields.joined(separator: "\n") + "\n---\n\n# \(effective)\n"
    }

    /// A file inside the legacy trash folder: a folder named `Trash` directly under one of `roots`.
    public static func isLegacyTrash(file: URL, roots: [URL]) -> Bool {
        let path = file.standardizedFileURL.path
        return roots.contains { root in
            let trash = root.standardizedFileURL.appendingPathComponent(trashFolderName).path
            return path.hasPrefix(trash + "/")
        }
    }
}
