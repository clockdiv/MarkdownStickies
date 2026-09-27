import AppKit
import UniformTypeIdentifiers
import WebKit

/// Obsidian-style Live Preview hosted entirely in AppKit (no SwiftUI / NSHostingView).
@MainActor
final class LivePreviewView: NSView, WKNavigationDelegate, WKScriptMessageHandler {
    var onTextChange: ((String) -> Void)?
    /// Flush the note to disk immediately (e.g. after an image drop).
    var onRequestImmediateSave: (() -> Void)?

    private var noteURL: URL

    func updateNoteURL(_ url: URL) {
        noteURL = url
    }
    private var background: NSColor
    private var fontSize: Double
    private var columnCount: Int
    private let webView: ImageDropWKWebView
    /// Retained because WKUserContentController keeps only an unowned-style ref pattern via the config.
    private let messageProxy: ScriptMessageProxy
    private var pasteMonitor: Any?
    /// Drop target from draggingUpdated (AppKit coords — must match the blue caret line).
    private var cachedDropTarget: [String: Any]?
    /// Locked in on drop; HTML5 file bytes reuse this so placement matches the caret.
    private var pendingDropTarget: [String: Any]?
    /// Nearest inter-block gap under the pointer (source of truth for caret + insert).
    private var pendingInsertIndex: Int?
    /// Prevent AppKit + HTML5 double-insert of the same drop.
    private var lastImageDropAt: Date?
    private var allowingHTMLLoad = false
    /// Restore scroll after loadHTMLString (click-to-edit used to jump the page).
    private var pendingScrollY: Double?
    /// Block frames in DOM client coords, refreshed while dragging.
    private var dropBlockFrames: [(index: Int, top: CGFloat, bottom: CGFloat)] = []
    /// Viewport height reported by the page (more reliable than webView.bounds for DOM Y).
    private var dropViewportHeight: CGFloat = 0
    private let dropCaretLine = DropCaretLineView()
    private let dropDebugLabel = DropDebugLabel()
    /// Temporary: on-screen drop diagnostics (remove once placement is correct).
    private let dropDebugEnabled = false

    /// One insertion slot between blocks (or before first / after last).
    private struct DropGap {
        /// `blocks.insert(_, at: insertIndex)` — 0...blocks.count
        var insertIndex: Int
        /// AppKit y in webView coords (from bottom), same space as the mouse.
        var appKitY: CGFloat
        var mapping: String
    }

    private var blocks: [MarkdownBlock] = [MarkdownBlock(source: "")]
    private var activeIndex: Int? = 0
    private var pendingHTML: String?
    private var suppressPublish = false
    /// Caret to restore after the next reload (click-to-edit / cross-block nav).
    private var pendingCaretOffset: Int?

    private struct EditorSnapshot {
        var blocks: [MarkdownBlock]
        var activeIndex: Int?
        var caret: Int?
    }
    private var undoStack: [EditorSnapshot] = []
    private var redoStack: [EditorSnapshot] = []
    private var lastUndoCoalesceAt: Date?
    private var lastUndoBlockIndex: Int?
    private let undoCoalesceInterval: TimeInterval = 1.2

    var markdown: String {
        get { MarkdownBlockParser.join(blocks) }
        set {
            guard newValue != MarkdownBlockParser.join(blocks) else { return }
            suppressPublish = true
            bootstrap(text: newValue)
            suppressPublish = false
        }
    }

    /// Re-render HTML without changing markdown (e.g. images arrived via sync).
    func reloadPreviewMedia() {
        reloadHTML()
    }

    init(
        noteURL: URL,
        text: String,
        background: NSColor,
        fontSize: Double = NoteWindowState.defaultTextSize,
        columnCount: Int = NoteWindowState.defaultColumnCount
    ) {
        self.noteURL = noteURL
        self.background = background
        self.fontSize = fontSize
        self.columnCount = NoteWindowState.clampedColumnCount(columnCount)

        let proxy = ScriptMessageProxy()
        self.messageProxy = proxy

        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
        for name in ["activate", "edit", "openURL", "commit", "append", "navigate", "moveLineAcross", "deleteEmptyBlock", "insertEmptyBelow", "splitBlock", "imageDrop"] {
            config.userContentController.add(proxy, name: name)
        }

        let wv = ImageDropWKWebView(
            frame: NSRect(x: 0, y: 0, width: 320, height: 400),
            configuration: config
        )
        wv.setValue(false, forKey: "drawsBackground")
        if #available(macOS 12.0, *) {
            wv.underPageBackgroundColor = background
        }
        self.webView = wv

        super.init(frame: .zero)

        proxy.target = self
        wv.dropDestination = self
        wantsLayer = true
        layer?.backgroundColor = background.cgColor

        wv.navigationDelegate = self
        wv.translatesAutoresizingMaskIntoConstraints = false
        addSubview(wv)
        NSLayoutConstraint.activate([
            wv.topAnchor.constraint(equalTo: topAnchor),
            wv.bottomAnchor.constraint(equalTo: bottomAnchor),
            wv.leadingAnchor.constraint(equalTo: leadingAnchor),
            wv.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])

        let dragTypes: [NSPasteboard.PasteboardType] = [
            .fileURL,
            .tiff,
            .png,
            NSPasteboard.PasteboardType(UTType.jpeg.identifier),
            NSPasteboard.PasteboardType(UTType.gif.identifier),
            NSPasteboard.PasteboardType(UTType.webP.identifier),
            NSPasteboard.PasteboardType(UTType.heic.identifier),
            NSPasteboard.PasteboardType(UTType.image.identifier),
        ]
        registerForDraggedTypes(dragTypes)
        wv.registerForDraggedTypes(dragTypes)
        setupPasteMonitor()

        dropCaretLine.translatesAutoresizingMaskIntoConstraints = true
        dropCaretLine.isHidden = true
        addSubview(dropCaretLine)
        dropDebugLabel.isHidden = true
        addSubview(dropDebugLabel)

        bootstrap(text: text)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeKeyAndOrderFront(nil)
        super.mouseDown(with: event)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let pasteMonitor {
            NSEvent.removeMonitor(pasteMonitor)
        }
    }

    func applyBackground(_ color: NSColor) {
        background = color
        layer?.backgroundColor = color.cgColor
        if #available(macOS 12.0, *) {
            webView.underPageBackgroundColor = color
        }
        reloadHTML()
    }

    func applyFontSize(_ size: Double) {
        let clamped = min(NoteWindowState.maxTextSize, max(NoteWindowState.minTextSize, size))
        guard abs(fontSize - clamped) > 0.01 else { return }
        fontSize = clamped
        let px = String(format: "%.1f", clamped)
        webView.evaluateJavaScript(
            """
            document.documentElement.style.fontSize = '\(px)px';
            document.body.style.fontSize = '\(px)px';
            var ta = document.querySelector('textarea.source');
            if (ta) { ta.style.fontSize = '\(px)px'; }
            """
        )
    }

    func applyColumnCount(_ count: Int) {
        let clamped = NoteWindowState.clampedColumnCount(count)
        guard columnCount != clamped else { return }
        columnCount = clamped
        // Column layout rules live in the stylesheet; reload so flex/column CSS switches cleanly.
        reloadHTML()
    }

    func focusEditor() {
        window?.makeFirstResponder(webView)
    }

    // MARK: - Engine

    private func bootstrap(text: String) {
        blocks = MarkdownBlockParser.parse(text)
        if blocks.isEmpty { blocks = [MarkdownBlock(source: "")] }
        let onlyEmpty = blocks.count == 1
            && blocks[0].source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        // Empty note → edit immediately; otherwise start fully rendered (Obsidian-like).
        activeIndex = onlyEmpty ? 0 : nil
        undoStack.removeAll()
        redoStack.removeAll()
        lastUndoCoalesceAt = nil
        lastUndoBlockIndex = nil
        reloadHTML()
    }

    private func composedMarkdown() -> String {
        MarkdownBlockParser.join(blocks)
    }

    private func publish() {
        guard !suppressPublish else { return }
        onTextChange?(composedMarkdown())
    }

    private func activateBlock(_ index: Int, caretOffset: Int? = nil) {
        let previous = blocks
        let targetSource: String? = previous.indices.contains(index) ? previous[index].source : nil
        blocks = MarkdownBlockParser.parse(composedMarkdown())
        if blocks.isEmpty { blocks = [MarkdownBlock(source: "")] }

        if let targetSource {
            // Prefer same index when duplicates exist (e.g. several blank lines).
            if blocks.indices.contains(index), blocks[index].source == targetSource {
                activeIndex = index
            } else if let match = blocks.firstIndex(where: { $0.source == targetSource }) {
                activeIndex = match
            } else {
                activeIndex = min(max(0, index), blocks.count - 1)
            }
        } else {
            activeIndex = min(max(0, index), blocks.count - 1)
        }

        if let caretOffset, let activeIndex, blocks.indices.contains(activeIndex) {
            pendingCaretOffset = min(max(0, caretOffset), blocks[activeIndex].source.count)
        } else {
            pendingCaretOffset = nil
        }

        reloadHTML()
        window?.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async { [weak self] in
            self?.window?.makeFirstResponder(self?.webView)
        }
    }

    private func currentSnapshot(caret: Int? = nil) -> EditorSnapshot {
        EditorSnapshot(blocks: blocks.map { MarkdownBlock(id: $0.id, source: $0.source) }, activeIndex: activeIndex, caret: caret)
    }

    /// Record state before a destructive/structural edit. Typing coalesces within ~1.2s per block.
    private func pushUndo(coalesceTyping: Bool = false, caret: Int? = nil) {
        let snap = currentSnapshot(caret: caret)
        let now = Date()
        if coalesceTyping,
           let lastAt = lastUndoCoalesceAt,
           let lastIdx = lastUndoBlockIndex,
           lastIdx == activeIndex,
           now.timeIntervalSince(lastAt) < undoCoalesceInterval,
           !undoStack.isEmpty {
            // Keep the earliest snapshot in this typing burst.
            lastUndoCoalesceAt = now
            return
        }
        undoStack.append(snap)
        if undoStack.count > 80 { undoStack.removeFirst(undoStack.count - 80) }
        redoStack.removeAll()
        lastUndoCoalesceAt = coalesceTyping ? now : nil
        lastUndoBlockIndex = coalesceTyping ? activeIndex : nil
    }

    private func restoreSnapshot(_ snap: EditorSnapshot) {
        blocks = snap.blocks.map { MarkdownBlock(id: $0.id, source: $0.source) }
        if blocks.isEmpty { blocks = [MarkdownBlock(source: "")] }
        activeIndex = snap.activeIndex.flatMap { blocks.indices.contains($0) ? $0 : min($0, blocks.count - 1) }
        pendingCaretOffset = snap.caret
        lastUndoCoalesceAt = nil
        lastUndoBlockIndex = nil
        publish()
        reloadHTML()
        window?.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async { [weak self] in
            self?.window?.makeFirstResponder(self?.webView)
        }
    }

    private func performUndo() {
        guard let prev = undoStack.popLast() else { return }
        redoStack.append(currentSnapshot(caret: pendingCaretOffset))
        restoreSnapshot(prev)
    }

    private func performRedo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(currentSnapshot(caret: pendingCaretOffset))
        restoreSnapshot(next)
    }

    /// Enter at end of block → new blank block below (real blank line in the note).
    private func insertEmptyBlockBelow(index: Int, text: String) {
        splitBlock(index: index, text: text, caret: text.count)
    }

    /// Enter → split at caret: left stays, right becomes the new block (empty when at end).
    private func splitBlock(index: Int, text: String, caret: Int) {
        guard blocks.indices.contains(index) else { return }
        pushUndo()
        let pos = min(max(0, caret), text.count)
        let before = String(text.prefix(pos))
        let after = String(text.suffix(text.count - pos))
        blocks[index].source = before
        let insertAt = index + 1
        blocks.insert(MarkdownBlock(source: after), at: insertAt)
        activeIndex = insertAt
        pendingCaretOffset = 0
        publish()
        reloadHTML()
        window?.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async { [weak self] in
            self?.window?.makeFirstResponder(self?.webView)
        }
    }

    /// Remove an empty blank-line block only — never deletes content.
    /// Backspace removes the block only when the textarea is fully empty (`""`), not when it still has newlines.
    private func deleteEmptyBlock(target: String, index: Int, text: String) {
        guard blocks.indices.contains(index) else { return }
        blocks[index].source = text

        func isTrulyEmpty(at i: Int) -> Bool {
            blocks[i].source.isEmpty
        }

        let newActive: Int
        let caret: Int

        switch target {
        case "self":
            guard isTrulyEmpty(at: index) else { return }
            guard blocks.count > 1 else { return }
            pushUndo()
            blocks.remove(at: index)
            if index > 0 {
                newActive = index - 1
                caret = blocks[newActive].source.count
            } else {
                newActive = 0
                caret = 0
            }
        case "above":
            let above = index - 1
            guard above >= 0, isTrulyEmpty(at: above) else { return }
            guard blocks.count > 1 else { return }
            pushUndo()
            blocks.remove(at: above)
            newActive = above
            caret = 0
        case "below":
            let below = index + 1
            guard below < blocks.count, isTrulyEmpty(at: below) else { return }
            guard blocks.count > 1 else { return }
            pushUndo()
            blocks.remove(at: below)
            newActive = index
            caret = text.count
        default:
            return
        }

        guard blocks.indices.contains(newActive) else { return }
        activeIndex = newActive
        pendingCaretOffset = min(max(0, caret), blocks[newActive].source.count)

        publish()
        reloadHTML()
        window?.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async { [weak self] in
            self?.window?.makeFirstResponder(self?.webView)
        }
    }

    /// Arrow up/down at the edge of a block → previous/next block (seamless).
    private func navigateAcrossBlocks(direction: Int, column: Int) {
        guard let current = activeIndex else { return }
        let next = current + direction
        guard blocks.indices.contains(next) else { return }

        let source = blocks[next].source
        let lines = source.components(separatedBy: "\n")
        let caret: Int
        if direction < 0 {
            // Enter previous block on its last line, same column.
            let last = lines.last ?? ""
            let prefix = lines.dropLast().reduce(0) { $0 + $1.count + 1 }
            caret = prefix + min(max(0, column), last.count)
        } else {
            // Enter next block on its first line, same column.
            let first = lines.first ?? ""
            caret = min(max(0, column), first.count)
        }
        activateBlock(next, caretOffset: caret)
    }

    /// ⌥↑/⌥↓ past the first/last line → move that line into the neighboring block.
    private func moveLineAcrossBlocks(direction: Int, lineIndex: Int, column: Int) {
        guard let current = activeIndex, blocks.indices.contains(current) else { return }
        let neighbor = current + direction
        guard blocks.indices.contains(neighbor) else { return }

        var curLines = blocks[current].source.components(separatedBy: "\n")
        guard curLines.indices.contains(lineIndex) else { return }
        let moved = curLines.remove(at: lineIndex)
        pushUndo()
        blocks[current].source = curLines.joined(separator: "\n")

        var nextLines = blocks[neighbor].source.components(separatedBy: "\n")
        // Empty block is a single "" line — replace rather than stacking blanks.
        if nextLines == [""] {
            nextLines = [moved]
        } else if direction < 0 {
            nextLines.append(moved)
        } else {
            nextLines.insert(moved, at: 0)
        }
        blocks[neighbor].source = nextLines.joined(separator: "\n")

        // Re-parse so blank/list boundaries stay consistent, then find the moved line again.
        blocks = MarkdownBlockParser.parse(composedMarkdown())
        if blocks.isEmpty { blocks = [MarkdownBlock(source: "")] }

        let preferred = min(max(0, neighbor), blocks.count - 1)
        if blocks.indices.contains(preferred),
           blocks[preferred].source.components(separatedBy: "\n").contains(moved) {
            activeIndex = preferred
        } else if let match = blocks.firstIndex(where: {
            $0.source.components(separatedBy: "\n").contains(moved)
        }) {
            activeIndex = match
        } else {
            activeIndex = preferred
        }

        if let idx = activeIndex, blocks.indices.contains(idx) {
            let lines = blocks[idx].source.components(separatedBy: "\n")
            let li = direction < 0 ? lines.lastIndex(of: moved) : lines.firstIndex(of: moved)
            if let li {
                var off = 0
                for i in 0..<li { off += lines[i].count + 1 }
                pendingCaretOffset = off + min(max(0, column), lines[li].count)
            } else {
                pendingCaretOffset = direction < 0 ? blocks[idx].source.count : 0
            }
        }

        publish()
        reloadHTML()
        window?.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async { [weak self] in
            self?.window?.makeFirstResponder(self?.webView)
        }
    }

    private func focusActiveTextarea() {
        let offset = pendingCaretOffset
        pendingCaretOffset = nil
        let js: String
        if let offset {
            js = """
            (function(){
              var ta=document.querySelector('textarea.source');
              if(!ta) return;
              ta.focus({preventScroll:true});
              var n=Math.min(Math.max(0,\(offset)), ta.value.length);
              ta.selectionStart=ta.selectionEnd=n;
            })();
            """
        } else {
            js = "var ta=document.querySelector('textarea.source'); if(ta){ta.focus({preventScroll:true});}"
        }
        webView.evaluateJavaScript(js)
    }

    /// Map a click in rendered HTML (visible line/column) onto the Markdown source offset.
    private static func sourceOffset(in source: String, visibleLine: Int, visibleColumn: Int) -> Int {
        let lines = source.components(separatedBy: "\n")
        guard !lines.isEmpty else { return 0 }
        let lineIndex = min(max(0, visibleLine), lines.count - 1)
        var offset = 0
        for i in 0..<lineIndex {
            offset += lines[i].count + 1
        }
        let line = lines[lineIndex]
        let prefix = markdownDecorativePrefixLength(line)
        let col = min(max(0, visibleColumn) + prefix, line.count)
        return offset + col
    }

    /// Leading markup that disappears (or becomes a bullet) in the rendered view.
    private static func markdownDecorativePrefixLength(_ line: String) -> Int {
        var s = Substring(line)
        // Indentation kept in both views for nested lists — don't strip spaces that are content indent
        // only strip the list/heading/quote marker after optional indent.
        let indent = s.prefix { $0 == " " || $0 == "\t" }
        s = s.dropFirst(indent.count)

        if s.hasPrefix("```") { return indent.count }

        if s.first == "#" {
            var n = 0
            for ch in s {
                if ch == "#" { n += 1; if n > 6 { break } } else { break }
            }
            if n >= 1, n <= 6, s.count > n, s[s.index(s.startIndex, offsetBy: n)] == " " {
                return indent.count + n + 1
            }
        }

        if s.hasPrefix("> ") { return indent.count + 2 }
        if s.hasPrefix(">") { return indent.count + 1 }

        if s.hasPrefix("- ") || s.hasPrefix("* ") || s.hasPrefix("+ ") {
            return indent.count + 2
        }
        // Ordered list: 1. / 12. …
        if let dot = s.firstIndex(of: "."),
           s.startIndex < dot,
           s[s.startIndex..<dot].allSatisfy(\.isNumber),
           s.index(after: dot) < s.endIndex,
           s[s.index(after: dot)] == " " {
            return indent.count + s.distance(from: s.startIndex, to: s.index(after: dot)) + 1
        }

        return indent.count
    }

    /// Leave edit mode: re-parse and show everything rendered.
    private func commitEditing() {
        blocks = MarkdownBlockParser.parse(composedMarkdown())
        if blocks.isEmpty { blocks = [MarkdownBlock(source: "")] }
        let onlyEmpty = blocks.count == 1
            && blocks[0].source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        activeIndex = onlyEmpty ? 0 : nil
        publish()
        reloadHTML()
    }

    /// Click in empty space below content → new paragraph at end.
    private func appendBlock() {
        pushUndo()
        blocks = MarkdownBlockParser.parse(composedMarkdown())
        if blocks.isEmpty {
            blocks = [MarkdownBlock(source: "")]
        } else if let last = blocks.last,
                  last.source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            activeIndex = blocks.count - 1
            reloadHTML()
            return
        } else {
            blocks.append(MarkdownBlock(source: ""))
        }
        activeIndex = blocks.count - 1
        pendingCaretOffset = 0
        publish()
        reloadHTML()
    }

    private func insertImageMarkdown(_ snippet: String, dropTarget: [String: Any]? = nil) {
        pushUndo()

        if let dropTarget {
            applyImageSnippet(snippet, dropTarget: dropTarget)
        } else if let i = activeIndex, blocks.indices.contains(i) {
            // Paste while editing: append to the active block (own line).
            let current = blocks[i].source
            if current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                blocks[i].source = snippet
            } else if current.hasSuffix("\n") {
                blocks[i].source = current + snippet
            } else {
                blocks[i].source = current + "\n" + snippet
            }
        } else if blocks.isEmpty {
            blocks = [MarkdownBlock(source: snippet)]
        } else {
            blocks.append(MarkdownBlock(source: snippet))
        }

        // Leave edit mode and re-parse so the image renders as <img>, not raw markdown.
        blocks = MarkdownBlockParser.parse(composedMarkdown())
        if blocks.isEmpty { blocks = [MarkdownBlock(source: "")] }
        activeIndex = nil
        pendingCaretOffset = nil
        publish()
        reloadHTML()
        onRequestImmediateSave?()
    }

    /// Place image as its own block at `insertIndex` (0...count).
    private func applyImageSnippet(_ snippet: String, dropTarget: [String: Any]) {
        if let insertIndex = intValue(dropTarget["insertIndex"]) {
            let i = min(max(0, insertIndex), blocks.count)
            if i < blocks.count,
               blocks[i].source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                blocks[i].source = snippet
            } else {
                blocks.insert(MarkdownBlock(source: snippet), at: i)
            }
            return
        }

        if boolValue(dropTarget["append"]) == true {
            if blocks.isEmpty {
                blocks = [MarkdownBlock(source: snippet)]
            } else if let last = blocks.last,
                      last.source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                blocks[blocks.count - 1].source = snippet
            } else {
                blocks.append(MarkdownBlock(source: snippet))
            }
            return
        }

        guard let index = intValue(dropTarget["index"]), blocks.indices.contains(index) else {
            blocks.append(MarkdownBlock(source: snippet))
            return
        }

        let current = blocks[index].source
        if current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            blocks[index].source = snippet
            return
        }

        let after = boolValue(dropTarget["after"]) ?? true
        let insertAt = after ? index + 1 : index
        blocks.insert(MarkdownBlock(source: snippet), at: min(insertAt, blocks.count))
    }

    private func pasteImageFromClipboardIfPossible() -> Bool {
        guard let image = NoteImageStore.imageFromClipboard() else { return false }
        do {
            let rel = try NoteImageStore.saveImage(image, nextToNote: noteURL)
            insertImageMarkdown(NoteImageStore.markdownSnippet(relativePath: rel))
            return true
        } catch {
            return false
        }
    }

    /// Snap caret to the nearest inter-block gap; lock that gap as the insert target.
    private func refreshCachedDropTarget(at windowPoint: NSPoint) {
        let viewPoint = webView.convert(windowPoint, from: nil)
        refreshDropBlockFramesIfNeeded()
        let gap = nearestDropGap(toWebViewY: viewPoint.y)
        pendingInsertIndex = gap.insertIndex
        cachedDropTarget = ["insertIndex": gap.insertIndex]
        updateDropCaretLine(appKitYInWebView: gap.appKitY)
        if dropDebugEnabled {
            let n = blocks.count
            dropDebugLabel.stringValue = "drop → #\(gap.insertIndex)/\(n)  [\(gap.mapping)]  mouseY=\(Int(viewPoint.y)) caretY=\(Int(gap.appKitY))  frames=\(dropBlockFrames.count)"
            dropDebugLabel.sizeToFit()
            var frame = dropDebugLabel.frame
            frame.origin = NSPoint(x: 10, y: 8)
            frame.size.width = min(bounds.width - 20, max(frame.width, 280))
            frame.size.height = 18
            dropDebugLabel.frame = frame
            dropDebugLabel.isHidden = false
            addSubview(dropDebugLabel, positioned: .above, relativeTo: webView)
        }
    }

    private func updateDropCaretLine(appKitYInWebView y: CGFloat) {
        let local = convert(NSPoint(x: 0, y: y), from: webView)
        dropCaretLine.isHidden = false
        dropCaretLine.frame = NSRect(
            x: 10,
            y: local.y - 1.5,
            width: max(0, bounds.width - 20),
            height: 3
        )
        addSubview(dropCaretLine, positioned: .above, relativeTo: webView)
    }

    private func hideDropCaretLine() {
        dropCaretLine.isHidden = true
        dropDebugLabel.isHidden = true
    }

    /// Insertion edges in DOM space (clientY from top of the viewport).
    private func dropEdges() -> [(insertIndex: Int, clientY: CGFloat)] {
        let H = max(dropViewportHeight > 0 ? dropViewportHeight : webView.bounds.height, 1)
        if dropBlockFrames.isEmpty {
            let n = max(blocks.count, 1)
            return (0...n).map { i in
                (min(i, blocks.count), CGFloat(i) / CGFloat(n) * H)
            }
        }
        let sorted = dropBlockFrames.sorted { $0.top < $1.top }
        var edges: [(insertIndex: Int, clientY: CGFloat)] = sorted.map { ($0.index, $0.top) }
        if let last = sorted.last {
            edges.append((last.index + 1, last.bottom))
        }
        return edges
    }

    /// Pick the gap closest to the mouse.
    /// Critical: converted drag Y in this WKWebView is already top-origin (0 = top),
    /// same as DOM clientY — do NOT apply (height - y) or top maps to the last gap.
    private func nearestDropGap(toWebViewY mouseY: CGFloat) -> DropGap {
        let edges = dropEdges()
        guard !edges.isEmpty else {
            return DropGap(insertIndex: blocks.count, appKitY: mouseY, mapping: "empty")
        }

        let edge = edges.min(by: { abs($0.clientY - mouseY) < abs($1.clientY - mouseY) })!
        // Caret in the same top-origin space as mouseY / DOM clientY.
        return DropGap(insertIndex: edge.insertIndex, appKitY: edge.clientY, mapping: "top-origin")
    }

    private func refreshDropBlockFramesIfNeeded() {
        webView.evaluateJavaScript(
            """
            (function(){
              var h = window.innerHeight || document.documentElement.clientHeight || 0;
              var frames = Array.from(document.querySelectorAll('.block')).map(function(b) {
                var r = b.getBoundingClientRect();
                return { index: parseInt(b.dataset.index, 10), top: r.top, bottom: r.bottom };
              });
              return { h: h, frames: frames };
            })()
            """
        ) { [weak self] result, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                let root = Self.dictionary(fromJS: result) ?? [:]
                if let h = root["h"] as? NSNumber {
                    self.dropViewportHeight = CGFloat(h.doubleValue)
                } else if let h = root["h"] as? Double {
                    self.dropViewportHeight = CGFloat(h)
                }
                let frameRows: [[String: Any]]
                if let typed = root["frames"] as? [[String: Any]] {
                    frameRows = typed
                } else if let anyRows = root["frames"] as? [Any] {
                    frameRows = anyRows.compactMap { $0 as? [String: Any] }
                } else {
                    frameRows = []
                }
                self.dropBlockFrames = frameRows.compactMap { row in
                    guard let index = self.intValue(row["index"]) else { return nil }
                    let top = (row["top"] as? NSNumber)?.doubleValue ?? (row["top"] as? Double) ?? 0
                    let bottom = (row["bottom"] as? NSNumber)?.doubleValue ?? (row["bottom"] as? Double) ?? 0
                    return (index, CGFloat(top), CGFloat(bottom))
                }
            }
        }
    }

    private static func dictionary(fromJS result: Any?) -> [String: Any]? {
        if let dict = result as? [String: Any] { return dict }
        if let dict = result as? NSDictionary {
            var out: [String: Any] = [:]
            for (key, value) in dict {
                if let k = key as? String { out[k] = value }
            }
            return out.isEmpty ? nil : out
        }
        return nil
    }

    private func boolValue(_ any: Any?) -> Bool? {
        if let b = any as? Bool { return b }
        if let n = any as? NSNumber { return n.boolValue }
        return nil
    }

    private func reloadHTML() {
        // Capture scroll before tearing down the document — otherwise click-to-edit jumps.
        webView.evaluateJavaScript("window.scrollY||document.documentElement.scrollTop||0") { [weak self] result, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                if let n = result as? NSNumber {
                    self.pendingScrollY = n.doubleValue
                } else if let d = result as? Double {
                    self.pendingScrollY = d
                } else {
                    self.pendingScrollY = 0
                }
                self.performReloadHTML()
            }
        }
    }

    private func performReloadHTML() {
        let noteDir = noteURL.deletingLastPathComponent()
        let html = MarkdownHTMLRenderer.document(
            blocks: blocks,
            activeIndex: activeIndex,
            backgroundHex: background.reliableHexString,
            noteDirectory: noteDir,
            fontSize: fontSize,
            columnCount: columnCount
        )
        pendingHTML = html
        flushPendingHTMLIfPossible()
    }

    override func layout() {
        super.layout()
        flushPendingHTMLIfPossible()
    }

    private func flushPendingHTMLIfPossible() {
        guard let html = pendingHTML else { return }
        guard bounds.width > 10, bounds.height > 10 else { return }
        pendingHTML = nil
        let base = noteURL.deletingLastPathComponent()
        allowingHTMLLoad = true
        webView.loadHTMLString(html, baseURL: base)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        // Our own loadHTMLString.
        if allowingHTMLLoad {
            allowingHTMLLoad = false
            decisionHandler(.allow)
            return
        }
        // Block Finder image drops from navigating the whole page away from the note.
        if navigationAction.targetFrame?.isMainFrame != false,
           let url = navigationAction.request.url,
           url.isFileURL {
            let ext = url.pathExtension.lowercased()
            let imageExts: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "tif", "tiff", "bmp", "heic"]
            if imageExts.contains(ext) {
                decisionHandler(.cancel)
                return
            }
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let restoreFocus = activeIndex != nil
        if let y = pendingScrollY {
            pendingScrollY = nil
            webView.evaluateJavaScript("window.scrollTo(0, \(y))") { [weak self] _, _ in
                DispatchQueue.main.async {
                    if restoreFocus { self?.focusActiveTextarea() }
                }
            }
        } else if restoreFocus {
            focusActiveTextarea()
        }
    }

    // MARK: - WKScriptMessageHandler

    nonisolated func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        Task { @MainActor in
            self.handleScriptMessage(message)
        }
    }

    private func handleScriptMessage(_ message: WKScriptMessage) {
        switch message.name {
        case "activate":
            if let body = message.body as? [String: Any],
               let idx = intValue(body["index"]) {
                let line = intValue(body["line"]) ?? 0
                let column = intValue(body["column"]) ?? 0
                let source = blocks.indices.contains(idx) ? blocks[idx].source : ""
                let offset = Self.sourceOffset(in: source, visibleLine: line, visibleColumn: column)
                activateBlock(idx, caretOffset: offset)
            } else if let s = message.body as? String, let idx = Int(s) {
                activateBlock(idx)
            } else if let n = message.body as? NSNumber {
                activateBlock(n.intValue)
            }
        case "navigate":
            guard let body = message.body as? [String: Any],
                  let direction = intValue(body["direction"]),
                  let column = intValue(body["column"])
            else { return }
            navigateAcrossBlocks(direction: direction, column: column)
        case "deleteEmptyBlock":
            guard let body = message.body as? [String: Any],
                  let target = body["target"] as? String,
                  let index = intValue(body["index"]),
                  let text = body["text"] as? String
            else { return }
            deleteEmptyBlock(target: target, index: index, text: text)
        case "insertEmptyBelow":
            guard let body = message.body as? [String: Any],
                  let index = intValue(body["index"]),
                  let text = body["text"] as? String
            else { return }
            insertEmptyBlockBelow(index: index, text: text)
        case "splitBlock":
            guard let body = message.body as? [String: Any],
                  let index = intValue(body["index"]),
                  let text = body["text"] as? String,
                  let caret = intValue(body["caret"])
            else { return }
            splitBlock(index: index, text: text, caret: caret)
        case "moveLineAcross":
            guard let body = message.body as? [String: Any],
                  let direction = intValue(body["direction"]),
                  let lineIndex = intValue(body["lineIndex"]),
                  let column = intValue(body["column"])
            else { return }
            moveLineAcrossBlocks(direction: direction, lineIndex: lineIndex, column: column)
        case "edit":
            guard let body = message.body as? [String: Any],
                  let index = intValue(body["index"]),
                  let text = body["text"] as? String,
                  blocks.indices.contains(index)
            else { return }
            if blocks[index].source != text {
                pushUndo(coalesceTyping: true, caret: intValue(body["caret"]))
                blocks[index].source = text
                publish()
            }
        case "commit":
            commitEditing()
        case "append":
            appendBlock()
        case "imageDrop":
            handleHTMLImageDrop(message.body)
        case "openURL":
            if let s = message.body as? String, let url = URL(string: s) {
                NSWorkspace.shared.open(url)
            }
        default:
            break
        }
    }

    /// HTML5 provides image bytes; placement always comes from the snapped AppKit gap.
    private func handleHTMLImageDrop(_ body: Any?) {
        guard let dict = Self.dictionary(fromJS: body) else { return }
        if boolValue(dict["missingFiles"]) == true {
            return
        }
        guard let dataURL = dict["dataUrl"] as? String else { return }
        if let last = lastImageDropAt, Date().timeIntervalSince(last) < 0.8 { return }
        lastImageDropAt = Date()
        let target = pendingDropTarget
            ?? cachedDropTarget
            ?? pendingInsertIndex.map { ["insertIndex": $0] }
        pendingDropTarget = nil
        pendingInsertIndex = nil
        do {
            let rel = try NoteImageStore.saveImageDataURL(dataURL, nextToNote: noteURL)
            let snippet = NoteImageStore.markdownSnippet(relativePath: rel)
            insertImageMarkdown(snippet, dropTarget: target)
        } catch {
            // AppKit fallback may still succeed.
        }
    }

    private func intValue(_ any: Any?) -> Int? {
        if let i = any as? Int { return i }
        if let n = any as? NSNumber { return n.intValue }
        if let d = any as? Double { return Int(d) }
        if let s = any as? String { return Int(s) }
        return nil
    }

    // MARK: - Paste / drop

    private func setupPasteMonitor() {
        pasteMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            // Accept events for this sticky even if the panel is only briefly key.
            guard event.window === self.window || self.window?.isKeyWindow == true else {
                return event
            }

            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

            // Image paste
            if flags.contains(.command),
               event.charactersIgnoringModifiers == "v",
               NoteImageStore.clipboardHasImage(),
               self.pasteImageFromClipboardIfPossible() {
                return nil
            }

            let key = event.charactersIgnoringModifiers ?? ""

            // Undo/redo even after leaving edit mode (Escape) — trust requires recovery.
            if flags.contains(.command), !flags.contains(.option),
               key == "z" || key == "Z" {
                if flags.contains(.shift) {
                    guard !self.redoStack.isEmpty else { return event }
                    self.performRedo()
                } else {
                    guard !self.undoStack.isEmpty else { return event }
                    self.performUndo()
                }
                return nil
            }

            // Editor shortcuts while a block is active for editing
            guard activeIndex != nil else { return event }

            // Escape → leave edit mode and re-render.
            if event.keyCode == 53 {
                let mods = flags.intersection([.command, .option, .control, .shift])
                if mods.isEmpty {
                    self.commitEditing()
                    return nil
                }
            }

            var action: String?

            if flags.contains(.command), !flags.contains(.option), !flags.contains(.shift) {
                if key == "b" { action = "bold" }
                else if key == "i" { action = "italic" }
            } else if flags.contains(.option), !flags.contains(.command),
                      (event.keyCode == 126 || event.keyCode == 125) {
                action = event.keyCode == 126 ? "lineUp" : "lineDown"
            } else if event.keyCode == 48, !flags.contains(.command) { // Tab
                action = flags.contains(.shift) ? "outdent" : "indent"
            }

            if let action {
                webView.evaluateJavaScript(
                    "window.__msEditorAction && window.__msEditorAction('\(action)')"
                )
                return nil
            }

            return event
        }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let op = dragOperation(for: sender)
        if op == .copy {
            refreshDropBlockFramesIfNeeded()
            refreshCachedDropTarget(at: sender.draggingLocation)
        }
        return op
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let op = dragOperation(for: sender)
        if op == .copy { refreshCachedDropTarget(at: sender.draggingLocation) }
        return op
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        hideDropCaretLine()
        cachedDropTarget = nil
        pendingDropTarget = nil
        pendingInsertIndex = nil
        dropBlockFrames = []
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        dragOperation(for: sender) == .copy
    }

    private func dragOperation(for sender: NSDraggingInfo) -> NSDragOperation {
        if !NoteImageStore.imageURLs(from: sender).isEmpty { return .copy }
        if NoteImageStore.imageFromDragging(sender) != nil { return .copy }
        return []
    }

    /// AppKit fallback when HTML5 FileReader doesn't handle the drop.
    /// Delays briefly so the page's `drop` handler can win (and we don't leave orphan copies).
    func handleImageDrop(_ sender: NSDraggingInfo) -> Bool {
        let fileURL = NoteImageStore.imageURLs(from: sender).first
        let fallbackImage: NSImage? = fileURL == nil ? NoteImageStore.imageFromDragging(sender) : nil
        guard fileURL != nil || fallbackImage != nil else { return false }

        refreshCachedDropTarget(at: sender.draggingLocation)
        let viewPoint = webView.convert(sender.draggingLocation, from: nil)
        let gap = nearestDropGap(toWebViewY: viewPoint.y)
        let target: [String: Any] = ["insertIndex": gap.insertIndex]
        pendingInsertIndex = gap.insertIndex
        pendingDropTarget = target
        cachedDropTarget = target
        let noteURL = self.noteURL
        hideDropCaretLine()

        // Same-folder file: link immediately and block the HTML5 path (which would re-encode a copy).
        if let fileURL, NoteImageStore.isInNoteFolder(fileURL, noteURL: noteURL) {
            lastImageDropAt = Date()
            pendingDropTarget = nil
            pendingInsertIndex = nil
            do {
                let rel = try NoteImageStore.saveImageFile(from: fileURL, nextToNote: noteURL)
                insertImageMarkdown(NoteImageStore.markdownSnippet(relativePath: rel), dropTarget: target)
            } catch {
                return false
            }
            return true
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) { [weak self] in
            guard let self else { return }
            if let last = self.lastImageDropAt, Date().timeIntervalSince(last) < 0.7 {
                self.pendingDropTarget = nil
                self.pendingInsertIndex = nil
                return
            }
            self.lastImageDropAt = Date()
            let insertTarget = self.pendingDropTarget ?? target
            self.pendingDropTarget = nil
            self.pendingInsertIndex = nil
            do {
                let rel: String
                if let fileURL {
                    rel = try NoteImageStore.saveImageFile(from: fileURL, nextToNote: noteURL)
                } else if let fallbackImage {
                    rel = try NoteImageStore.saveImage(fallbackImage, nextToNote: noteURL)
                } else {
                    return
                }
                let snippet = NoteImageStore.markdownSnippet(relativePath: rel)
                self.insertImageMarkdown(snippet, dropTarget: insertTarget)
            } catch {
                return
            }
        }
        return true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        handleImageDrop(sender)
    }
}

/// Blue insertion line during image drag — hit-test transparent so WKWebView still gets the drop.
private final class DropCaretLineView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.systemBlue.cgColor
        layer?.cornerRadius = 1
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private final class DropDebugLabel: NSTextField {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBezeled = false
        drawsBackground = true
        backgroundColor = NSColor.black.withAlphaComponent(0.75)
        textColor = .white
        font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        isEditable = false
        isSelectable = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// WKWebView eats Finder drops unless we forward NSDraggingDestination to the note view.
private final class ImageDropWKWebView: WKWebView {
    weak var dropDestination: LivePreviewView?

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        MainActor.assumeIsolated { dropDestination?.draggingEntered(sender) ?? [] }
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        MainActor.assumeIsolated { dropDestination?.draggingUpdated(sender) ?? [] }
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        MainActor.assumeIsolated { dropDestination?.draggingExited(sender) }
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        MainActor.assumeIsolated { dropDestination?.prepareForDragOperation(sender) ?? false }
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        MainActor.assumeIsolated { dropDestination?.handleImageDrop(sender) ?? false }
    }
}
