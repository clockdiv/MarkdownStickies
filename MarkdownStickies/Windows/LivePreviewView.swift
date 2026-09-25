import AppKit
import WebKit

/// Obsidian-style Live Preview hosted entirely in AppKit (no SwiftUI / NSHostingView).
@MainActor
final class LivePreviewView: NSView, WKNavigationDelegate, WKScriptMessageHandler {
    var onTextChange: ((String) -> Void)?

    private var noteURL: URL

    func updateNoteURL(_ url: URL) {
        noteURL = url
    }
    private var background: NSColor
    private var fontSize: Double
    private var columnCount: Int
    private let webView: WKWebView
    /// Retained because WKUserContentController keeps only an unowned-style ref pattern via the config.
    private let messageProxy: ScriptMessageProxy
    private var pasteMonitor: Any?

    private var blocks: [MarkdownBlock] = [MarkdownBlock(source: "")]
    private var activeIndex: Int? = 0
    private var pendingHTML: String?
    private var suppressPublish = false

    var markdown: String {
        get { MarkdownBlockParser.join(blocks) }
        set {
            guard newValue != MarkdownBlockParser.join(blocks) else { return }
            suppressPublish = true
            bootstrap(text: newValue)
            suppressPublish = false
        }
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
        for name in ["activate", "edit", "openURL", "commit", "append"] {
            config.userContentController.add(proxy, name: name)
        }

        let wv = WKWebView(
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

        registerForDraggedTypes([.fileURL, .tiff, .png])
        setupPasteMonitor()
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
        reloadHTML()
    }

    private func composedMarkdown() -> String {
        MarkdownBlockParser.join(blocks)
    }

    private func publish() {
        guard !suppressPublish else { return }
        onTextChange?(composedMarkdown())
    }

    private func activateBlock(_ index: Int) {
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
        reloadHTML()
        window?.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.window?.makeFirstResponder(self.webView)
            self.webView.evaluateJavaScript(
                "var ta=document.querySelector('textarea.source'); if(ta){ta.focus();}"
            )
        }
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
        publish()
        reloadHTML()
    }

    private func insertImageMarkdown(_ snippet: String) {
        if blocks.isEmpty {
            blocks = [MarkdownBlock(source: snippet)]
            activeIndex = 0
        } else {
            let i = activeIndex ?? blocks.count - 1
            activeIndex = i
            let current = blocks[i].source
            if current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                blocks[i].source = snippet
            } else if current.hasSuffix("\n") {
                blocks[i].source = current + snippet
            } else {
                blocks[i].source = current + "\n" + snippet
            }
        }
        publish()
        reloadHTML()
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

    private func reloadHTML() {
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
        webView.loadHTMLString(html, baseURL: base)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard activeIndex != nil else { return }
        webView.evaluateJavaScript(
            "var ta=document.querySelector('textarea.source'); if(ta){ta.focus();}"
        )
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
            if let s = message.body as? String, let idx = Int(s) {
                activateBlock(idx)
            } else if let n = message.body as? NSNumber {
                activateBlock(n.intValue)
            }
        case "edit":
            guard let body = message.body as? [String: Any],
                  let index = body["index"] as? Int,
                  let text = body["text"] as? String,
                  blocks.indices.contains(index)
            else { return }
            blocks[index].source = text
            publish()
        case "commit":
            commitEditing()
        case "append":
            appendBlock()
        case "openURL":
            if let s = message.body as? String, let url = URL(string: s) {
                NSWorkspace.shared.open(url)
            }
        default:
            break
        }
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

            let key = event.charactersIgnoringModifiers ?? ""
            var action: String?

            if flags.contains(.command), !flags.contains(.shift), !flags.contains(.option) {
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
        if NoteImageStore.imageFromDragging(sender) != nil || !NoteImageStore.imageURLs(from: sender).isEmpty {
            return .copy
        }
        return []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        do {
            if let file = NoteImageStore.imageURLs(from: sender).first {
                let rel = try NoteImageStore.saveImageFile(from: file, nextToNote: noteURL)
                insertImageMarkdown(NoteImageStore.markdownSnippet(relativePath: rel))
                return true
            }
            if let image = NoteImageStore.imageFromDragging(sender) {
                let rel = try NoteImageStore.saveImage(image, nextToNote: noteURL)
                insertImageMarkdown(NoteImageStore.markdownSnippet(relativePath: rel))
                return true
            }
        } catch {
            return false
        }
        return false
    }
}
