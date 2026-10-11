import Foundation

/// Finds the local images a note references (spec §2.4).
///
/// Recognized: `![alt](path)`, `![alt](path "title")`, `![alt](<path with spaces>)` and
/// `<img src="path">`. Paths are percent-decoded and resolved relative to the note.
/// Remote URLs, absolute paths, paths that leave the root and non-image files are ignored.
/// There is no fallback by file name: a reference either resolves or it doesn't.
/// Fenced code blocks are skipped.
public enum ImageReferences {
    /// Root-relative image paths (NFC), in order of first appearance, without duplicates.
    ///
    /// - Parameter noteDirectory: the note's folder relative to its root (`""` for the root itself).
    public static func paths(in markdown: String, noteDirectory: String) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for raw in rawDestinations(in: markdown) {
            guard let path = resolve(raw, noteDirectory: noteDirectory), seen.insert(path).inserted else { continue }
            result.append(path)
        }
        return result
    }

    /// File URL an editor shows or opens for an image destination: web and `file:` URLs as they
    /// are, relative paths resolved against the note's folder (percent-decoded). No fallback
    /// by file name, so a broken reference shows as broken.
    public static func fileURL(forDestination raw: String, noteDirectory: URL) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let lower = trimmed.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("file:") {
            return URL(string: trimmed)
        }
        guard !hasScheme(trimmed), !trimmed.hasPrefix("/") else { return nil }
        let decoded = trimmed.removingPercentEncoding ?? trimmed
        let ext = (decoded as NSString).pathExtension.lowercased()
        guard PathRules.imageExtensions.contains(ext) else { return nil }
        return noteDirectory.appendingPathComponent(decoded).standardizedFileURL
    }

    /// Image destinations as written in the note, before resolving.
    static func rawDestinations(in markdown: String) -> [String] {
        var result: [String] = []
        var inFence = false
        var text = ""
        for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                inFence.toggle()
                continue
            }
            if !inFence { text += line + "\n" }
        }
        result += markdownImageDestinations(in: text)
        result += htmlImageSources(in: text)
        return result
    }

    /// Resolves one destination to a root-relative image path, or `nil`.
    static func resolve(_ raw: String, noteDirectory: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !hasScheme(trimmed), !trimmed.hasPrefix("/") else { return nil }
        let decoded = trimmed.removingPercentEncoding ?? trimmed

        var components = noteDirectory.split(separator: "/").map(String.init)
        for part in decoded.split(separator: "/", omittingEmptySubsequences: true) {
            switch part {
            case ".":
                continue
            case "..":
                guard !components.isEmpty else { return nil }   // would leave the root
                components.removeLast()
            default:
                components.append(String(part))
            }
        }
        guard case .success(let path) = PathRules.validate(components.joined(separator: "/"), as: .image) else {
            return nil
        }
        return path
    }

    // MARK: - Private

    /// `scheme:` per RFC 3986 (`http:`, `https:`, `data:`, `file:`, …).
    private static func hasScheme(_ text: String) -> Bool {
        guard let colon = text.firstIndex(of: ":") else { return false }
        let scheme = text[..<colon]
        guard let first = scheme.first, first.isLetter else { return false }
        return scheme.allSatisfy { $0.isLetter || $0.isNumber || $0 == "+" || $0 == "-" || $0 == "." }
    }

    private static func markdownImageDestinations(in text: String) -> [String] {
        var result: [String] = []
        let chars = Array(text)
        var index = 0
        while index + 1 < chars.count {
            guard chars[index] == "!", chars[index + 1] == "[" else {
                index += 1
                continue
            }
            // Alt text: up to the matching "]".
            var cursor = index + 2
            var depth = 1
            while cursor < chars.count, depth > 0 {
                if chars[cursor] == "[" { depth += 1 }
                if chars[cursor] == "]" { depth -= 1 }
                if chars[cursor] == "\n" { break }
                cursor += 1
            }
            guard depth == 0, cursor < chars.count, chars[cursor] == "(" else {
                index += 2
                continue
            }
            cursor += 1
            while cursor < chars.count, chars[cursor] == " " { cursor += 1 }

            var destination = ""
            if cursor < chars.count, chars[cursor] == "<" {
                cursor += 1
                while cursor < chars.count, chars[cursor] != ">", chars[cursor] != "\n" {
                    destination.append(chars[cursor])
                    cursor += 1
                }
            } else {
                // Unbracketed: ends at whitespace or the ")" that closes the link; balanced parentheses allowed.
                var parens = 0
                while cursor < chars.count {
                    let c = chars[cursor]
                    if c == " " || c == "\t" || c == "\n" { break }
                    if c == "(" { parens += 1 }
                    if c == ")" {
                        if parens == 0 { break }
                        parens -= 1
                    }
                    destination.append(c)
                    cursor += 1
                }
            }
            if !destination.isEmpty { result.append(destination) }
            index = cursor
        }
        return result
    }

    private static let imgTag = try! NSRegularExpression(
        pattern: #"<img\b[^>]*?\bsrc\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))"#,
        options: [.caseInsensitive]
    )

    private static func htmlImageSources(in text: String) -> [String] {
        let range = NSRange(text.startIndex..., in: text)
        return imgTag.matches(in: text, range: range).compactMap { match in
            for group in 1...3 {
                if let r = Range(match.range(at: group), in: text) { return String(text[r]) }
            }
            return nil
        }
    }
}
