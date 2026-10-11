import Foundation

/// Reads and writes the app's namespaced frontmatter keys (`stickies-*`), byte-exactly.
///
/// A frontmatter block exists only when:
/// - line 1 (after an optional UTF-8 BOM) is exactly `---`,
/// - a later line is exactly `---`,
/// - the first non-empty, non-comment line in between looks like `key: value`.
///
/// Anything else, such as a note that starts with blank lines or a horizontal rule,
/// has no block. Writing a key then creates a new block at the very top.
///
/// Writes change only the one line they touch. Other keys, their order, line endings
/// (LF or CRLF) and the BOM stay exactly as they were.
public enum StickiesFrontmatter {
    public static let idKey = "stickies-id"
    public static let colorKey = "stickies-color"
    public static let conflictOfKey = "stickies-conflict-of"

    // MARK: - Reading

    /// `stickies-id`, if present and a valid UUID.
    public static func id(in data: Data) -> UUID? {
        value(for: idKey, in: data).flatMap(UUID.init(uuidString:))
    }

    /// `stickies-color`, if present and valid. `nil` means "show the default color".
    public static func color(in data: Data) -> NoteColor? {
        value(for: colorKey, in: data).flatMap(NoteColor.init(frontmatterValue:))
    }

    /// `stickies-conflict-of`, if present and a valid UUID.
    public static func conflictOf(in data: Data) -> UUID? {
        value(for: conflictOfKey, in: data).flatMap(UUID.init(uuidString:))
    }

    /// Raw value of `key` (quotes stripped), from the first matching line of the block.
    /// Keys match exactly and case-sensitively.
    public static func value(for key: String, in data: Data) -> String? {
        let bytes = [UInt8](data)
        guard let block = block(in: bytes) else { return nil }
        return block.fields.first(where: { $0.key == key })?.value
    }

    /// Whether the document has a frontmatter block at all.
    public static func hasBlock(_ data: Data) -> Bool {
        block(in: [UInt8](data)) != nil
    }

    // MARK: - Writing

    /// Sets `key` to `value`. Returns `data` unchanged when that value is already set.
    ///
    /// - An existing line for `key` is rewritten in place (its line ending is kept).
    /// - A missing key is added as the last line of the block.
    /// - Without a block, a new block is created at the top (after the BOM).
    public static func setting(_ key: String, to value: String, in data: Data) -> Data {
        precondition(!value.contains(where: \.isNewline), "Frontmatter values are single-line")
        let bytes = [UInt8](data)
        let line = Array("\(key): \(value)".utf8)

        guard let block = block(in: bytes) else {
            return Data(prependingBlock(with: line, to: bytes))
        }
        if let field = block.fields.first(where: { $0.key == key }) {
            if field.value == value { return data }
            var result = bytes
            result.replaceSubrange(field.lineStart..<field.contentEnd, with: line)
            return Data(result)
        }
        var result = bytes
        result.insert(contentsOf: line + block.lineEnding, at: block.closingFenceStart)
        return Data(result)
    }

    /// Removes the line for `key`. If the block has no fields left, the whole block goes.
    public static func removing(_ key: String, in data: Data) -> Data {
        let bytes = [UInt8](data)
        guard let block = block(in: bytes),
              let field = block.fields.first(where: { $0.key == key })
        else { return data }

        var result = bytes
        if block.fields.count == 1, block.hasOnlyFieldLines {
            result.removeSubrange(block.openingFenceStart..<block.bodyStart)
        } else {
            result.removeSubrange(field.lineStart..<field.lineEnd)
        }
        return Data(result)
    }

    /// Ensures `stickies-id` exists. Returns the (possibly updated) document and the id.
    public static func ensuringID(
        in data: Data,
        newID: UUID = UUID()
    ) -> (data: Data, id: UUID, didChange: Bool) {
        if let existing = id(in: data) {
            return (data, existing, false)
        }
        let updated = setting(idKey, to: newID.uuidString, in: data)
        return (updated, newID, true)
    }

    /// Sets the color. Written explicitly for every color, yellow included.
    public static func settingColor(_ color: NoteColor, in data: Data) -> Data {
        setting(colorKey, to: color.frontmatterValue, in: data)
    }

    // MARK: - Block parsing (internal for NoteHashing and tests)

    struct Field {
        var key: String
        var value: String
        /// Offset of the first byte of the line.
        var lineStart: Int
        /// Offset just past the line's content (before its terminator).
        var contentEnd: Int
        /// Offset just past the line's terminator.
        var lineEnd: Int
    }

    struct Block {
        var openingFenceStart: Int
        var closingFenceStart: Int
        /// Offset just past the closing fence line (its terminator included).
        var bodyStart: Int
        /// Terminator of the opening fence line, used for inserted lines.
        var lineEnding: [UInt8]
        var fields: [Field]
        /// False when the block also holds lines that aren't top-level `key: value` fields.
        var hasOnlyFieldLines: Bool
    }

    static let bom: [UInt8] = [0xEF, 0xBB, 0xBF]

    static func block(in bytes: [UInt8]) -> Block? {
        let start = bytes.starts(with: bom) ? bom.count : 0
        let opening = Line(in: bytes, from: start)
        guard opening.content(of: bytes).elementsEqual(fence), !opening.terminator.isEmpty else { return nil }

        var fields: [Field] = []
        var sawContent = false
        var onlyFields = true
        var cursor = opening.end

        while cursor < bytes.count {
            let line = Line(in: bytes, from: cursor)
            let content = line.content(of: bytes)

            if content.elementsEqual(fence) {
                guard sawContent else { return nil }
                return Block(
                    openingFenceStart: start,
                    closingFenceStart: line.start,
                    bodyStart: line.end,
                    lineEnding: opening.terminator,
                    fields: fields,
                    hasOnlyFieldLines: onlyFields
                )
            }

            let isBlank = content.allSatisfy { $0 == UInt8(ascii: " ") || $0 == UInt8(ascii: "\t") }
            let isComment = content.first == UInt8(ascii: "#")
            if let (key, value) = parseField(content) {
                sawContent = true
                fields.append(Field(
                    key: key,
                    value: value,
                    lineStart: line.start,
                    contentEnd: line.contentEnd,
                    lineEnd: line.end
                ))
            } else if !isBlank && !isComment {
                // The first meaningful line must be a field, or this isn't frontmatter.
                guard sawContent else { return nil }
                onlyFields = false
            } else {
                onlyFields = false
            }
            cursor = line.end
        }
        return nil
    }

    // MARK: - Private

    private static let fence = Array("---".utf8)

    /// One line: `start..<contentEnd` is the content, `contentEnd..<end` the terminator (`\n`, `\r\n` or none).
    private struct Line {
        var start: Int
        var contentEnd: Int
        var end: Int
        var terminator: [UInt8]

        init(in bytes: [UInt8], from start: Int) {
            self.start = start
            var newline = start
            while newline < bytes.count, bytes[newline] != UInt8(ascii: "\n") {
                newline += 1
            }
            if newline < bytes.count {
                let hasCR = newline > start && bytes[newline - 1] == UInt8(ascii: "\r")
                contentEnd = hasCR ? newline - 1 : newline
                end = newline + 1
            } else {
                contentEnd = newline
                end = newline
            }
            terminator = Array(bytes[contentEnd..<end])
        }

        func content(of bytes: [UInt8]) -> ArraySlice<UInt8> {
            bytes[start..<contentEnd]
        }
    }

    /// A top-level `key: value` line. Keys are `[A-Za-z0-9_.-]+` and start at column 0.
    private static func parseField(_ content: ArraySlice<UInt8>) -> (String, String)? {
        guard let colon = content.firstIndex(of: UInt8(ascii: ":")) else { return nil }
        let keyBytes = content[content.startIndex..<colon]
        guard !keyBytes.isEmpty, keyBytes.allSatisfy(isKeyByte) else { return nil }
        guard let key = String(bytes: keyBytes, encoding: .utf8),
              let rawValue = String(bytes: content[content.index(after: colon)...], encoding: .utf8)
        else { return nil }
        return (key, stripQuotes(rawValue.trimmingCharacters(in: .whitespaces)))
    }

    private static func isKeyByte(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "a")...UInt8(ascii: "z"),
             UInt8(ascii: "A")...UInt8(ascii: "Z"),
             UInt8(ascii: "0")...UInt8(ascii: "9"),
             UInt8(ascii: "_"), UInt8(ascii: "-"), UInt8(ascii: "."):
            return true
        default:
            return false
        }
    }

    private static func stripQuotes(_ value: String) -> String {
        guard value.count >= 2 else { return value }
        if (value.hasPrefix("\"") && value.hasSuffix("\""))
            || (value.hasPrefix("'") && value.hasSuffix("'")) {
            return String(value.dropFirst().dropLast())
        }
        return value
    }

    /// New block at the top (after a BOM), using the file's own line ending (LF by default).
    private static func prependingBlock(with line: [UInt8], to bytes: [UInt8]) -> [UInt8] {
        let hasBOM = bytes.starts(with: bom)
        let rest = Array(bytes.dropFirst(hasBOM ? bom.count : 0))
        let firstLine = Line(in: rest, from: 0)
        let eol = firstLine.terminator.isEmpty ? [UInt8(ascii: "\n")] : firstLine.terminator

        var result = hasBOM ? bom : []
        result += fence + eol + line + eol + fence + eol
        if !rest.isEmpty, !rest.starts(with: eol) {
            result += eol
        }
        return result + rest
    }
}
