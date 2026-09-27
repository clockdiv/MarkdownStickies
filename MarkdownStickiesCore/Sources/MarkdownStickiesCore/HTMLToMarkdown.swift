#if os(macOS)
import Foundation

/// Converts HTML note bodies to Markdown (CommonMark-ish) with optional residual HTML for unsupported bits.
///
/// Conversion is selective: unchecked tags stay as raw HTML; checked tags convert / unwrap / strip per kind.
public enum HTMLToMarkdown {
    public struct Result: Equatable, Sendable {
        public var markdown: String
        public var convertedTags: Int
        public var residualHTMLBlocks: Int
        public var strippedTags: Int

        public init(markdown: String, convertedTags: Int, residualHTMLBlocks: Int, strippedTags: Int) {
            self.markdown = markdown
            self.convertedTags = convertedTags
            self.residualHTMLBlocks = residualHTMLBlocks
            self.strippedTags = strippedTags
        }

        /// True when at least one tag was converted, unwrapped, stripped, or left residual.
        public var didChange: Bool {
            convertedTags > 0 || residualHTMLBlocks > 0 || strippedTags > 0
        }
    }

    public enum TagKind: String, Sendable, Equatable {
        /// Maps to Markdown syntax (`**`, links, headings, …).
        case markdown
        /// Drop the tag; keep children / text.
        case unwrap
        /// Drop the element entirely (script, style, …).
        case strip
        /// No built-in rule — leave as HTML unless the user opts in to unwrap.
        case unknown
    }

    public struct TagInfo: Identifiable, Equatable, Sendable {
        public var id: String { name }
        public var name: String
        public var count: Int
        public var kind: TagKind
        /// Default checklist state for this tag.
        public var defaultEnabled: Bool
        public var detail: String

        public init(name: String, count: Int, kind: TagKind, defaultEnabled: Bool, detail: String) {
            self.name = name
            self.count = count
            self.kind = kind
            self.defaultEnabled = defaultEnabled
            self.detail = detail
        }
    }

    /// Tags that become Markdown when enabled.
    private static let markdownTags: Set<String> = [
        "h1", "h2", "h3", "h4", "h5", "h6",
        "p", "br", "hr",
        "strong", "b", "em", "i", "s", "del", "strike",
        "code", "pre", "blockquote",
        "ul", "ol", "li",
        "a", "img", "table",
    ]

    /// Structural wrappers → keep text only.
    private static let unwrapTags: Set<String> = [
        "div", "span", "section", "article", "main", "header", "footer", "aside", "nav",
        "figure", "figcaption", "center", "font", "u", "o:p",
    ]

    private static let stripTags: Set<String> = [
        "script", "style", "noscript", "template", "link", "meta", "head", "title",
    ]

    /// HTML comments tidy keeps; used so author newlines are not collapsed into spaces.
    private static let newlineMarkerComment = "ms-nl"

    // MARK: - Public API

    public static func looksLikeHTML(_ text: String) -> Bool {
        text.range(of: #"<[A-Za-z][^>]*>"#, options: .regularExpression) != nil
    }

    public static func inventory(in html: String) -> [TagInfo] {
        guard let root = parseDocument(html) else { return [] }
        var counts: [String: Int] = [:]
        collectTags(from: root, into: &counts)
        return counts.keys.sorted().map { name in
            let kind = kind(for: name)
            return TagInfo(
                name: name,
                count: counts[name] ?? 0,
                kind: kind,
                defaultEnabled: defaultEnabled(for: name, kind: kind),
                detail: detail(for: name, kind: kind)
            )
        }
    }

    public static func defaultEnabledTags(in html: String) -> Set<String> {
        Set(inventory(in: html).filter(\.defaultEnabled).map(\.name))
    }

    public static func kind(for tag: String) -> TagKind {
        let name = tag.lowercased()
        if markdownTags.contains(name) { return .markdown }
        if unwrapTags.contains(name) { return .unwrap }
        if stripTags.contains(name) { return .strip }
        return .unknown
    }

    public static func defaultEnabled(for tag: String, kind: TagKind? = nil) -> Bool {
        let k = kind ?? Self.kind(for: tag)
        switch k {
        case .markdown, .unwrap, .strip: return true
        case .unknown: return false
        }
    }

    /// Convert with default checklist (known tags on, unknown off).
    public static func convert(_ html: String) -> Result {
        convert(html, enabledTags: defaultEnabledTags(in: html))
    }

    /// Convert only tags listed in `enabledTags`. Others are left as residual HTML.
    public static func convert(_ html: String, enabledTags: Set<String>) -> Result {
        let enabled = Set(enabledTags.map { $0.lowercased() })
        guard let root = parseDocument(html) else {
            return Result(markdown: html, convertedTags: 0, residualHTMLBlocks: 0, strippedTags: 0)
        }

        var ctx = EmitContext(enabledTags: enabled)
        emitChildren(of: root, into: &ctx, block: true)
        var md = ctx.buffer
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        while md.contains("\n\n\n") {
            md = md.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        }
        md = md.trimmingCharacters(in: CharacterSet(charactersIn: "\n"))
        if !md.isEmpty { md += "\n" }

        return Result(
            markdown: md,
            convertedTags: ctx.convertedTags,
            residualHTMLBlocks: ctx.residualHTMLBlocks,
            strippedTags: ctx.strippedTags
        )
    }

    // MARK: - Parse

    private static func parseDocument(_ html: String) -> XMLElement? {
        let protected = protectNewlines(in: html)
        let wrapped = """
        <!DOCTYPE html><html><head><meta charset="utf-8"></head><body>\(protected)</body></html>
        """
        do {
            // Prefer xmlString so Unicode in the source isn't re-decoded as Latin-1 by tidy.
            let doc = try XMLDocument(
                xmlString: wrapped,
                options: [
                    .documentTidyHTML,
                    .nodePreserveWhitespace,
                    .nodeLoadExternalEntitiesNever,
                ]
            )
            doc.characterEncoding = "UTF-8"
            return doc.rootElement()
        } catch {
            return nil
        }
    }

    private static func protectNewlines(in html: String) -> String {
        let marker = "<!--\(newlineMarkerComment)-->"
        var out = ""
        out.reserveCapacity(html.count + html.filter { $0 == "\n" || $0 == "\r" }.count * marker.count)
        var i = html.startIndex
        while i < html.endIndex {
            let ch = html[i]
            if ch == "\r" {
                let next = html.index(after: i)
                if next < html.endIndex, html[next] == "\n" {
                    out += marker
                    i = html.index(after: next)
                    continue
                }
                out += marker
                i = next
                continue
            }
            if ch == "\n" {
                out += marker
                i = html.index(after: i)
                continue
            }
            out.append(ch)
            i = html.index(after: i)
        }
        return out
    }

    // MARK: - Inventory walk

    private static func collectTags(from node: XMLNode, into counts: inout [String: Int]) {
        guard let element = node as? XMLElement else {
            for child in node.children ?? [] {
                collectTags(from: child, into: &counts)
            }
            return
        }
        let name = (element.name ?? "").lowercased()
        if name == "head" {
            // Document chrome (ours or tidy-moved) — never inventory / never residual.
            return
        }
        if !name.isEmpty, name != "html", name != "body" {
            counts[name, default: 0] += 1
        }
        for child in element.children ?? [] {
            collectTags(from: child, into: &counts)
        }
    }

    private static func detail(for name: String, kind: TagKind) -> String {
        switch kind {
        case .markdown:
            switch name {
            case "h1", "h2", "h3", "h4", "h5", "h6": return "→ Markdown heading"
            case "p": return "→ paragraph"
            case "br": return "→ line break"
            case "hr": return "→ ---"
            case "strong", "b": return "→ **bold**"
            case "em", "i": return "→ *italic*"
            case "s", "del", "strike": return "→ ~~strike~~"
            case "a": return "→ [label](url) or bare URL"
            case "img": return "→ ![alt](src)"
            case "ul", "ol", "li": return "→ list"
            case "blockquote": return "→ > quote"
            case "pre", "code": return "→ code"
            case "table": return "→ Markdown table"
            default: return "→ Markdown"
            }
        case .unwrap:
            if name == "u" { return "unwrap (drop underline)" }
            return "unwrap (keep text)"
        case .strip:
            return "remove entirely"
        case .unknown:
            return "leave as HTML (or unwrap if checked)"
        }
    }

    // MARK: - Emit

    private struct ListState {
        var ordered: Bool
        var index: Int
    }

    private struct EmitContext {
        var enabledTags: Set<String>
        var buffer = ""
        var listStack: [ListState] = []
        var convertedTags = 0
        var residualHTMLBlocks = 0
        var strippedTags = 0
    }

    private static func isEnabled(_ name: String, ctx: EmitContext) -> Bool {
        ctx.enabledTags.contains(name)
    }

    private static func emitChildren(of parent: XMLNode, into ctx: inout EmitContext, block: Bool) {
        for child in parent.children ?? [] {
            emit(node: child, into: &ctx, block: block)
        }
    }

    private static func emit(node: XMLNode, into ctx: inout EmitContext, block: Bool) {
        switch node.kind {
        case .text:
            let raw = node.stringValue ?? ""
            let cleaned = raw
                .replacingOccurrences(of: "\u{00a0}", with: " ")
            if block {
                ctx.buffer += cleaned
            } else {
                ctx.buffer += cleaned.replacingOccurrences(of: "\n", with: " ")
            }
        case .comment:
            let text = (node.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if text == newlineMarkerComment {
                ctx.buffer += "\n"
            }
        case .element:
            guard let element = node as? XMLElement else { return }
            emit(element: element, into: &ctx)
        default:
            break
        }
    }

    private static func emit(element: XMLElement, into ctx: inout EmitContext) {
        let name = (element.name ?? "").lowercased()

        if name == "html" || name == "body" {
            emitChildren(of: element, into: &ctx, block: true)
            return
        }

        // Always drop document <head> (wrapper meta/title, tidy-moved style/script).
        if name == "head" {
            ctx.strippedTags += 1
            return
        }

        // Unchecked → keep raw HTML subtree.
        if !name.isEmpty, !isEnabled(name, ctx: ctx) {
            appendResidual(element, into: &ctx)
            return
        }

        let tagKind = kind(for: name)

        if tagKind == .strip {
            ctx.strippedTags += 1
            return
        }

        if tagKind == .unwrap {
            ctx.convertedTags += 1
            let asBlock = ["div", "section", "article", "figure", "main", "header", "footer", "aside", "nav"].contains(name)
            emitChildren(of: element, into: &ctx, block: asBlock)
            if asBlock {
                ensureEndsWithNewline(&ctx)
            }
            return
        }

        if tagKind == .unknown {
            // Checked unknown → unwrap (user explicitly wants conversion).
            ctx.convertedTags += 1
            emitChildren(of: element, into: &ctx, block: true)
            return
        }

        // markdown tags
        switch name {
        case "h1", "h2", "h3", "h4", "h5", "h6":
            ctx.convertedTags += 1
            ensureStartsOnOwnLine(&ctx)
            let level = Int(String(name.dropFirst())) ?? 1
            ctx.buffer += String(repeating: "#", count: level) + " "
            emitChildren(of: element, into: &ctx, block: false)
            ensureEndsWithNewline(&ctx)

        case "p":
            ctx.convertedTags += 1
            ensureStartsOnOwnLine(&ctx)
            emitChildren(of: element, into: &ctx, block: false)
            if !ctx.buffer.hasSuffix("\n\n") {
                if ctx.buffer.hasSuffix("\n") {
                    ctx.buffer += "\n"
                } else {
                    ctx.buffer += "\n\n"
                }
            }

        case "br":
            ctx.convertedTags += 1
            ctx.buffer += "\n"

        case "hr":
            ctx.convertedTags += 1
            ensureStartsOnOwnLine(&ctx)
            ctx.buffer += "---\n"

        case "strong", "b":
            ctx.convertedTags += 1
            ctx.buffer += "**"
            emitChildren(of: element, into: &ctx, block: false)
            ctx.buffer += "**"

        case "em", "i":
            ctx.convertedTags += 1
            ctx.buffer += "*"
            emitChildren(of: element, into: &ctx, block: false)
            ctx.buffer += "*"

        case "s", "del", "strike":
            ctx.convertedTags += 1
            ctx.buffer += "~~"
            emitChildren(of: element, into: &ctx, block: false)
            ctx.buffer += "~~"

        case "code":
            ctx.convertedTags += 1
            let text = element.stringValue ?? ""
            ctx.buffer += "`\(text.replacingOccurrences(of: "`", with: "\\`"))`"

        case "pre":
            ctx.convertedTags += 1
            ensureStartsOnOwnLine(&ctx)
            let code = codeText(from: element)
            ctx.buffer += "```\n\(code)\n```\n"

        case "blockquote":
            ctx.convertedTags += 1
            ensureStartsOnOwnLine(&ctx)
            var inner = EmitContext(enabledTags: ctx.enabledTags)
            emitChildren(of: element, into: &inner, block: true)
            let quoted = inner.buffer
                .trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
                .components(separatedBy: "\n")
                .map { line in
                    let t = line.trimmingCharacters(in: .whitespaces)
                    return t.isEmpty ? ">" : "> \(t)"
                }
                .joined(separator: "\n")
            ctx.buffer += quoted
            ensureEndsWithNewline(&ctx)
            ctx.convertedTags += inner.convertedTags
            ctx.residualHTMLBlocks += inner.residualHTMLBlocks
            ctx.strippedTags += inner.strippedTags

        case "ul":
            ctx.convertedTags += 1
            ensureStartsOnOwnLine(&ctx)
            ctx.listStack.append(ListState(ordered: false, index: 0))
            emitChildren(of: element, into: &ctx, block: true)
            ctx.listStack.removeLast()
            ensureEndsWithNewline(&ctx)

        case "ol":
            ctx.convertedTags += 1
            ensureStartsOnOwnLine(&ctx)
            ctx.listStack.append(ListState(ordered: true, index: 0))
            emitChildren(of: element, into: &ctx, block: true)
            ctx.listStack.removeLast()
            ensureEndsWithNewline(&ctx)

        case "li":
            ctx.convertedTags += 1
            ensureStartsOnOwnLine(&ctx)
            let depth = max(ctx.listStack.count - 1, 0)
            let indent = String(repeating: "  ", count: depth)
            if var state = ctx.listStack.last {
                if state.ordered {
                    state.index += 1
                    ctx.listStack[ctx.listStack.count - 1] = state
                    ctx.buffer += "\(indent)\(state.index). "
                } else {
                    ctx.buffer += "\(indent)- "
                }
            } else {
                ctx.buffer += "- "
            }
            emitChildren(of: element, into: &ctx, block: false)
            ensureEndsWithNewline(&ctx)

        case "a":
            ctx.convertedTags += 1
            let href = (attribute(element, "href") ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            var labelCtx = EmitContext(enabledTags: ctx.enabledTags)
            emitChildren(of: element, into: &labelCtx, block: false)
            let label = labelCtx.buffer
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if href.isEmpty {
                ctx.buffer += label
            } else if label.isEmpty || linkLabelIsRedundantURL(label, href: href) {
                ctx.buffer += href
            } else {
                ctx.buffer += "[\(label)](\(href))"
            }

        case "img":
            ctx.convertedTags += 1
            let src = attribute(element, "src") ?? ""
            let alt = attribute(element, "alt") ?? ""
            if !src.isEmpty {
                ctx.buffer += "![\(alt)](\(src))"
            }

        case "table":
            if let md = convertTable(element) {
                ctx.convertedTags += 1
                ensureStartsOnOwnLine(&ctx)
                ctx.buffer += md
                ensureEndsWithNewline(&ctx)
            } else {
                appendResidual(element, into: &ctx)
            }

        default:
            appendResidual(element, into: &ctx)
        }
    }

    private static func linkLabelIsRedundantURL(_ label: String, href: String) -> Bool {
        func normalize(_ s: String) -> String {
            var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.hasSuffix("/") { t.removeLast() }
            if let scheme = t.range(of: "://") {
                t = String(t[scheme.upperBound...])
            }
            if t.lowercased().hasPrefix("www.") {
                t = String(t.dropFirst(4))
            }
            return t.lowercased()
        }
        return normalize(label) == normalize(href)
    }

    private static func convertTable(_ table: XMLElement) -> String? {
        var rows: [[String]] = []
        func walk(_ node: XMLNode) {
            guard let el = node as? XMLElement else { return }
            let n = (el.name ?? "").lowercased()
            if n == "tr" {
                var cells: [String] = []
                for child in el.children ?? [] {
                    guard let cell = child as? XMLElement else { continue }
                    let cn = (cell.name ?? "").lowercased()
                    if cn == "td" || cn == "th" {
                        let text = (cell.stringValue ?? "")
                            .replacingOccurrences(of: "\n", with: " ")
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                            .replacingOccurrences(of: "|", with: "\\|")
                        cells.append(text)
                    }
                }
                if !cells.isEmpty { rows.append(cells) }
            } else {
                for child in el.children ?? [] { walk(child) }
            }
        }
        walk(table)
        guard let header = rows.first, !header.isEmpty else { return nil }
        let width = header.count
        let normalized = rows.map { row -> [String] in
            if row.count == width { return row }
            if row.count > width { return Array(row.prefix(width)) }
            return row + Array(repeating: "", count: width - row.count)
        }
        var lines: [String] = []
        lines.append("| " + normalized[0].joined(separator: " | ") + " |")
        lines.append("| " + Array(repeating: "---", count: width).joined(separator: " | ") + " |")
        for row in normalized.dropFirst() {
            lines.append("| " + row.joined(separator: " | ") + " |")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func appendResidual(_ element: XMLElement, into ctx: inout EmitContext) {
        ctx.residualHTMLBlocks += 1
        let xml = element.xmlString
        ensureStartsOnOwnLine(&ctx)
        ctx.buffer += xml
        ensureEndsWithNewline(&ctx)
    }

    private static func codeText(from element: XMLElement) -> String {
        if let code = element.children?.compactMap({ $0 as? XMLElement }).first(where: { ($0.name ?? "").lowercased() == "code" }) {
            return code.stringValue ?? ""
        }
        return element.stringValue ?? ""
    }

    private static func attribute(_ element: XMLElement, _ name: String) -> String? {
        element.attribute(forName: name)?.stringValue
    }

    private static func ensureStartsOnOwnLine(_ ctx: inout EmitContext) {
        if ctx.buffer.isEmpty { return }
        if !ctx.buffer.hasSuffix("\n") {
            ctx.buffer += "\n"
        }
    }

    private static func ensureEndsWithNewline(_ ctx: inout EmitContext) {
        if ctx.buffer.isEmpty { return }
        if !ctx.buffer.hasSuffix("\n") {
            ctx.buffer += "\n"
        }
    }
}

#endif
