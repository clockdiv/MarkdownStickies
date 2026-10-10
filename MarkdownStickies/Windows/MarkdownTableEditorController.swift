import AppKit

/// Lightweight sheet to edit a GFM pipe table and write markdown back.
@MainActor
final class MarkdownTableEditorController: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
    struct DetectedTable {
        /// Line indices in the document’s `components(separatedBy: "\n")` array.
        var lineRange: Range<Int>
        var headers: [String]
        var rows: [[String]]
        var alignments: [String]
    }

    var onClose: (() -> Void)?

    private let onApply: ([String]) -> Void
    private var headers: [String]
    private var rows: [[String]]
    private var alignments: [String]
    private let panel: NSPanel
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()

    init(table: DetectedTable, onApply: @escaping ([String]) -> Void) {
        self.onApply = onApply
        self.headers = table.headers
        self.rows = table.rows
        self.alignments = table.alignments

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 360),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Edit Table"
        panel.isFloatingPanel = true
        panel.level = .floating
        self.panel = panel
        super.init()
        panel.delegate = self
        buildUI()
    }

    func show() {
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }

    // MARK: - Detection

    static func detectTable(in markdown: String, utf16Offset: Int) -> DetectedTable? {
        let lines = markdown.components(separatedBy: "\n")
        guard !lines.isEmpty else { return nil }

        // Map UTF-16 offset → line index.
        var consumed = 0
        var caretLine = 0
        for (i, line) in lines.enumerated() {
            let len = (line as NSString).length + (i < lines.count - 1 ? 1 : 0)
            if consumed + len > utf16Offset {
                caretLine = i
                break
            }
            consumed += len
            caretLine = i
        }

        func isTableLine(_ s: String) -> Bool {
            let t = s.trimmingCharacters(in: .whitespaces)
            return t.contains("|") && !t.isEmpty
        }
        func isSeparator(_ s: String) -> Bool {
            let t = s.trimmingCharacters(in: .whitespaces)
            guard t.contains("|") || t.contains("-") else { return false }
            let stripped = t.replacingOccurrences(of: "|", with: "")
                .replacingOccurrences(of: ":", with: "")
                .replacingOccurrences(of: "-", with: "")
                .replacingOccurrences(of: " ", with: "")
            return stripped.isEmpty && t.contains("-")
        }

        guard isTableLine(lines[caretLine]) else { return nil }

        var start = caretLine
        while start > 0, isTableLine(lines[start - 1]) { start -= 1 }
        var end = caretLine
        while end + 1 < lines.count, isTableLine(lines[end + 1]) { end += 1 }

        let block = Array(lines[start...end])
        guard block.count >= 2, isSeparator(block[1]) else { return nil }

        let headers = splitRow(block[0])
        guard !headers.isEmpty else { return nil }
        let alignments = splitRow(block[1]).map { alignToken($0) }
        var rows: [[String]] = []
        for line in block.dropFirst(2) {
            var cells = splitRow(line)
            while cells.count < headers.count { cells.append("") }
            if cells.count > headers.count { cells = Array(cells.prefix(headers.count)) }
            rows.append(cells)
        }
        var aligns = alignments
        while aligns.count < headers.count { aligns.append("---") }
        if aligns.count > headers.count { aligns = Array(aligns.prefix(headers.count)) }

        return DetectedTable(
            lineRange: start..<(end + 1),
            headers: headers,
            rows: rows,
            alignments: aligns
        )
    }

    private static func splitRow(_ line: String) -> [String] {
        var s = line.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("|") { s.removeFirst() }
        if s.hasSuffix("|") { s.removeLast() }
        return s.split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func alignToken(_ cell: String) -> String {
        let t = cell.trimmingCharacters(in: .whitespaces)
        let left = t.hasPrefix(":")
        let right = t.hasSuffix(":")
        if left && right { return ":---:" }
        if right { return "---:" }
        if left { return ":---" }
        return "---"
    }

    // MARK: - UI

    private func buildUI() {
        let root = NSView(frame: .zero)
        root.translatesAutoresizingMaskIntoConstraints = false

        tableView.headerView = NSTableHeaderView()
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsColumnReordering = false
        tableView.allowsColumnResizing = true
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.dataSource = self
        tableView.delegate = self
        rebuildColumns()

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .bezelBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let addRow = NSButton(title: "Add Row", target: self, action: #selector(addRow))
        let removeRow = NSButton(title: "Remove Row", target: self, action: #selector(removeRow))
        let addCol = NSButton(title: "Add Column", target: self, action: #selector(addColumn))
        let apply = NSButton(title: "Apply", target: self, action: #selector(applyPressed))
        apply.keyEquivalent = "\r"
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelPressed))
        cancel.keyEquivalent = "\u{1b}"

        let buttons = NSStackView(views: [addRow, removeRow, addCol, NSView(), cancel, apply])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(scrollView)
        root.addSubview(buttons)
        panel.contentView = root

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            scrollView.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -10),

            buttons.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            buttons.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            buttons.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
            buttons.heightAnchor.constraint(equalToConstant: 28),
        ])
    }

    private func rebuildColumns() {
        while tableView.tableColumns.count > 0 {
            tableView.removeTableColumn(tableView.tableColumns[0])
        }
        for (i, header) in headers.enumerated() {
            let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("c\(i)"))
            col.title = header.isEmpty ? "Column \(i + 1)" : header
            col.width = 120
            tableView.addTableColumn(col)
        }
        tableView.reloadData()
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        // Row 0 = headers
        1 + rows.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn,
              let idx = Int(tableColumn.identifier.rawValue.dropFirst())
        else { return nil }

        let field = NSTextField(string: "")
        field.isBordered = false
        field.drawsBackground = false
        field.isEditable = true
        field.font = .systemFont(ofSize: 12)
        field.tag = row * 1000 + idx
        field.target = self
        field.action = #selector(cellEdited(_:))

        if row == 0 {
            field.stringValue = idx < headers.count ? headers[idx] : ""
            field.font = .boldSystemFont(ofSize: 12)
        } else {
            let r = row - 1
            field.stringValue = (r < rows.count && idx < rows[r].count) ? rows[r][idx] : ""
        }
        return field
    }

    @objc private func cellEdited(_ sender: NSTextField) {
        let row = sender.tag / 1000
        let col = sender.tag % 1000
        if row == 0 {
            while headers.count <= col { headers.append("") }
            headers[col] = sender.stringValue
            if let column = tableView.tableColumns[safe: col] {
                column.title = sender.stringValue.isEmpty ? "Column \(col + 1)" : sender.stringValue
            }
        } else {
            let r = row - 1
            while rows.count <= r { rows.append(Array(repeating: "", count: headers.count)) }
            while rows[r].count <= col { rows[r].append("") }
            rows[r][col] = sender.stringValue
        }
    }

    @objc private func addRow() {
        rows.append(Array(repeating: "", count: max(1, headers.count)))
        tableView.reloadData()
    }

    @objc private func removeRow() {
        let selected = tableView.selectedRow
        if selected > 0, selected - 1 < rows.count {
            rows.remove(at: selected - 1)
        } else if !rows.isEmpty {
            rows.removeLast()
        }
        tableView.reloadData()
    }

    @objc private func addColumn() {
        headers.append("")
        alignments.append("---")
        for i in rows.indices { rows[i].append("") }
        rebuildColumns()
    }

    @objc private func applyPressed() {
        // Commit first responder edits
        panel.makeFirstResponder(nil)
        var lines: [String] = []
        lines.append("| " + headers.map { $0.isEmpty ? " " : $0 }.joined(separator: " | ") + " |")
        var aligns = alignments
        while aligns.count < headers.count { aligns.append("---") }
        lines.append("| " + aligns.prefix(headers.count).joined(separator: " | ") + " |")
        for row in rows {
            var cells = row
            while cells.count < headers.count { cells.append("") }
            lines.append("| " + cells.prefix(headers.count).map { $0.isEmpty ? " " : $0 }.joined(separator: " | ") + " |")
        }
        onApply(lines)
        panel.close()
    }

    @objc private func cancelPressed() {
        panel.close()
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
