import AppKit
import MarkdownStickiesCore
import Quartz

/// Continuous TextKit markdown source editor.
@MainActor
final class MarkdownSourceEditorView: NSView, NSTextViewDelegate, StickyNoteEditorBody {
    var onTextChange: ((String) -> Void)?
    var onTypingActivity: (() -> Void)?
    var onRequestImmediateSave: (() -> Void)?

    private(set) var hasUnpublishedEdits = false

    /// Files that can't be written open read-only: no typing, pasting or dropping.
    var isReadOnly = false {
        didSet { for tv in columnViews { tv.isEditable = !isReadOnly } }
    }

    private var noteURL: URL
    private var background: NSColor
    private var fontSize: Double
    private var columnCount: Int
    private var suppressPublish = false
    private var publishTask: Task<Void, Never>?
    private let publishDebounceNanoseconds: UInt64 = 150_000_000
    private var keyMonitor: Any?
    private var isRefreshingDisplay = false
    private var previewURL: URL?
    private var tableEditor: MarkdownTableEditorController?

    private let editContainer = FlippedEditContainer()
    private let scrollView = NSScrollView()
    private var textStorage = NSTextStorage()
    private var layoutManager = NSLayoutManager()
    private var columnViews: [SourceNSTextView] = []
    private var columnContainers: [NSTextContainer] = []
    private let dropCaret = SourceDropCaretLineView()
    /// Avoid fighting the user after they scroll; reset only on structural rebuilds.
    private var shouldScrollToTopAfterLayout = true
    /// Last bounds used for column geometry (zero until first real layout).
    private var lastColumnLayoutSize: CGSize = .zero
    private var isRelayoutingColumns = false
    /// Dedupe key-monitor ⌘V + `paste(_:)` so one gesture can’t write two files.
    private var lastImagePasteAt: Date?

    private enum ColumnGrowMode {
        /// Typing: only grow when glyphs overflow — never resize from used-rect padding
        /// (that was shifting column 2 on every keystroke).
        case typing
        /// Open / column-count / bounds: allow pad-to-used and single-column shrink-wrap.
        case structural
    }

    var markdown: String {
        get { serializeMarkdown() }
        set {
            let current = serializeMarkdown()
            guard newValue != current else { return }
            suppressPublish = true
            replacePlainMarkdown(newValue, preferredPlainOffset: nil)
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
        self.fontSize = min(NoteWindowState.maxTextSize, max(NoteWindowState.minTextSize, fontSize))
        self.columnCount = NoteWindowState.clampedColumnCount(columnCount)

        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = background.cgColor

        textStorage.addLayoutManager(layoutManager)

        // Document view is frame-based (not Auto Layout) inside NSScrollView.
        editContainer.translatesAutoresizingMaskIntoConstraints = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.contentView.copiesOnScroll = true
        scrollView.documentView = editContainer
        // Document view is a plain container (columns + gaps), not a text view.
        scrollView.contentView.documentCursor = .arrow

        dropCaret.isHidden = true
        editContainer.addSubview(dropCaret)

        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        rebuildColumns(seedMarkdown: text)
        registerForDraggedTypes([.fileURL, .tiff, .png])

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKeyDown(event) ?? event
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    }

    override func layout() {
        super.layout()
        let size = bounds.size
        if size.width > 40, size.height > 40, !isRelayoutingColumns {
            let firstLayout = lastColumnLayoutSize == .zero
            let widthChanged = abs(size.width - lastColumnLayoutSize.width) > 2
            if firstLayout || widthChanged {
                // Init often runs with empty bounds — rebuild once we know the sticky size
                // so column widths/heights are correct (otherwise everything stays in col 1).
                lastColumnLayoutSize = size
                relayoutColumnsForCurrentBounds(scrollToTop: firstLayout || shouldScrollToTopAfterLayout)
            }
            // Intentionally no per-layout `layoutColumnFrames()` — rewriting
            // container sizes on every pass reflows column 2 while typing.
        }
        if shouldScrollToTopAfterLayout {
            scrollEditViewToTop()
            shouldScrollToTopAfterLayout = false
        }
    }

    // MARK: - StickyNoteEditorBody

    func updateNoteURL(_ url: URL) { noteURL = url }

    func reloadPreviewMedia() {
        let plain = serializeMarkdown()
        let caret = primaryTextView()?.selectedRange().location
        let plainOffset = caret.map { plainOffset(forAttributedLocation: $0) }
        replacePlainMarkdown(plain, preferredPlainOffset: plainOffset)
    }

    func applyBackground(_ color: NSColor) {
        background = color
        layer?.backgroundColor = color.cgColor
        for tv in columnViews { tv.backgroundColor = color }
    }

    func applyFontSize(_ size: Double) {
        let clamped = min(NoteWindowState.maxTextSize, max(NoteWindowState.minTextSize, size))
        guard abs(fontSize - clamped) > 0.01 else { return }
        fontSize = clamped
        let plain = serializeMarkdown()
        replacePlainMarkdown(plain, preferredPlainOffset: nil)
    }

    func applyColumnCount(_ count: Int) {
        let clamped = NoteWindowState.clampedColumnCount(count)
        guard columnCount != clamped else { return }
        columnCount = clamped
        let plain = serializeMarkdown()
        let caret = primaryTextView()?.selectedRange().location
        let plainOffset = caret.map { plainOffset(forAttributedLocation: $0) }
        rebuildColumns(seedMarkdown: plain, preferredPlainOffset: plainOffset)
    }

    func focusEditor() {
        window?.makeFirstResponder(primaryTextView())
    }

    func flushPendingPublish() {
        guard publishTask != nil || hasUnpublishedEdits else { return }
        publish(immediate: true)
    }

    // MARK: - Table

    func presentTableEditor() {
        flushPendingPublish()
        let plain = serializeMarkdown()
        guard let table = MarkdownTableEditorController.detectTable(in: plain, utf16Offset: {
            let loc = primaryTextView()?.selectedRange().location ?? 0
            return plainOffset(forAttributedLocation: loc)
        }()) else {
            let alert = NSAlert()
            alert.messageText = "No Table Found"
            alert.informativeText = "Place the caret inside a pipe table (lines with |)."
            alert.alertStyle = .informational
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }
        let editor = MarkdownTableEditorController(table: table) { [weak self] replacement in
            guard let self else { return }
            var lines = plain.components(separatedBy: "\n")
            let end = table.lineRange.upperBound
            let start = table.lineRange.lowerBound
            guard start <= end, end <= lines.count else { return }
            lines.replaceSubrange(start..<end, with: replacement)
            let newPlain = lines.joined(separator: "\n")
            self.replacePlainMarkdown(newPlain, preferredPlainOffset: nil)
            self.hasUnpublishedEdits = true
            self.onTypingActivity?()
            self.publish(immediate: true)
            self.tableEditor = nil
        }
        editor.onClose = { [weak self] in self?.tableEditor = nil }
        tableEditor = editor
        editor.show()
    }

    // MARK: - NSTextViewDelegate

    func textDidChange(_ notification: Notification) {
        guard !suppressPublish, !isRefreshingDisplay else { return }
        hasUnpublishedEdits = true
        onTypingActivity?()
        let tv = (notification.object as? NSTextView) ?? primaryTextView()
        let caret = tv?.selectedRange().location ?? 0
        let plainOffset = plainOffset(forAttributedLocation: caret)
        let plain = serializeMarkdown()
        replacePlainMarkdown(plain, preferredPlainOffset: plainOffset, columnGrow: .typing)
        publish(immediate: false)
    }

    func textView(_ textView: NSTextView, clickedOn link: Any, at charIndex: Int) -> Bool {
        // Links always open externally — never Quick Look (that’s for image attachments only).
        if let url = link as? URL {
            NSWorkspace.shared.open(url)
            return true
        }
        if let s = link as? String, let url = URL(string: s) {
            NSWorkspace.shared.open(url)
            return true
        }
        return false
    }


    // MARK: - Drag

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        dragHasImage(sender) ? .copy : []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        updateDropCaret(with: sender)
        return dragHasImage(sender) ? .copy : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        dropCaret.isHidden = true
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { true }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        dropCaret.isHidden = true
        placeCaretForDrop(sender)
        let urls = NoteImageStore.imageURLs(from: sender)
        if !urls.isEmpty {
            insertDroppedImageFiles(urls)
            return true
        }
        if let image = NoteImageStore.imageFromPasteboard(sender.draggingPasteboard) {
            insertImage(image)
            return true
        }
        return false
    }

    // MARK: - Private layout / columns

    private func primaryTextView() -> SourceNSTextView? { columnViews.first }

    private func relayoutColumnsForCurrentBounds(scrollToTop: Bool) {
        let plain = serializeMarkdown()
        let caret = primaryTextView()?.selectedRange().location
        let plainOffset = caret.map { plainOffset(forAttributedLocation: $0) }
        if scrollToTop { shouldScrollToTopAfterLayout = true }
        rebuildColumns(seedMarkdown: plain, preferredPlainOffset: plainOffset)
    }

    private func rebuildColumns(seedMarkdown: String, preferredPlainOffset: Int? = nil) {
        isRelayoutingColumns = true
        defer { isRelayoutingColumns = false }

        for tv in columnViews { tv.removeFromSuperview() }
        columnViews.removeAll()
        while layoutManager.textContainers.count > 0 {
            layoutManager.removeTextContainer(at: 0)
        }
        columnContainers.removeAll()

        let count = max(1, columnCount)
        let colWidth = columnWidth()
        // Multi-column: start at *viewport* height so text flows across columns.
        // (Content-estimated height was often too tall → everything fit in column 1.)
        // Single-column: start at viewport, then shrink-wrap to used height.
        let colHeight = visibleColumnHeight()

        for _ in 0..<count {
            let container = NSTextContainer(size: NSSize(width: colWidth, height: colHeight))
            container.widthTracksTextView = false
            container.heightTracksTextView = false
            container.lineFragmentPadding = 4
            layoutManager.addTextContainer(container)
            columnContainers.append(container)

            let tv = SourceNSTextView(frame: .zero, textContainer: container)
            configureTextView(tv)
            columnViews.append(tv)
            editContainer.addSubview(tv)
        }

        replacePlainMarkdown(seedMarkdown, preferredPlainOffset: preferredPlainOffset, columnGrow: .structural)
        layoutColumnFrames()
        ensureTextLaidOut()
        growColumnsIfNeeded(mode: .structural)
        if shouldScrollToTopAfterLayout {
            scrollEditViewToTop()
        }
    }

    private func scrollEditViewToTop() {
        // Flipped document: (0,0) is the top-leading corner of the note.
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func ensureTextLaidOut() {
        guard textStorage.length > 0 else { return }
        let full = NSRange(location: 0, length: textStorage.length)
        layoutManager.ensureLayout(forCharacterRange: full)
    }

    private func configureTextView(_ tv: SourceNSTextView) {
        tv.isRichText = true
        tv.allowsUndo = true
        tv.isEditable = !isReadOnly
        tv.isSelectable = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = true
        tv.usesFindBar = true
        tv.isHorizontallyResizable = false
        tv.isVerticallyResizable = false
        tv.textContainerInset = NSSize(width: 8, height: 10)
        tv.drawsBackground = true
        tv.backgroundColor = background
        tv.insertionPointColor = .labelColor
        tv.delegate = self
        tv.linkTextAttributes = [
            .foregroundColor: NSColor.linkColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ]
        tv.onPasteImage = { [weak self] in self?.pasteImageFromClipboard() ?? false }
        tv.onInsertDroppedImages = { [weak self] urls in self?.insertDroppedImageFiles(urls) }
        // Click image → Quick Look. Pinch must not open links or previews.
        tv.onOpenAttachment = { [weak self] url in self?.presentQuickLook(url) }
        tv.onMoveLines = { [weak self] direction in
            self?.moveSelectedLines(direction: direction)
            return true
        }
    }

    private lazy var quickLookBridge = QuickLookBridge()

    private func presentQuickLook(_ url: URL) {
        guard url.isFileURL, FileManager.default.fileExists(atPath: url.path) else { return }
        previewURL = url
        quickLookBridge.url = url
        // QL walks the responder chain for a controller — seed the text views
        // (usually first responder) and become controller there.
        for tv in columnViews {
            tv.quickLookURL = url
            tv.quickLookDataSource = quickLookBridge
        }
        if let tv = window?.firstResponder as? SourceNSTextView ?? primaryTextView() {
            window?.makeFirstResponder(tv)
        }
        guard let panel = QLPreviewPanel.shared() else {
            NSWorkspace.shared.open(url)
            return
        }
        if panel.isVisible {
            panel.reloadData()
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
    }

    func textView(
        _ textView: NSTextView,
        clickedOn cell: any NSTextAttachmentCellProtocol,
        in cellFrame: NSRect,
        at charIndex: Int
    ) {
        guard let storage = textView.textStorage,
              charIndex >= 0, charIndex < storage.length,
              let attachment = storage.attribute(.attachment, at: charIndex, effectiveRange: nil) as? MarkdownImageAttachment
        else { return }
        presentQuickLook(attachment.fileURL)
    }

    private func columnWidth() -> CGFloat {
        let inset: CGFloat = 16
        let gap: CGFloat = 16
        let width = bounds.width > 40 ? bounds.width : scrollView.contentView.bounds.width
        let available = max(80, width - inset)
        let n = CGFloat(max(1, columnCount))
        return max(60, (available - gap * (n - 1)) / n)
    }

    private func visibleColumnHeight() -> CGFloat {
        let clipH = scrollView.contentView.bounds.height
        let selfH = bounds.height
        let h = max(clipH, selfH)
        // Prefer real clip size; fall back only when not laid out yet.
        if h > 40 { return max(80, h - 8) }
        return 240
    }

    private func layoutColumnFrames() {
        let gap: CGFloat = 16
        let colW = columnWidth()
        // Container height is the text layout height. The text view is taller by
        // top+bottom `textContainerInset` so the last line isn’t clipped.
        let layoutHeight = columnContainers.first?.size.height ?? visibleColumnHeight()
        let vInset = (columnViews.first?.textContainerInset.height ?? 10) * 2
        let viewHeight = layoutHeight + vInset
        var x: CGFloat = 8
        for (i, tv) in columnViews.enumerated() {
            tv.frame = NSRect(x: x, y: 0, width: colW, height: viewHeight)
            if i < columnContainers.count {
                let hPad = tv.textContainerInset.width * 2
                columnContainers[i].size = NSSize(
                    width: max(40, colW - hPad),
                    height: layoutHeight
                )
            }
            x += colW + gap
        }
        let totalW = max(bounds.width > 40 ? bounds.width : colW + 16, x)
        editContainer.frame = NSRect(x: 0, y: 0, width: totalW, height: viewHeight)
    }

    /// True when not all glyphs fit in the existing column containers.
    private func textOverflowsColumns() -> Bool {
        guard textStorage.length > 0, let last = columnContainers.last else { return false }
        ensureTextLaidOut()
        let allGlyphs = layoutManager.glyphRange(
            forCharacterRange: NSRange(location: 0, length: textStorage.length),
            actualCharacterRange: nil
        )
        guard allGlyphs.length > 0 else { return false }
        let lastGlyphs = layoutManager.glyphRange(for: last)
        return NSMaxRange(lastGlyphs) < NSMaxRange(allGlyphs)
    }

    private func growColumnsIfNeeded(mode: ColumnGrowMode) {
        guard !columnContainers.isEmpty else { return }

        let bottomPadding: CGFloat = 36

        // Grow only when content no longer fits — keep height stable otherwise so
        // multi-column text doesn’t reshuffle on every character.
        var guardCount = 0
        while textOverflowsColumns(), guardCount < 80 {
            let step: CGFloat = mode == .typing ? 48 : 64
            let newH = (columnContainers.first?.size.height ?? visibleColumnHeight()) + step
            for c in columnContainers {
                c.size = NSSize(width: c.size.width, height: newH)
            }
            layoutColumnFrames()
            ensureTextLaidOut()
            guardCount += 1
        }

        guard mode == .structural else { return }

        ensureTextLaidOut()
        if columnCount <= 1, let c = columnContainers.first {
            // Single-column: shrink-wrap so the document isn’t absurdly tall.
            let used = layoutManager.usedRect(for: c)
            let fitted = max(visibleColumnHeight(), ceil(used.maxY) + bottomPadding)
            if abs(c.size.height - fitted) > 1 {
                c.size = NSSize(width: c.size.width, height: fitted)
                layoutColumnFrames()
            }
        } else if columnCount > 1 {
            // One-time pad after open/resize — not on each keystroke.
            let maxUsed = columnContainers.map { layoutManager.usedRect(for: $0).maxY }.max() ?? 0
            let current = columnContainers[0].size.height
            let desired = ceil(maxUsed) + bottomPadding
            if desired > current + 0.5 {
                for c in columnContainers {
                    c.size = NSSize(width: c.size.width, height: desired)
                }
                layoutColumnFrames()
                ensureTextLaidOut()
                var extra = 0
                while textOverflowsColumns(), extra < 40 {
                    let newH = (columnContainers.first?.size.height ?? desired) + 64
                    for c in columnContainers {
                        c.size = NSSize(width: c.size.width, height: newH)
                    }
                    layoutColumnFrames()
                    ensureTextLaidOut()
                    extra += 1
                }
            }
        }
    }

    // MARK: - Markdown <-> attachments

    private func serializeMarkdown() -> String {
        let attr = textStorage
        var out = ""
        let full = NSRange(location: 0, length: attr.length)
        attr.enumerateAttributes(in: full, options: []) { attrs, range, _ in
            if let attachment = attrs[.attachment] as? MarkdownImageAttachment {
                out += attachment.markdownSnippet
            } else {
                out += (attr.string as NSString).substring(with: range)
            }
        }
        return out
    }

    private func plainOffset(forAttributedLocation loc: Int) -> Int {
        let clamped = max(0, min(loc, textStorage.length))
        let prefix = textStorage.attributedSubstring(from: NSRange(location: 0, length: clamped))
        var out = ""
        let full = NSRange(location: 0, length: prefix.length)
        prefix.enumerateAttributes(in: full, options: []) { attrs, range, _ in
            if let attachment = attrs[.attachment] as? MarkdownImageAttachment {
                out += attachment.markdownSnippet
            } else {
                out += (prefix.string as NSString).substring(with: range)
            }
        }
        return (out as NSString).length
    }

    private func attributedLocation(forPlainOffset plainOffset: Int) -> Int {
        var plainCount = 0
        var attrPos = 0
        let full = NSRange(location: 0, length: textStorage.length)
        var result = textStorage.length
        textStorage.enumerateAttributes(in: full, options: []) { attrs, range, stop in
            if let attachment = attrs[.attachment] as? MarkdownImageAttachment {
                let snippetLen = (attachment.markdownSnippet as NSString).length
                if plainCount + snippetLen >= plainOffset {
                    result = attrPos
                    stop.pointee = true
                    return
                }
                plainCount += snippetLen
                attrPos += range.length
            } else {
                let len = range.length
                if plainCount + len >= plainOffset {
                    result = attrPos + (plainOffset - plainCount)
                    stop.pointee = true
                    return
                }
                plainCount += len
                attrPos += len
            }
        }
        return result
    }

    private func replacePlainMarkdown(
        _ plain: String,
        preferredPlainOffset: Int?,
        columnGrow: ColumnGrowMode = .structural
    ) {
        isRefreshingDisplay = true
        // Keep multi-column container sizes fixed across the text replace so
        // TextKit doesn’t get a height rewrite mid-edit (that shifts column 2).
        let lockedSizes: [CGSize] = columnCount > 1
            ? columnContainers.map(\.size)
            : []
        let attributed = buildDisplayString(from: plain)
        textStorage.beginEditing()
        textStorage.setAttributedString(attributed)
        textStorage.endEditing()
        if columnCount > 1, lockedSizes.count == columnContainers.count {
            for (i, size) in lockedSizes.enumerated() {
                columnContainers[i].size = size
            }
            layoutColumnFrames()
        }
        applyTypingAttributes()
        if let preferredPlainOffset {
            let loc = attributedLocation(forPlainOffset: preferredPlainOffset)
            primaryTextView()?.setSelectedRange(NSRange(location: loc, length: 0))
        }
        isRefreshingDisplay = false
        growColumnsIfNeeded(mode: columnGrow)
    }

    /// Inline images use (almost) the full column measure.
    private func imageMaxWidth() -> CGFloat {
        max(96, columnWidth() - 16)
    }

    /// `ink` 1.0 = full black (or white in dark), 0.8 ≈ 80% black, etc.
    private func sourceInk(_ ink: CGFloat) -> NSColor {
        let clamped = min(1, max(0, ink))
        return NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let white = dark ? clamped : (1 - clamped)
            return NSColor(white: white, alpha: 1)
        }
    }

    /// Regular copy ≈ 80% black; bold/italic use full black for contrast.
    private var sourceBodyColor: NSColor { sourceInk(0.80) }

    private var sourceEmphasisColor: NSColor { sourceInk(1.0) }

    private func buildDisplayString(from plain: String) -> NSAttributedString {
        let bodyFont = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        let base: [NSAttributedString.Key: Any] = [
            .font: bodyFont,
            .foregroundColor: sourceBodyColor,
        ]
        let result = NSMutableAttributedString(string: plain, attributes: base)
        let ns = plain as NSString
        let full = NSRange(location: 0, length: ns.length)
        let noteDir = noteURL.deletingLastPathComponent()
        let imgWidth = imageMaxWidth()

        // Images → attachments (reverse order so ranges stay valid)
        if let imageRe = try? NSRegularExpression(pattern: #"!\[([^\]]*)\]\(\s*(?:<([^>]+)>|([^)\s]+))\s*\)"#) {
            let matches = imageRe.matches(in: plain, options: [], range: full)
            for match in matches.reversed() {
                let destRange = match.range(at: 2).location != NSNotFound ? match.range(at: 2) : match.range(at: 3)
                guard destRange.location != NSNotFound else { continue }
                var dest = ns.substring(with: destRange).trimmingCharacters(in: .whitespacesAndNewlines)
                if dest.hasPrefix("<"), dest.hasSuffix(">") {
                    dest = String(dest.dropFirst().dropLast())
                }
                let snippet = ns.substring(with: match.range)
                guard let fileURL = ImageReferences.fileURL(forDestination: dest, noteDirectory: noteDir),
                      fileURL.isFileURL,
                      let image = NSImage(contentsOf: fileURL)
                else { continue }
                let attachment = MarkdownImageAttachment(
                    markdownSnippet: snippet,
                    fileURL: fileURL,
                    image: image,
                    maxWidth: imgWidth
                )
                let replacement = NSMutableAttributedString(attachment: attachment)
                replacement.addAttributes(base, range: NSRange(location: 0, length: replacement.length))
                result.replaceCharacters(in: match.range, with: replacement)
            }
        }

        applySourceChrome(to: result, noteDirectory: noteDir, bodyFont: bodyFont)
        return result
    }

    /// Headings / lists / quotes / code / links — display-only; markdown text unchanged.
    private func applySourceChrome(
        to result: NSMutableAttributedString,
        noteDirectory: URL,
        bodyFont: NSFont
    ) {
        let display = result.string as NSString
        let displayFull = NSRange(location: 0, length: display.length)
        let unit = max(10, fontSize * 0.95)

        func overlapsAttachment(_ range: NSRange) -> Bool {
            var hit = false
            result.enumerateAttribute(.attachment, in: range, options: []) { value, _, stop in
                if value != nil { hit = true; stop.pointee = true }
            }
            return hit
        }

        func styleMatches(_ pattern: String, _ apply: (NSTextCheckingResult) -> Void) {
            guard let re = try? NSRegularExpression(pattern: pattern) else { return }
            re.enumerateMatches(in: display as String, options: [], range: displayFull) { match, _, _ in
                guard let match, !overlapsAttachment(match.range) else { return }
                apply(match)
            }
        }

        // Headings: color + scale + weight (still show the `#` markers).
        // Note: never assign `NSTextView.font` after this — that resets the whole doc.
        let headingStyles: [(String, CGFloat, NSFont.Weight, NSColor)] = [
            (#"(?m)^(#{1}\s+.*)$"#, 1.55, .bold, .systemBlue),
            (#"(?m)^(#{2}\s+.*)$"#, 1.35, .bold, .systemIndigo),
            (#"(?m)^(#{3}\s+.*)$"#, 1.2, .semibold, .systemPurple),
            (#"(?m)^(#{4}\s+.*)$"#, 1.1, .semibold, .systemTeal),
            (#"(?m)^(#{5,6}\s+.*)$"#, 1.05, .semibold, .systemTeal),
        ]
        for (pattern, scale, weight, color) in headingStyles {
            styleMatches(pattern) { match in
                let size = max(fontSize + 2, fontSize * scale)
                let font = NSFont.monospacedSystemFont(ofSize: size, weight: weight)
                let para = NSMutableParagraphStyle()
                para.paragraphSpacingBefore = fontSize * 0.4
                para.paragraphSpacing = fontSize * 0.2
                result.addAttributes(
                    [
                        .font: font,
                        .foregroundColor: color,
                        .paragraphStyle: para,
                    ],
                    range: match.range
                )
            }
        }

        // Lists: indent by nesting; marker muted/bold, body stays readable.
        styleMatches(#"(?m)^([ \t]*)([-*+]|\d+\.)(\s+)(.*)$"#) { match in
            let indentRun = display.substring(with: match.range(at: 1))
            let spaces = indentRun.reduce(0) { partial, ch -> Int in
                if ch == "\t" { return partial + 2 }
                return partial + 1
            }
            let level = spaces / 2
            let para = NSMutableParagraphStyle()
            let indent = unit * 0.55 + CGFloat(level) * unit * 1.15
            para.firstLineHeadIndent = indent
            para.headIndent = indent + unit * 1.35
            para.paragraphSpacing = fontSize * 0.08
            result.addAttribute(.paragraphStyle, value: para, range: match.range)

            let markerRange = match.range(at: 2)
            result.addAttributes(
                [
                    .foregroundColor: NSColor.secondaryLabelColor,
                    .font: NSFont.monospacedSystemFont(ofSize: fontSize, weight: .bold),
                ],
                range: markerRange
            )
            if match.range(at: 4).location != NSNotFound {
                result.addAttribute(.foregroundColor, value: sourceBodyColor, range: match.range(at: 4))
            }
        }

        // Blockquotes: nested `>` → deeper indent + warm tint.
        styleMatches(#"(?m)^(>+)(\s?.*)$"#) { match in
            let markers = display.substring(with: match.range(at: 1))
            let depth = max(1, markers.filter { $0 == ">" }.count)
            let para = NSMutableParagraphStyle()
            let indent = CGFloat(depth) * unit * 1.05
            para.firstLineHeadIndent = indent
            para.headIndent = indent
            result.addAttributes(
                [
                    .paragraphStyle: para,
                    .foregroundColor: NSColor.systemOrange.withAlphaComponent(0.88),
                    .font: bodyFont,
                ],
                range: match.range
            )
            result.addAttribute(
                .foregroundColor,
                value: NSColor.systemOrange,
                range: match.range(at: 1)
            )
        }

        // Emphasis: keep `*` / `_` / `~~` visible (dimmed); style the inner text.
        func dimMarkers(full: NSRange, inner: NSRange) {
            let markerColor = NSColor.tertiaryLabelColor
            if inner.location > full.location {
                let left = NSRange(location: full.location, length: inner.location - full.location)
                result.addAttribute(.foregroundColor, value: markerColor, range: left)
            }
            let innerEnd = NSMaxRange(inner)
            let fullEnd = NSMaxRange(full)
            if fullEnd > innerEnd {
                let right = NSRange(location: innerEnd, length: fullEnd - innerEnd)
                result.addAttribute(.foregroundColor, value: markerColor, range: right)
            }
        }

        func applyFontTraits(_ traits: NSFontTraitMask, to range: NSRange) {
            result.enumerateAttribute(.font, in: range, options: []) { value, subrange, _ in
                let base = (value as? NSFont) ?? bodyFont
                let converted = NSFontManager.shared.convert(base, toHaveTrait: traits)
                result.addAttribute(.font, value: converted, range: subrange)
            }
        }

        // Bold before italic so `**` isn’t eaten by single-`*` patterns.
        styleMatches(#"\*\*(.+?)\*\*"#) { match in
            let inner = match.range(at: 1)
            guard inner.location != NSNotFound, inner.length > 0 else { return }
            dimMarkers(full: match.range, inner: inner)
            applyFontTraits(.boldFontMask, to: inner)
            result.addAttribute(.foregroundColor, value: sourceEmphasisColor, range: inner)
        }
        styleMatches(#"__(.+?)__"#) { match in
            let inner = match.range(at: 1)
            guard inner.location != NSNotFound, inner.length > 0 else { return }
            dimMarkers(full: match.range, inner: inner)
            applyFontTraits(.boldFontMask, to: inner)
            result.addAttribute(.foregroundColor, value: sourceEmphasisColor, range: inner)
        }
        styleMatches(#"(?<!\*)\*([^*\n]+?)\*(?!\*)"#) { match in
            let inner = match.range(at: 1)
            guard inner.location != NSNotFound, inner.length > 0 else { return }
            dimMarkers(full: match.range, inner: inner)
            applyFontTraits(.italicFontMask, to: inner)
            result.addAttribute(.foregroundColor, value: sourceEmphasisColor, range: inner)
            // Monospace often lacks a true italic — nudge if traits didn’t stick.
            result.enumerateAttribute(.font, in: inner, options: []) { value, subrange, _ in
                let font = (value as? NSFont) ?? bodyFont
                if !font.fontDescriptor.symbolicTraits.contains(.italic) {
                    result.addAttribute(.obliqueness, value: 0.18, range: subrange)
                }
            }
        }
        styleMatches(#"(?<!_)_([^_\n]+?)_(?!_)"#) { match in
            let inner = match.range(at: 1)
            guard inner.location != NSNotFound, inner.length > 0 else { return }
            dimMarkers(full: match.range, inner: inner)
            applyFontTraits(.italicFontMask, to: inner)
            result.addAttribute(.foregroundColor, value: sourceEmphasisColor, range: inner)
            result.enumerateAttribute(.font, in: inner, options: []) { value, subrange, _ in
                let font = (value as? NSFont) ?? bodyFont
                if !font.fontDescriptor.symbolicTraits.contains(.italic) {
                    result.addAttribute(.obliqueness, value: 0.18, range: subrange)
                }
            }
        }
        styleMatches(#"~~(.+?)~~"#) { match in
            let inner = match.range(at: 1)
            guard inner.location != NSNotFound, inner.length > 0 else { return }
            dimMarkers(full: match.range, inner: inner)
            result.addAttribute(
                .strikethroughStyle,
                value: NSUnderlineStyle.single.rawValue,
                range: inner
            )
        }

        // Fences / inline code / tables
        styleMatches(#"(?m)^```.*$"#) { match in
            result.addAttributes(
                [
                    .foregroundColor: NSColor.systemTeal,
                    .font: NSFont.monospacedSystemFont(ofSize: fontSize * 0.92, weight: .medium),
                ],
                range: match.range
            )
        }
        styleMatches(#"`[^`\n]+`"#) { match in
            result.addAttributes(
                [
                    .foregroundColor: NSColor.systemTeal,
                    .backgroundColor: NSColor.labelColor.withAlphaComponent(0.06),
                    .font: NSFont.monospacedSystemFont(ofSize: fontSize * 0.92, weight: .regular),
                ],
                range: match.range
            )
        }
        styleMatches(#"(?m)^\s*\|.*\|.*$"#) { match in
            result.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: match.range)
        }

        // Links
        styleMatches(#"(?<!!)\[[^\]]*\]\(\s*(?:<([^>]+)>|([^)\s]+))\s*\)"#) { match in
            let destRange = match.range(at: 1).location != NSNotFound ? match.range(at: 1) : match.range(at: 2)
            guard destRange.location != NSNotFound else { return }
            var dest = display.substring(with: destRange).trimmingCharacters(in: .whitespacesAndNewlines)
            if dest.hasPrefix("<"), dest.hasSuffix(">") { dest = String(dest.dropFirst().dropLast()) }
            let url: URL? = {
                if dest.hasPrefix("http://") || dest.hasPrefix("https://") { return URL(string: dest) }
                return ImageReferences.fileURL(forDestination: dest, noteDirectory: noteDirectory)
            }()
            if let url {
                result.addAttributes(
                    [
                        .link: url,
                        .foregroundColor: NSColor.linkColor,
                    ],
                    range: match.range
                )
            }
        }
        styleMatches(#"https?://[^\s<>\]]+"#) { match in
            if let url = URL(string: display.substring(with: match.range)) {
                result.addAttribute(.link, value: url, range: match.range)
            }
        }
    }

    private func applyTypingAttributes() {
        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: sourceBodyColor,
        ]
        for tv in columnViews {
            // Only typingAttributes — setting `tv.font` reattributes the entire
            // document and wipes heading sizes/colors.
            tv.typingAttributes = attrs
        }
    }

    // MARK: - Keys / edit helpers

    /// True when this sticky should handle a monitored key event (not every open note).
    private func isTarget(for event: NSEvent) -> Bool {
        guard let window else { return false }
        // Match the sticky that received the key. Fall back to keyWindow when
        // `event.window` is nil (seen with some panel key equivalents).
        let windowMatches = (event.window === window)
            || (event.window == nil && window.isKeyWindow)
        guard windowMatches else { return false }
        guard let fr = window.firstResponder as? SourceNSTextView,
              columnViews.contains(where: { $0 === fr })
        else { return false }
        return true
    }

    private func handleKeyDown(_ event: NSEvent) -> NSEvent? {
        guard isTarget(for: event) else { return event }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let chars = event.charactersIgnoringModifiers ?? ""

        // Floating sticky panels often don’t deliver ⌘V via `paste(_:)` reliably —
        // handle image paste here, with a short debounce so `paste(_:)` can’t double-save.
        if flags.contains(.command), !flags.contains(.option),
           chars.lowercased() == "v",
           NoteImageStore.clipboardHasImage() {
            if pasteImageFromClipboard() { return nil }
        }

        if flags == .command, chars.lowercased() == "b" {
            wrapSelection(with: "**"); return nil
        }
        if flags == .command, chars.lowercased() == "i" {
            wrapSelection(with: "*"); return nil
        }
        if flags == [.command, .shift], chars.lowercased() == "x" {
            wrapSelection(with: "~~"); return nil
        }
        // ⌥↑ / ⌥↓ is handled in SourceNSTextView.keyDown (not here — would double-move).
        if flags.isEmpty, event.keyCode == 48 {
            if adjustListIndent(outdent: false) { return nil }
            return event
        }
        if flags == .shift, event.keyCode == 48 {
            if adjustListIndent(outdent: true) { return nil }
            return event
        }
        return event
    }

    /// Swap the selected line block with the previous (`-1`) or next (`+1`) line.
    private func moveSelectedLines(direction: Int) {
        guard direction == -1 || direction == 1 else { return }
        guard let tv = window?.firstResponder as? SourceNSTextView ?? primaryTextView() else { return }

        let plain = serializeMarkdown()
        let ns = plain as NSString
        guard ns.length > 0 else { return }

        let attrSel = tv.selectedRange()
        let plainStart = plainOffset(forAttributedLocation: attrSel.location)
        let plainEnd = plainOffset(forAttributedLocation: NSMaxRange(attrSel))

        var start = 0, end = 0, contentsEnd = 0
        ns.getLineStart(
            &start,
            end: &end,
            contentsEnd: &contentsEnd,
            for: NSRange(location: min(plainStart, ns.length), length: 0)
        )
        if plainEnd > plainStart {
            var endStart = 0, endEnd = 0, endContents = 0
            let probe = min(max(plainStart, plainEnd - 1), max(0, ns.length - 1))
            ns.getLineStart(
                &endStart,
                end: &endEnd,
                contentsEnd: &endContents,
                for: NSRange(location: probe, length: 0)
            )
            end = endEnd
        }
        let blockRange = NSRange(location: start, length: end - start)
        guard blockRange.length > 0 else { return }
        let block = ns.substring(with: blockRange)
        let caretOffsetInBlock = max(0, plainStart - start)

        if direction < 0 {
            guard start > 0 else { return }
            var prevStart = 0, prevEnd = 0, prevContents = 0
            ns.getLineStart(
                &prevStart,
                end: &prevEnd,
                contentsEnd: &prevContents,
                for: NSRange(location: start - 1, length: 0)
            )
            let prevRange = NSRange(location: prevStart, length: prevEnd - prevStart)
            let prev = ns.substring(with: prevRange)
            let combined = NSRange(location: prevStart, length: end - prevStart)
            let newPlain = ns.replacingCharacters(in: combined, with: block + prev)
            replacePlainMarkdown(newPlain, preferredPlainOffset: prevStart + caretOffsetInBlock)
        } else {
            guard end < ns.length else { return }
            var nextStart = 0, nextEnd = 0, nextContents = 0
            ns.getLineStart(
                &nextStart,
                end: &nextEnd,
                contentsEnd: &nextContents,
                for: NSRange(location: end, length: 0)
            )
            let nextRange = NSRange(location: nextStart, length: nextEnd - nextStart)
            let next = ns.substring(with: nextRange)
            let combined = NSRange(location: start, length: nextEnd - start)
            let newPlain = ns.replacingCharacters(in: combined, with: next + block)
            replacePlainMarkdown(
                newPlain,
                preferredPlainOffset: start + (next as NSString).length + caretOffsetInBlock
            )
        }
        hasUnpublishedEdits = true
        onTypingActivity?()
        publish(immediate: false)
    }

    private func wrapSelection(with marker: String) {
        guard let tv = window?.firstResponder as? SourceNSTextView ?? primaryTextView() else { return }
        // Work in plain markdown space for correct round-trip with attachments.
        let plain = serializeMarkdown()
        let ns = plain as NSString
        let attrRange = tv.selectedRange()
        var start = plainOffset(forAttributedLocation: attrRange.location)
        var end = plainOffset(forAttributedLocation: NSMaxRange(attrRange))
        if start == end {
            var s = start
            var e = end
            let whitespace = CharacterSet.whitespacesAndNewlines
            while s > 0 {
                let ch = ns.character(at: s - 1)
                if let scalar = UnicodeScalar(ch), whitespace.contains(scalar) { break }
                s -= 1
            }
            while e < ns.length {
                let ch = ns.character(at: e)
                if let scalar = UnicodeScalar(ch), whitespace.contains(scalar) { break }
                e += 1
            }
            start = s; end = e
        }
        let range = NSRange(location: start, length: max(0, end - start))
        let selected = ns.substring(with: range)
        let wrapped: String
        if selected.hasPrefix(marker), selected.hasSuffix(marker), selected.count >= marker.count * 2 {
            wrapped = String(selected.dropFirst(marker.count).dropLast(marker.count))
        } else {
            wrapped = marker + selected + marker
        }
        let newPlain = ns.replacingCharacters(in: range, with: wrapped)
        replacePlainMarkdown(newPlain, preferredPlainOffset: start + (wrapped.hasPrefix(marker) ? marker.count : 0))
        hasUnpublishedEdits = true
        onTypingActivity?()
        publish(immediate: false)
    }

    /// Returns true when the line looks like a list item and indent was applied.
    @discardableResult
    private func adjustListIndent(outdent: Bool) -> Bool {
        let plain = serializeMarkdown()
        let ns = plain as NSString
        let attrLoc = (window?.firstResponder as? NSTextView)?.selectedRange().location
            ?? primaryTextView()?.selectedRange().location
            ?? 0
        let loc = plainOffset(forAttributedLocation: attrLoc)
        var lineStart = 0, lineEnd = 0, contentsEnd = 0
        ns.getLineStart(&lineStart, end: &lineEnd, contentsEnd: &contentsEnd, for: NSRange(location: loc, length: 0))
        let lineRange = NSRange(location: lineStart, length: lineEnd - lineStart)
        var line = ns.substring(with: lineRange)
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let listPrefix = trimmed.range(of: #"^([-*+]|\d+\.)\s+"#, options: .regularExpression) != nil
        guard listPrefix || outdent else { return false }

        let indent = "  "
        if outdent {
            if line.hasPrefix(indent) {
                line = String(line.dropFirst(indent.count))
            } else if line.hasPrefix("\t") {
                line = String(line.dropFirst())
            } else {
                return false
            }
        } else {
            line = indent + line
        }
        let newPlain = ns.replacingCharacters(in: lineRange, with: line)
        replacePlainMarkdown(newPlain, preferredPlainOffset: loc + (outdent ? -indent.count : indent.count))
        hasUnpublishedEdits = true
        onTypingActivity?()
        publish(immediate: false)
        return true
    }

    private func publish(immediate: Bool) {
        guard !suppressPublish else { return }
        if immediate {
            publishTask?.cancel()
            publishTask = nil
            hasUnpublishedEdits = false
            onTextChange?(serializeMarkdown())
            return
        }
        publishTask?.cancel()
        publishTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: publishDebounceNanoseconds)
            guard !Task.isCancelled else { return }
            self.hasUnpublishedEdits = false
            self.onTextChange?(self.serializeMarkdown())
        }
    }

    // MARK: - Images

    @discardableResult
    private func pasteImageFromClipboard() -> Bool {
        if isReadOnly { return true }
        if let last = lastImagePasteAt, Date().timeIntervalSince(last) < 0.4 {
            return true // already handled this gesture
        }
        guard let image = NoteImageStore.imageFromClipboard() else { return false }
        lastImagePasteAt = Date()
        insertImage(image)
        return true
    }

    private func insertDroppedImageFiles(_ urls: [URL]) {
        guard !isReadOnly else { return }
        for url in urls {
            do {
                let relative = try NoteImageStore.saveImageFile(from: url, nextToNote: noteURL)
                insertMarkdownSnippet(NoteImageStore.markdownSnippet(relativePath: relative))
            } catch { continue }
        }
    }

    private func insertImage(_ image: NSImage) {
        do {
            let relative = try NoteImageStore.saveImage(image, nextToNote: noteURL)
            insertMarkdownSnippet(NoteImageStore.markdownSnippet(relativePath: relative))
        } catch { return }
    }

    private func insertMarkdownSnippet(_ snippet: String) {
        let insert = snippet + "\n"
        let plain = serializeMarkdown() as NSString
        let attrLoc = (window?.firstResponder as? NSTextView)?.selectedRange().location
            ?? primaryTextView()?.selectedRange().location
            ?? plain.length
        let loc = plainOffset(forAttributedLocation: attrLoc)
        let newPlain = plain.replacingCharacters(in: NSRange(location: loc, length: 0), with: insert)
        replacePlainMarkdown(newPlain, preferredPlainOffset: loc + (insert as NSString).length)
        hasUnpublishedEdits = true
        onTypingActivity?()
        publish(immediate: true)
        onRequestImmediateSave?()
    }

    private func dragHasImage(_ sender: NSDraggingInfo) -> Bool {
        !NoteImageStore.imageURLs(from: sender).isEmpty
            || NoteImageStore.pasteboardHasImage(sender.draggingPasteboard)
    }

    private func updateDropCaret(with sender: NSDraggingInfo) {
        guard let tv = primaryTextView() else { return }
        let point = tv.convert(sender.draggingLocation, from: nil)
        let idx = tv.characterIndexForInsertion(at: point)
        tv.setSelectedRange(NSRange(location: idx, length: 0))
        if let layoutManager = tv.layoutManager, let container = tv.textContainer {
            let glyphIndex = layoutManager.glyphIndexForCharacter(at: min(idx, max(0, textStorage.length - 1)))
            var fraction: CGFloat = 0
            let rect = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil, withoutAdditionalLayout: true)
            _ = fraction
            let origin = tv.textContainerOrigin
            let y = origin.y + rect.minY
            let lineRect = NSRect(x: 8, y: y, width: max(40, editContainer.bounds.width - 16), height: 2)
            dropCaret.frame = editContainer.convert(lineRect, from: tv)
            dropCaret.isHidden = false
            editContainer.addSubview(dropCaret) // keep on top
        }
    }

    private func placeCaretForDrop(_ sender: NSDraggingInfo) {
        guard let tv = primaryTextView() else { return }
        let point = tv.convert(sender.draggingLocation, from: nil)
        let idx = tv.characterIndexForInsertion(at: point)
        tv.setSelectedRange(NSRange(location: idx, length: 0))
        window?.makeFirstResponder(tv)
    }

}

// MARK: - Attachment

private final class MarkdownImageAttachment: NSTextAttachment {
    let markdownSnippet: String
    let fileURL: URL

    init(markdownSnippet: String, fileURL: URL, image: NSImage, maxWidth: CGFloat) {
        self.markdownSnippet = markdownSnippet
        self.fileURL = fileURL
        super.init(data: nil, ofType: nil)
        let sized = Self.scaled(image, maxWidth: maxWidth)
        self.image = sized
        let cell = NSTextAttachmentCell(imageCell: sized)
        self.attachmentCell = cell
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private static func scaled(_ image: NSImage, maxWidth: CGFloat) -> NSImage {
        let size = image.size
        guard size.width > maxWidth, size.width > 0 else { return image }
        let scale = maxWidth / size.width
        let newSize = NSSize(width: maxWidth, height: max(1, size.height * scale))
        let result = NSImage(size: newSize)
        result.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: newSize), from: .zero, operation: .copy, fraction: 1)
        result.unlockFocus()
        return result
    }
}

// MARK: - Text view

private final class SourceNSTextView: NSTextView {
    var onPasteImage: (() -> Bool)?
    var onInsertDroppedImages: (([URL]) -> Void)?
    var onOpenAttachment: ((URL) -> Void)?
    /// ⌥↑ / ⌥↓ line move — handled here so NSTextView can’t eat the arrows first.
    var onMoveLines: ((Int) -> Bool)?
    var quickLookURL: URL?
    var quickLookDataSource: QLPreviewPanelDataSource?

    private var mouseDownPoint: NSPoint?
    private var mouseDownAttachmentURL: URL?
    private var cursorTracking: NSTrackingArea?

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let chord = flags.intersection([.command, .option, .control, .shift])
        if chord == .option {
            if event.keyCode == 126 || event.specialKey == .upArrow {
                if onMoveLines?(-1) == true { return }
            }
            if event.keyCode == 125 || event.specialKey == .downArrow {
                if onMoveLines?(1) == true { return }
            }
        }
        super.keyDown(with: event)
    }

    override func paste(_ sender: Any?) {
        if NoteImageStore.clipboardHasImage(), onPasteImage?() == true { return }
        super.paste(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = NoteImageStore.imageURLs(from: sender)
        if !urls.isEmpty {
            onInsertDroppedImages?(urls)
            return true
        }
        return super.performDragOperation(sender)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if !NoteImageStore.imageURLs(from: sender).isEmpty { return .copy }
        return super.draggingEntered(sender)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let cursorTracking { removeTrackingArea(cursorTracking) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.activeInKeyWindow, .mouseMoved, .cursorUpdate, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        cursorTracking = area
    }

    /// Discard NSTextView’s full-bounds I-beam rects — we set the cursor ourselves.
    override func resetCursorRects() {}

    override func cursorUpdate(with event: NSEvent) {
        applyCursor(for: event)
    }

    override func mouseMoved(with event: NSEvent) {
        // Do not call super: NSTextView.mouseMoved forces I-beam over the whole view.
        applyCursor(for: event)
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        quickLookURL != nil
    }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = quickLookDataSource
        panel.delegate = nil
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
        quickLookURL = nil
    }

    override func mouseDown(with event: NSEvent) {
        if let url = imageAttachment(at: event)?.fileURL {
            // Don’t call super — NSTextView would select/drag the attachment
            // and eat the click before we can open Quick Look.
            mouseDownPoint = event.locationInWindow
            mouseDownAttachmentURL = url
            return
        }
        mouseDownPoint = nil
        mouseDownAttachmentURL = nil
        super.mouseDown(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        let downPoint = mouseDownPoint
        let downURL = mouseDownAttachmentURL
        mouseDownPoint = nil
        mouseDownAttachmentURL = nil

        if let start = downPoint, let url = downURL {
            let dx = event.locationInWindow.x - start.x
            let dy = event.locationInWindow.y - start.y
            if hypot(dx, dy) < 6 {
                onOpenAttachment?(url)
            }
            return
        }
        super.mouseUp(with: event)
    }

    override func magnify(with event: NSEvent) {
        // No Safari-style zoom in NSTextView; ignore pinch (don’t open previews/links).
    }

    private func applyCursor(for event: NSEvent) {
        if imageAttachment(at: event) != nil || link(at: event) {
            NSCursor.pointingHand.set()
        } else if isOverGlyphs(event) {
            NSCursor.iBeam.set()
        } else {
            NSCursor.arrow.set()
        }
    }

    /// True only over actual line fragments / attachments — not empty column chrome.
    private func isOverGlyphs(_ event: NSEvent) -> Bool {
        guard let lm = layoutManager, let tc = textContainer, let storage = textStorage else {
            return true
        }
        if storage.length == 0 { return true }

        let pointInView = convert(event.locationInWindow, from: nil)
        let origin = textContainerOrigin
        let p = NSPoint(x: pointInView.x - origin.x, y: pointInView.y - origin.y)

        let used = lm.usedRect(for: tc).insetBy(dx: -3, dy: -2)
        guard used.contains(p) else { return false }

        var fraction: CGFloat = 0
        let glyphIndex = lm.glyphIndex(for: p, in: tc, fractionOfDistanceThroughGlyph: &fraction)
        guard lm.numberOfGlyphs > 0 else { return false }
        let gi = min(glyphIndex, lm.numberOfGlyphs - 1)
        let line = lm.lineFragmentUsedRect(forGlyphAt: gi, effectiveRange: nil)
        return line.insetBy(dx: -4, dy: -2).contains(p)
    }

    private func link(at event: NSEvent) -> Bool {
        guard let lm = layoutManager, let tc = textContainer, let storage = textStorage, storage.length > 0 else {
            return false
        }
        let pointInView = convert(event.locationInWindow, from: nil)
        let origin = textContainerOrigin
        let p = NSPoint(x: pointInView.x - origin.x, y: pointInView.y - origin.y)
        let used = lm.usedRect(for: tc)
        guard used.insetBy(dx: -2, dy: -2).contains(p) else { return false }

        var fraction: CGFloat = 0
        let glyphIndex = lm.glyphIndex(for: p, in: tc, fractionOfDistanceThroughGlyph: &fraction)
        let charIndex = lm.characterIndexForGlyph(at: min(glyphIndex, max(0, lm.numberOfGlyphs - 1)))
        return storage.attribute(.link, at: charIndex, effectiveRange: nil) != nil
    }

    private func imageAttachment(at event: NSEvent) -> MarkdownImageAttachment? {
        guard let lm = layoutManager, let tc = textContainer, let storage = textStorage, storage.length > 0 else {
            return nil
        }
        let pointInView = convert(event.locationInWindow, from: nil)
        let origin = textContainerOrigin
        let p = NSPoint(x: pointInView.x - origin.x, y: pointInView.y - origin.y)

        var fraction: CGFloat = 0
        let glyphIndex = lm.glyphIndex(for: p, in: tc, fractionOfDistanceThroughGlyph: &fraction)
        let charIndex = lm.characterIndexForGlyph(at: min(glyphIndex, max(0, lm.numberOfGlyphs - 1)))

        // Insertion-index quirk: click on an attachment may resolve to idx or idx-1.
        for idx in Set([charIndex, max(0, charIndex - 1), min(storage.length - 1, charIndex + 1)]) {
            var range = NSRange(location: 0, length: 0)
            guard let attachment = storage.attribute(.attachment, at: idx, effectiveRange: &range) as? MarkdownImageAttachment else {
                continue
            }
            let glyphRange = lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let bounds = lm.boundingRect(forGlyphRange: glyphRange, in: tc)
            if bounds.insetBy(dx: -3, dy: -3).contains(p) {
                return attachment
            }
        }
        return nil
    }
}

/// Top-left origin so tall notes don’t open scrolled into empty space below the text.
private final class FlippedEditContainer: NSView {
    override var isFlipped: Bool { true }
}

/// Nonisolated QL bridge so MainActor editor type need not conform to QLPreviewPanelDataSource.
private final class QuickLookBridge: NSObject, QLPreviewPanelDataSource {
    var url: URL?

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { url == nil ? 0 : 1 }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem {
        (url ?? URL(fileURLWithPath: "/")) as NSURL
    }
}

private final class SourceDropCaretLineView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.systemBlue.cgColor
        layer?.cornerRadius = 1
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private extension NoteImageStore {
    static func pasteboardHasImage(_ pb: NSPasteboard) -> Bool {
        if pb.canReadObject(forClasses: [NSImage.self], options: nil) { return true }
        for type in [NSPasteboard.PasteboardType.png, .tiff] where pb.data(forType: type) != nil {
            return true
        }
        return false
    }

    static func imageFromPasteboard(_ pb: NSPasteboard) -> NSImage? {
        if let images = pb.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage],
           let first = images.first {
            return first
        }
        for type in [NSPasteboard.PasteboardType.png, .tiff] {
            if let data = pb.data(forType: type), let image = NSImage(data: data) {
                return image
            }
        }
        return nil
    }
}
