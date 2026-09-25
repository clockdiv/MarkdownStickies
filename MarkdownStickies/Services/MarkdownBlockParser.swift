import Foundation

struct MarkdownBlock: Equatable, Identifiable {
    let id: String
    var source: String

    init(id: String = UUID().uuidString, source: String) {
        self.id = id
        self.source = source
    }
}

enum MarkdownBlockParser {
    /// Split Markdown into block-level chunks for Live Preview.
    static func parse(_ markdown: String) -> [MarkdownBlock] {
        let normalized = markdown.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        if normalized.isEmpty {
            return [MarkdownBlock(source: "")]
        }

        var blocks: [MarkdownBlock] = []
        let lines = normalized.components(separatedBy: "\n")
        var i = 0

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                // Preserve blank lines as visible spacer blocks (stickies keep empty lines).
                blocks.append(MarkdownBlock(source: ""))
                i += 1
                continue
            }

            // Fenced code
            if trimmed.hasPrefix("```") {
                var chunk = [line]
                i += 1
                while i < lines.count {
                    chunk.append(lines[i])
                    if lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                        i += 1
                        break
                    }
                    i += 1
                }
                blocks.append(MarkdownBlock(source: chunk.joined(separator: "\n")))
                continue
            }

            // Table: header + separator + rows
            if isTableHeader(lines: lines, at: i) {
                var chunk = [line]
                i += 1
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    if t.contains("|") {
                        chunk.append(lines[i])
                        i += 1
                    } else {
                        break
                    }
                }
                blocks.append(MarkdownBlock(source: chunk.joined(separator: "\n")))
                continue
            }

            // Indented code (tab or 4 spaces)
            if isIndentedCodeLine(line) {
                var chunk = [line]
                i += 1
                while i < lines.count, isIndentedCodeLine(lines[i]) || lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
                    // stop on blank line followed by non-indented
                    if lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
                        if i + 1 < lines.count, !isIndentedCodeLine(lines[i + 1]) {
                            break
                        }
                    }
                    chunk.append(lines[i])
                    i += 1
                }
                blocks.append(MarkdownBlock(source: chunk.joined(separator: "\n")))
                continue
            }

            // List block
            if isListLine(trimmed) {
                var chunk = [line]
                i += 1
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    if isListLine(t) || (lines[i].hasPrefix("  ") || lines[i].hasPrefix("\t")) && !t.isEmpty {
                        chunk.append(lines[i])
                        i += 1
                    } else if t.isEmpty, i + 1 < lines.count, isListLine(lines[i + 1].trimmingCharacters(in: .whitespaces)) {
                        chunk.append(lines[i])
                        i += 1
                    } else {
                        break
                    }
                }
                blocks.append(MarkdownBlock(source: chunk.joined(separator: "\n")))
                continue
            }

            // Blockquote
            if trimmed.hasPrefix(">") {
                var chunk = [line]
                i += 1
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    chunk.append(lines[i])
                    i += 1
                }
                blocks.append(MarkdownBlock(source: chunk.joined(separator: "\n")))
                continue
            }

            // Heading (single line)
            if headingLevel(trimmed) != nil {
                blocks.append(MarkdownBlock(source: line))
                i += 1
                continue
            }

            // Horizontal rule
            if isRule(trimmed) {
                blocks.append(MarkdownBlock(source: line))
                i += 1
                continue
            }

            // Paragraph (until blank / new block)
            var chunk = [line]
            i += 1
            while i < lines.count {
                let next = lines[i]
                let t = next.trimmingCharacters(in: .whitespaces)
                if t.isEmpty { break }
                if t.hasPrefix("```")
                    || isListLine(t)
                    || t.hasPrefix(">")
                    || headingLevel(t) != nil
                    || isRule(t)
                    || isIndentedCodeLine(next)
                    || isTableHeader(lines: lines, at: i) {
                    break
                }
                chunk.append(next)
                i += 1
            }
            blocks.append(MarkdownBlock(source: chunk.joined(separator: "\n")))
        }

        return blocks.isEmpty ? [MarkdownBlock(source: "")] : blocks
    }

    static func join(_ blocks: [MarkdownBlock]) -> String {
        // Single newlines: blank blocks (source "") already represent empty lines.
        blocks.map(\.source).joined(separator: "\n")
    }

    // MARK: - Helpers

    private static func isListLine(_ trimmed: String) -> Bool {
        for m in ["- ", "* ", "+ "] where trimmed.hasPrefix(m) { return true }
        guard let dot = trimmed.firstIndex(of: ".") else { return false }
        let num = trimmed[trimmed.startIndex..<dot]
        guard !num.isEmpty, num.allSatisfy(\.isNumber) else { return false }
        let after = trimmed.index(after: dot)
        return after < trimmed.endIndex && trimmed[after] == " "
    }

    private static func isIndentedCodeLine(_ line: String) -> Bool {
        line.hasPrefix("\t") || line.hasPrefix("    ")
    }

    private static func isRule(_ trimmed: String) -> Bool {
        let compact = trimmed.replacingOccurrences(of: " ", with: "")
        guard compact.count >= 3 else { return false }
        return compact.allSatisfy { $0 == "-" }
            || compact.allSatisfy { $0 == "*" }
            || compact.allSatisfy { $0 == "_" }
    }

    private static func headingLevel(_ trimmed: String) -> Int? {
        guard trimmed.hasPrefix("#") else { return nil }
        var level = 0
        for ch in trimmed {
            if ch == "#" { level += 1 } else { break }
        }
        guard (1...6).contains(level) else { return nil }
        let rest = trimmed.dropFirst(level)
        guard rest.isEmpty || rest.first == " " else { return nil }
        return level
    }

    private static func isTableHeader(lines: [String], at index: Int) -> Bool {
        guard index + 1 < lines.count else { return false }
        let header = lines[index].trimmingCharacters(in: .whitespaces)
        let sep = lines[index + 1].trimmingCharacters(in: .whitespaces)
        guard header.contains("|"), sep.contains("|") else { return false }
        let cells = sep.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !cells.isEmpty else { return false }
        return cells.allSatisfy { cell in
            !cell.isEmpty && cell.allSatisfy { $0 == "-" || $0 == ":" }
        }
    }
}
