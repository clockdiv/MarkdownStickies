import AppKit
import MarkdownStickiesCore
import WebKit

/// Checklist of HTML tags + live sticky-style preview of the converted Markdown.
@MainActor
final class HTMLConvertWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
    private let sourceHTML: String
    private let noteURL: URL
    private let background: NSColor
    private let fontSize: Double
    private let onApply: (String) -> Void
    var onClose: (() -> Void)?

    private var tags: [HTMLToMarkdown.TagInfo]
    private var enabled: Set<String>
    private var tableView: NSTableView!
    private var previewWebView: WKWebView!
    private var previewContainer: NSView!
    private var statusLabel: NSTextField!

    init(
        sourceHTML: String,
        noteURL: URL,
        background: NSColor,
        fontSize: Double,
        onApply: @escaping (String) -> Void
    ) {
        self.sourceHTML = sourceHTML
        self.noteURL = noteURL
        self.background = background
        self.fontSize = fontSize
        self.onApply = onApply
        self.tags = HTMLToMarkdown.inventory(in: sourceHTML)
        self.enabled = Set(tags.filter(\.defaultEnabled).map(\.name))

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 920, height: 560),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Convert HTML to Markdown"
        window.minSize = NSSize(width: 640, height: 400)
        window.isReleasedWhenClosed = false

        super.init(window: window)
        window.delegate = self
        buildUI()
        refreshPreview()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func buildUI() {
        guard let window else { return }

        let root = NSView(frame: .zero)
        root.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = root

        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.translatesAutoresizingMaskIntoConstraints = false
        split.autosaveName = "HTMLConvertSplit"
        root.addSubview(split)

        let left = makeChecklistPane()
        left.translatesAutoresizingMaskIntoConstraints = true
        left.autoresizingMask = [.width, .height]
        left.frame = NSRect(x: 0, y: 0, width: 340, height: 500)

        let right = makePreviewPane()
        right.translatesAutoresizingMaskIntoConstraints = true
        right.autoresizingMask = [.width, .height]
        right.frame = NSRect(x: 0, y: 0, width: 540, height: 500)

        split.addSubview(left)
        split.addSubview(right)
        split.setHoldingPriority(.defaultLow + 1, forSubviewAt: 0)
        split.setHoldingPriority(.defaultLow, forSubviewAt: 1)

        NSLayoutConstraint.activate([
            split.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            split.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            split.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            split.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
        ])

        DispatchQueue.main.async { [weak split] in
            guard let split, split.subviews.count == 2 else { return }
            let total = split.bounds.width
            guard total > 40 else { return }
            split.setPosition(min(340, total * 0.4), ofDividerAt: 0)
        }
    }

    private func makeChecklistPane() -> NSView {
        let pane = NSView(frame: .zero)
        pane.translatesAutoresizingMaskIntoConstraints = false

        let headline = NSTextField(labelWithString: "Tags in this note")
        headline.font = .systemFont(ofSize: 13, weight: .semibold)
        headline.translatesAutoresizingMaskIntoConstraints = false

        let hint = NSTextField(wrappingLabelWithString: "Checked tags convert (or unwrap / remove). Unchecked tags stay as HTML.")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.translatesAutoresizingMaskIntoConstraints = false

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.autohidesScrollers = true

        let table = NSTableView()
        table.headerView = NSTableHeaderView()
        table.allowsMultipleSelection = false
        table.allowsEmptySelection = true
        table.rowHeight = 28
        table.usesAlternatingRowBackgroundColors = true
        table.style = .inset
        table.dataSource = self
        table.delegate = self

        let checkCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("check"))
        checkCol.title = ""
        checkCol.width = 28
        checkCol.minWidth = 28
        checkCol.maxWidth = 28
        table.addTableColumn(checkCol)

        let tagCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("tag"))
        tagCol.title = "Tag"
        tagCol.width = 70
        table.addTableColumn(tagCol)

        let countCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("count"))
        countCol.title = "#"
        countCol.width = 36
        countCol.minWidth = 30
        table.addTableColumn(countCol)

        let detailCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("detail"))
        detailCol.title = "Action"
        detailCol.width = 160
        table.addTableColumn(detailCol)

        scroll.documentView = table
        self.tableView = table

        let defaultsBtn = NSButton(title: "Defaults", target: self, action: #selector(resetDefaults))
        defaultsBtn.bezelStyle = .rounded
        defaultsBtn.translatesAutoresizingMaskIntoConstraints = false

        let allBtn = NSButton(title: "All", target: self, action: #selector(selectAllTags))
        allBtn.bezelStyle = .rounded
        allBtn.translatesAutoresizingMaskIntoConstraints = false

        let noneBtn = NSButton(title: "None", target: self, action: #selector(selectNoneTags))
        noneBtn.bezelStyle = .rounded
        noneBtn.translatesAutoresizingMaskIntoConstraints = false

        let cancelBtn = NSButton(title: "Cancel", target: self, action: #selector(cancelPressed))
        cancelBtn.bezelStyle = .rounded
        cancelBtn.translatesAutoresizingMaskIntoConstraints = false
        cancelBtn.keyEquivalent = "\u{1b}"

        let convertBtn = NSButton(title: "Convert", target: self, action: #selector(convertPressed))
        convertBtn.bezelStyle = .rounded
        convertBtn.translatesAutoresizingMaskIntoConstraints = false
        convertBtn.keyEquivalent = "\r"

        let status = NSTextField(labelWithString: "")
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.translatesAutoresizingMaskIntoConstraints = false
        status.maximumNumberOfLines = 2
        status.lineBreakMode = .byWordWrapping
        self.statusLabel = status

        let buttonRow = NSStackView(views: [defaultsBtn, allBtn, noneBtn, NSView(), cancelBtn, convertBtn])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8
        buttonRow.translatesAutoresizingMaskIntoConstraints = false

        pane.addSubview(headline)
        pane.addSubview(hint)
        pane.addSubview(scroll)
        pane.addSubview(status)
        pane.addSubview(buttonRow)

        NSLayoutConstraint.activate([
            headline.topAnchor.constraint(equalTo: pane.topAnchor),
            headline.leadingAnchor.constraint(equalTo: pane.leadingAnchor),
            headline.trailingAnchor.constraint(equalTo: pane.trailingAnchor),

            hint.topAnchor.constraint(equalTo: headline.bottomAnchor, constant: 4),
            hint.leadingAnchor.constraint(equalTo: pane.leadingAnchor),
            hint.trailingAnchor.constraint(equalTo: pane.trailingAnchor),

            scroll.topAnchor.constraint(equalTo: hint.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: pane.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: pane.trailingAnchor),

            status.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 8),
            status.leadingAnchor.constraint(equalTo: pane.leadingAnchor),
            status.trailingAnchor.constraint(equalTo: pane.trailingAnchor),

            buttonRow.topAnchor.constraint(equalTo: status.bottomAnchor, constant: 8),
            buttonRow.leadingAnchor.constraint(equalTo: pane.leadingAnchor),
            buttonRow.trailingAnchor.constraint(equalTo: pane.trailingAnchor),
            buttonRow.bottomAnchor.constraint(equalTo: pane.bottomAnchor),
        ])

        return pane
    }

    private func makePreviewPane() -> NSView {
        let pane = NSView(frame: .zero)
        pane.translatesAutoresizingMaskIntoConstraints = false

        let headline = NSTextField(labelWithString: "Preview sticky")
        headline.font = .systemFont(ofSize: 13, weight: .semibold)
        headline.translatesAutoresizingMaskIntoConstraints = false

        let sticky = NSView(frame: .zero)
        sticky.wantsLayer = true
        sticky.layer?.backgroundColor = background.cgColor
        sticky.layer?.cornerRadius = 8
        sticky.layer?.masksToBounds = true
        sticky.translatesAutoresizingMaskIntoConstraints = false
        self.previewContainer = sticky

        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        let web = WKWebView(frame: .zero, configuration: config)
        web.setValue(false, forKey: "drawsBackground")
        if #available(macOS 12.0, *) {
            web.underPageBackgroundColor = background
        }
        web.translatesAutoresizingMaskIntoConstraints = false
        sticky.addSubview(web)
        self.previewWebView = web

        pane.addSubview(headline)
        pane.addSubview(sticky)

        NSLayoutConstraint.activate([
            headline.topAnchor.constraint(equalTo: pane.topAnchor),
            headline.leadingAnchor.constraint(equalTo: pane.leadingAnchor),
            headline.trailingAnchor.constraint(equalTo: pane.trailingAnchor),

            sticky.topAnchor.constraint(equalTo: headline.bottomAnchor, constant: 8),
            sticky.leadingAnchor.constraint(equalTo: pane.leadingAnchor),
            sticky.trailingAnchor.constraint(equalTo: pane.trailingAnchor),
            sticky.bottomAnchor.constraint(equalTo: pane.bottomAnchor),

            web.topAnchor.constraint(equalTo: sticky.topAnchor, constant: 8),
            web.leadingAnchor.constraint(equalTo: sticky.leadingAnchor, constant: 8),
            web.trailingAnchor.constraint(equalTo: sticky.trailingAnchor, constant: -8),
            web.bottomAnchor.constraint(equalTo: sticky.bottomAnchor, constant: -8),
        ])

        return pane
    }

    private func currentResult() -> HTMLToMarkdown.Result {
        HTMLToMarkdown.convert(sourceHTML, enabledTags: enabled)
    }

    private func refreshPreview() {
        let result = currentResult()
        var info = "Converted \(result.convertedTags) · stripped \(result.strippedTags) · residual \(result.residualHTMLBlocks)"
        if tags.isEmpty {
            info = "No HTML tags found."
        }
        statusLabel.stringValue = info

        let blocks = MarkdownBlockParser.parse(result.markdown)
        let html = MarkdownHTMLRenderer.document(
            blocks: blocks,
            activeIndex: nil,
            backgroundHex: background.reliableHexString,
            noteDirectory: noteURL.deletingLastPathComponent(),
            fontSize: fontSize,
            columnCount: 1
        )
        let base = noteURL.deletingLastPathComponent()
        previewWebView.loadHTMLString(html, baseURL: base)
    }

    // MARK: - Actions

    @objc private func toggleTag(_ sender: NSButton) {
        let row = sender.tag
        guard tags.indices.contains(row) else { return }
        let name = tags[row].name
        if sender.state == .on {
            enabled.insert(name)
        } else {
            enabled.remove(name)
        }
        refreshPreview()
    }

    @objc private func resetDefaults() {
        enabled = Set(tags.filter(\.defaultEnabled).map(\.name))
        tableView.reloadData()
        refreshPreview()
    }

    @objc private func selectAllTags() {
        enabled = Set(tags.map(\.name))
        tableView.reloadData()
        refreshPreview()
    }

    @objc private func selectNoneTags() {
        enabled = []
        tableView.reloadData()
        refreshPreview()
    }

    @objc private func cancelPressed() {
        window?.close()
    }

    @objc private func convertPressed() {
        let result = currentResult()
        onApply(result.markdown)
        window?.close()
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int {
        tags.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard tags.indices.contains(row) else { return nil }
        let tag = tags[row]
        let id = tableColumn?.identifier.rawValue ?? ""

        switch id {
        case "check":
            let button = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggleTag(_:)))
            button.state = enabled.contains(tag.name) ? .on : .off
            button.tag = row
            return button
        case "tag":
            let field = NSTextField(labelWithString: "<\(tag.name)>")
            field.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            return field
        case "count":
            let field = NSTextField(labelWithString: "\(tag.count)")
            field.alignment = .right
            field.textColor = .secondaryLabelColor
            return field
        case "detail":
            let field = NSTextField(labelWithString: tag.detail)
            field.textColor = .secondaryLabelColor
            field.font = .systemFont(ofSize: 11)
            field.lineBreakMode = .byTruncatingTail
            return field
        default:
            return nil
        }
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
        onClose = nil
    }
}
