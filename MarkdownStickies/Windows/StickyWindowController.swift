import AppKit
import MarkdownStickiesCore
import SwiftUI

@MainActor
final class StickyWindowController: NSObject, NSWindowDelegate {
    private(set) var notePath: URL
    private let panel: StickyPanel
    private let rootView: NSView
    private let titlebar: StickyTitlebarView
    private let content: NSView & StickyNoteEditorBody
    private var colorMenu: NSMenu?
    private weak var manager: StickyWindowManager?

    private(set) var draftText: String
    private var isDirty = false {
        didSet { manager?.writer?.editors.setUnsavedEdits(isDirty, for: notePath) }
    }
    private var saveTask: Task<Void, Never>?
    /// Saves run one after another, so each one expects the hash the previous one wrote.
    private var pendingSave: Task<Void, Never>?
    /// Bumped on every saveNow; a queued save that isn't the newest skips (the newest writes).
    private var saveGeneration = 0
    /// Hash of the file as this editor last loaded or saved it. A save expects exactly this.
    private var loadedHash: String
    /// Files that can't be written open read-only and never save.
    let isReadOnly: Bool
    /// Set once the window is closed for good (e.g. deleted): no more saves.
    private var isDiscarded = false
    private var suppressExternalReload = false
    /// When false, the editor hides the YAML frontmatter block.
    private var showFrontmatter = false
    private var frontmatterPrefix = ""
    private var frontmatterToggleButton: NSButton?

    var currentColor: NoteColor
    var floatOnTop: Bool
    var noteTitle: String
    var textSize: Double
    var columnCount: Int
    private var textSizeSlider: NSSlider?
    private var textSizeLabel: NSTextField?
    private var columnSlider: NSSlider?
    private var columnLabel: NSTextField?
    private var floatButton: NSButton?
    private var colorSwatchButtons: [StickyColor: NSButton] = [:]
    private var colorPickerButton: NSButton?
    private var isPickingCustomColor = false
    private var sourceEditor: MarkdownSourceEditorView {
        content as! MarkdownSourceEditorView
    }
    private var isCollapsed = false
    private var expandedFrame: NSRect?
    private let normalMinSize = NSSize(width: 180, height: 140)
    private let collapsedHeight: CGFloat = 28
    private var htmlConvertWindow: HTMLConvertWindowController?
    /// Body vertical pins — deactivated while collapsed so Auto Layout can’t fight the titlebar-only height.
    private var bodyTopConstraint: NSLayoutConstraint?
    private var bodyBottomConstraint: NSLayoutConstraint?
    /// Prevents `windowDidResize` ↔ `setFrame` recursion (collapse animation / height lock).
    private var isApplyingPanelFrame = false

    init(
        note: Note,
        content initialText: String,
        loadedHash: String,
        isReadOnly: Bool,
        state: NoteWindowState,
        manager: StickyWindowManager
    ) {
        self.loadedHash = loadedHash
        self.isReadOnly = isReadOnly
        self.notePath = note.path
        self.manager = manager
        self.currentColor = state.color
        self.floatOnTop = state.floatOnTop
        self.noteTitle = note.title
        self.textSize = state.textSize
        self.columnCount = state.columnCount
        let parts = NoteFrontmatter.splitDocument(initialText)
        self.frontmatterPrefix = parts.prefix
        self.showFrontmatter = false
        self.draftText = initialText

        let bg = state.color.nsColor
        let panel = StickyPanel(
            contentRect: state.frame.cgRect,
            // Borderless → no system traffic lights. Custom title bar below.
            styleMask: [.borderless, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = state.floatOnTop ? .floating : .normal
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.hasShadow = true
        panel.isOpaque = true
        panel.backgroundColor = bg
        panel.minSize = normalMinSize
        panel.setFrame(state.frame.cgRect, display: false)
        panel.isMovableByWindowBackground = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.acceptsMouseMovedEvents = true

        let root = NSView(frame: .zero)
        root.wantsLayer = true
        root.layer?.backgroundColor = bg.cgColor
        root.layer?.cornerRadius = 8
        root.layer?.masksToBounds = true

        let titlebar = StickyTitlebarView(frame: .zero)
        titlebar.translatesAutoresizingMaskIntoConstraints = false
        titlebar.noteTitle = note.title
        titlebar.applyBackground(bg)

        let body = MarkdownSourceEditorView(
            noteURL: note.path,
            text: parts.body,
            background: bg,
            fontSize: state.textSize,
            columnCount: state.columnCount
        )
        body.translatesAutoresizingMaskIntoConstraints = false
        body.isReadOnly = isReadOnly
        if isReadOnly { titlebar.noteTitle = note.title + " (read-only)" }

        root.addSubview(titlebar)
        root.addSubview(body)
        let bodyTop = body.topAnchor.constraint(equalTo: titlebar.bottomAnchor)
        let bodyBottom = body.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -8)
        bodyTopConstraint = bodyTop
        bodyBottomConstraint = bodyBottom
        NSLayoutConstraint.activate([
            titlebar.topAnchor.constraint(equalTo: root.topAnchor),
            titlebar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            titlebar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            titlebar.heightAnchor.constraint(equalToConstant: collapsedHeight),

            // Keep root chrome at the sides/bottom so the borderless window’s
            // resize hot-edge isn’t under the editor (I-beam ↔ resize flicker).
            bodyTop,
            body.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            body.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            bodyBottom,
        ])

        panel.contentView = root

        self.panel = panel
        self.rootView = root
        self.titlebar = titlebar
        self.content = body
        super.init()

        body.onTextChange = { [weak self] text in
            self?.handleTextChange(text)
        }
        body.onTypingActivity = { [weak self] in
            self?.markTypingActivity()
        }
        body.onRequestImmediateSave = { [weak self] in
            _ = self?.saveNow()
        }
        titlebar.onDoubleClick = { [weak self] in
            self?.toggleCollapsed()
        }
        titlebar.onClose = { [weak self] in
            self?.panel.close()
        }
        titlebar.onMenuButton = { [weak self] button in
            self?.showColorMenu(button)
        }
        titlebar.onRenameCommit = { [weak self] edited in
            self?.handleRenameCommit(edited)
        }

        panel.delegate = self
        buildColorMenu()
        syncColorMenu()
    }

    private func buildColorMenu() {
        let menu = NSMenu()

        let colorsItem = NSMenuItem()
        colorsItem.view = makeColorRowMenuView()
        menu.addItem(colorsItem)

        menu.addItem(NSMenuItem.separator())

        let sizeItem = NSMenuItem()
        sizeItem.view = makeTextSizeMenuView(initial: textSize)
        menu.addItem(sizeItem)

        let columnsItem = NSMenuItem()
        columnsItem.view = makeColumnsMenuView()
        menu.addItem(columnsItem)

        menu.addItem(NSMenuItem.separator())

        let actionsItem = NSMenuItem()
        actionsItem.view = makeActionsMenuView()
        menu.addItem(actionsItem)

        menu.addItem(NSMenuItem.separator())

        let convertItem = NSMenuItem()
        convertItem.view = makeConvertMenuView()
        menu.addItem(convertItem)

        colorMenu = menu
        syncColorMenu()
    }

    private func showColorMenu(_ sender: NSButton) {
        guard let menu = colorMenu else { return }
        let point = NSPoint(x: sender.bounds.midX - 8, y: sender.bounds.minY - 2)
        menu.popUp(positioning: nil, at: point, in: sender)
    }

    private func makeColorRowMenuView() -> NSView {
        let width: CGFloat = 200
        let height: CGFloat = 36
        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.distribution = .fillEqually
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)

        var buttons: [StickyColor: NSButton] = [:]
        for preset in StickyColor.allCases {
            let button = NSButton(frame: .zero)
            button.bezelStyle = .inline
            button.isBordered = false
            button.imagePosition = .imageOnly
            button.image = colorSwatchImage(preset.nsColor, selected: false)
            button.target = self
            button.action = #selector(presetColorPressed(_:))
            button.tag = StickyColor.allCases.firstIndex(of: preset) ?? 0
            button.setAccessibilityLabel(preset.displayName)
            button.toolTip = preset.displayName
            button.translatesAutoresizingMaskIntoConstraints = false
            stack.addArrangedSubview(button)
            buttons[preset] = button
            button.heightAnchor.constraint(equalToConstant: 28).isActive = true
        }
        colorSwatchButtons = buttons

        let picker = NSButton(frame: .zero)
        picker.bezelStyle = .inline
        picker.isBordered = false
        picker.imagePosition = .imageOnly
        picker.image = NSImage(
            systemSymbolName: "eyedropper",
            accessibilityDescription: "Custom Color"
        )
        picker.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        picker.contentTintColor = .labelColor
        picker.target = self
        picker.action = #selector(openCustomColorPicker(_:))
        picker.setAccessibilityLabel("Custom Color")
        picker.toolTip = "Custom Color"
        picker.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(picker)
        picker.heightAnchor.constraint(equalToConstant: 28).isActive = true
        colorPickerButton = picker

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 4),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -4),
        ])

        return container
    }

    @objc private func presetColorPressed(_ sender: NSButton) {
        let presets = StickyColor.allCases
        guard sender.tag >= 0, sender.tag < presets.count else { return }
        handleColorChange(.preset(presets[sender.tag]))
        colorMenu?.cancelTracking()
    }

    @objc private func openCustomColorPicker(_ sender: Any?) {
        colorMenu?.cancelTracking()
        let panel = NSColorPanel.shared
        panel.showsAlpha = false
        panel.mode = .RGB
        panel.isContinuous = true
        panel.color = currentColor.nsColor
        panel.setTarget(self)
        panel.setAction(#selector(customColorChanged(_:)))
        isPickingCustomColor = true
        panel.orderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func customColorChanged(_ sender: NSColorPanel) {
        guard isPickingCustomColor else { return }
        handleColorChange(NoteColor(nsColor: sender.color))
    }

    private func detachColorPanelIfNeeded() {
        guard isPickingCustomColor else { return }
        let panel = NSColorPanel.shared
        panel.setTarget(nil)
        panel.setAction(nil)
        isPickingCustomColor = false
    }

    private func makeTextSizeMenuView(initial: Double) -> NSView {
        let width: CGFloat = 200
        let height: CGFloat = 44
        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))

        let title = NSTextField(labelWithString: "Text Size")
        title.font = .systemFont(ofSize: 11, weight: .medium)
        title.textColor = .secondaryLabelColor
        title.translatesAutoresizingMaskIntoConstraints = false

        let valueLabel = NSTextField(labelWithString: "\(Int(initial.rounded()))")
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        valueLabel.textColor = .secondaryLabelColor
        valueLabel.alignment = .right
        valueLabel.translatesAutoresizingMaskIntoConstraints = false

        let slider = NSSlider(value: initial,
                              minValue: NoteWindowState.minTextSize,
                              maxValue: NoteWindowState.maxTextSize,
                              target: self,
                              action: #selector(textSizeSliderChanged(_:)))
        slider.isContinuous = true
        slider.controlSize = .small
        slider.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(title)
        container.addSubview(valueLabel)
        container.addSubview(slider)

        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            title.topAnchor.constraint(equalTo: container.topAnchor, constant: 4),

            valueLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
            valueLabel.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            valueLabel.leadingAnchor.constraint(greaterThanOrEqualTo: title.trailingAnchor, constant: 8),
            valueLabel.widthAnchor.constraint(equalToConstant: 24),

            slider.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            slider.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
            slider.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 2),
            slider.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -4),
        ])

        textSizeSlider = slider
        textSizeLabel = valueLabel
        return container
    }

    @objc private func textSizeSliderChanged(_ sender: NSSlider) {
        handleTextSizeChange(sender.doubleValue)
    }

    private func makeColumnsMenuView() -> NSView {
        let width: CGFloat = 200
        let height: CGFloat = 44
        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))

        let title = NSTextField(labelWithString: "Columns")
        title.font = .systemFont(ofSize: 11, weight: .medium)
        title.textColor = .secondaryLabelColor
        title.translatesAutoresizingMaskIntoConstraints = false

        let valueLabel = NSTextField(labelWithString: "\(columnCount)")
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        valueLabel.textColor = .secondaryLabelColor
        valueLabel.alignment = .right
        valueLabel.translatesAutoresizingMaskIntoConstraints = false

        let slider = NSSlider(
            value: Double(columnCount),
            minValue: Double(NoteWindowState.minColumnCount),
            maxValue: Double(NoteWindowState.maxColumnCount),
            target: self,
            action: #selector(columnSliderChanged(_:))
        )
        slider.isContinuous = true
        slider.controlSize = .small
        slider.numberOfTickMarks = NoteWindowState.maxColumnCount - NoteWindowState.minColumnCount + 1
        slider.allowsTickMarkValuesOnly = true
        slider.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(title)
        container.addSubview(valueLabel)
        container.addSubview(slider)

        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            title.topAnchor.constraint(equalTo: container.topAnchor, constant: 4),

            valueLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
            valueLabel.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            valueLabel.leadingAnchor.constraint(greaterThanOrEqualTo: title.trailingAnchor, constant: 8),
            valueLabel.widthAnchor.constraint(equalToConstant: 24),

            slider.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            slider.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
            slider.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 2),
            slider.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -4),
        ])

        columnSlider = slider
        columnLabel = valueLabel
        return container
    }

    @objc private func columnSliderChanged(_ sender: NSSlider) {
        handleColumnCountChange(Int(sender.doubleValue.rounded()))
    }

    private func makeActionsMenuView() -> NSView {
        let width: CGFloat = 230
        let height: CGFloat = 36
        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.distribution = .equalSpacing
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)

        let floatBtn = makeActionIconButton(
            systemName: "pin",
            accessibilityLabel: "Float on Top",
            action: #selector(toggleFloatOnTop(_:))
        )
        let finderBtn = makeActionIconButton(
            systemName: "folder",
            accessibilityLabel: "Show in Finder",
            action: #selector(revealInFinder(_:))
        )
        let frontmatterBtn = makeActionIconButton(
            systemName: "curlybraces",
            accessibilityLabel: "Show Frontmatter",
            action: #selector(toggleFrontmatterPressed(_:))
        )
        let tableBtn = makeActionIconButton(
            systemName: "tablecells",
            accessibilityLabel: "Edit Table",
            action: #selector(editTablePressed(_:))
        )
        let deleteBtn = makeActionIconButton(
            systemName: "trash",
            accessibilityLabel: "Delete Note",
            action: #selector(deleteNotePressed(_:))
        )
        deleteBtn.contentTintColor = .systemRed

        let buttons: [NSButton] = [floatBtn, finderBtn, frontmatterBtn, tableBtn, deleteBtn]

        for btn in buttons {
            stack.addArrangedSubview(btn)
            btn.widthAnchor.constraint(equalToConstant: 28).isActive = true
            btn.heightAnchor.constraint(equalToConstant: 28).isActive = true
        }

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 4),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -4),
        ])

        floatButton = floatBtn
        frontmatterToggleButton = frontmatterBtn
        updateFloatButtonAppearance()
        updateFrontmatterButtonAppearance()
        return container
    }

    private func makeConvertMenuView() -> NSView {
        let width: CGFloat = 200
        let height: CGFloat = 32
        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))

        let button = NSButton(title: "Convert to .md", target: self, action: #selector(convertHTMLToMarkdownPressed(_:)))
        button.bezelStyle = .inline
        button.isBordered = false
        button.alignment = .center
        button.font = .systemFont(ofSize: 12, weight: .medium)
        button.contentTintColor = .labelColor
        button.toolTip = "Convert HTML in this note to Markdown"
        button.setAccessibilityLabel("Convert to .md")
        button.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(button)

        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            button.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            button.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        return container
    }

    private func makeActionIconButton(
        systemName: String,
        accessibilityLabel: String,
        action: Selector
    ) -> NSButton {
        let button = NSButton(frame: .zero)
        button.bezelStyle = .inline
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.image = NSImage(systemSymbolName: systemName, accessibilityDescription: accessibilityLabel)
        button.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        button.contentTintColor = .labelColor
        button.target = self
        button.action = action
        button.setAccessibilityLabel(accessibilityLabel)
        button.toolTip = accessibilityLabel
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }

    private func updateFloatButtonAppearance() {
        guard let floatButton else { return }
        let name = floatOnTop ? "pin.fill" : "pin"
        floatButton.image = NSImage(
            systemSymbolName: name,
            accessibilityDescription: "Float on Top"
        )
        floatButton.contentTintColor = floatOnTop ? .controlAccentColor : .labelColor
        floatButton.toolTip = floatOnTop ? "Don't Float on Top" : "Float on Top"
        floatButton.setAccessibilityLabel(floatButton.toolTip)
    }

    private func updateFrontmatterButtonAppearance() {
        guard let frontmatterToggleButton else { return }
        frontmatterToggleButton.contentTintColor = showFrontmatter ? .controlAccentColor : .labelColor
        let tip = showFrontmatter ? "Hide Frontmatter" : "Show Frontmatter"
        frontmatterToggleButton.toolTip = tip
        frontmatterToggleButton.setAccessibilityLabel(tip)
    }

    /// Full on-disk document (frontmatter + body), regardless of editor visibility.
    private var fullDocumentMarkdown: String {
        if showFrontmatter {
            return content.markdown
        }
        return NoteFrontmatter.joinDocument(prefix: frontmatterPrefix, body: content.markdown)
    }

    private func presentDocument(_ full: String) {
        let parts = NoteFrontmatter.splitDocument(full)
        frontmatterPrefix = parts.prefix
        draftText = full
        content.markdown = showFrontmatter ? full : parts.body
    }

    private func colorSwatchImage(_ color: NSColor, selected: Bool) -> NSImage {
        let size = NSSize(width: 16, height: 16)
        return NSImage(size: size, flipped: false) { rect in
            color.setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 3, yRadius: 3).fill()
            if selected {
                NSColor.labelColor.setStroke()
                let ring = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 3.5, yRadius: 3.5)
                ring.lineWidth = 1.5
                ring.stroke()
            } else {
                NSColor.separatorColor.setStroke()
                NSBezierPath(roundedRect: rect.insetBy(dx: 1.5, dy: 1.5), xRadius: 2.5, yRadius: 2.5).stroke()
            }
            return true
        }
    }

    private func syncColorMenu() {
        let selected = currentColor.selectedPreset
        for (preset, button) in colorSwatchButtons {
            button.image = colorSwatchImage(preset.nsColor, selected: preset == selected)
        }
        if case .custom = currentColor {
            colorPickerButton?.contentTintColor = .controlAccentColor
        } else {
            colorPickerButton?.contentTintColor = .labelColor
        }
        textSizeSlider?.doubleValue = textSize
        textSizeLabel?.stringValue = "\(Int(textSize.rounded()))"
        columnSlider?.doubleValue = Double(columnCount)
        columnLabel?.stringValue = "\(columnCount)"
        updateFloatButtonAppearance()
    }

    @objc private func toggleFloatOnTop(_ sender: Any?) {
        handleFloatChange(!floatOnTop)
        syncColorMenu()
        colorMenu?.cancelTracking()
    }

    @objc private func revealInFinder(_ sender: Any?) {
        colorMenu?.cancelTracking()
        NSWorkspace.shared.activateFileViewerSelecting([notePath])
    }

    @objc private func toggleFrontmatterPressed(_ sender: Any?) {
        let full = fullDocumentMarkdown
        showFrontmatter.toggle()
        suppressExternalReload = true
        presentDocument(full)
        suppressExternalReload = false
        updateFrontmatterButtonAppearance()
        // Keep menu open feel: rebuild isn't needed; just refresh tint next open.
    }

    @objc private func editTablePressed(_ sender: Any?) {
        colorMenu?.cancelTracking()
        sourceEditor.presentTableEditor()
    }

    @objc private func deleteNotePressed(_ sender: Any?) {
        colorMenu?.cancelTracking()
        confirmAndDeleteNote()
    }

    @objc private func convertHTMLToMarkdownPressed(_ sender: Any?) {
        colorMenu?.cancelTracking()
        openHTMLConvertWindow()
    }

    private func openHTMLConvertWindow() {
        saveNow()
        let full = fullDocumentMarkdown
        let parts = NoteFrontmatter.splitDocument(full)
        let source = parts.body.isEmpty && parts.prefix.isEmpty ? full : parts.body

        guard HTMLToMarkdown.looksLikeHTML(source) else {
            let alert = NSAlert()
            alert.messageText = "No HTML Found"
            alert.informativeText = "This note doesn’t look like it contains HTML tags to convert."
            alert.alertStyle = .informational
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }

        if let existing = htmlConvertWindow, existing.window?.isVisible == true {
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }

        let prefix = parts.prefix
        let controller = HTMLConvertWindowController(
            sourceHTML: source,
            noteURL: notePath,
            background: currentColor.nsColor,
            fontSize: textSize,
            onApply: { [weak self] markdown in
                self?.applyConvertedMarkdown(markdown, frontmatterPrefix: prefix)
            }
        )
        controller.onClose = { [weak self] in
            self?.htmlConvertWindow = nil
        }
        htmlConvertWindow = controller
        controller.window?.center()
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func applyConvertedMarkdown(_ markdown: String, frontmatterPrefix: String) {
        let newFull = frontmatterPrefix.isEmpty
            ? markdown
            : NoteFrontmatter.joinDocument(prefix: frontmatterPrefix, body: markdown)

        suppressExternalReload = true
        presentDocument(newFull)
        isDirty = true
        suppressExternalReload = false
        _ = saveNow()
    }

    private func confirmAndDeleteNote() {
        let alert = NSAlert()
        alert.messageText = "Delete “\(noteTitle)”?"
        alert.informativeText = "The note file will be moved to the Trash."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }
        manager?.deleteNote(path: notePath)
    }

    func show() {
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async { [weak self] in
            self?.content.focusEditor()
        }
    }

    /// Bring back a hibernated sticky without stealing key focus (set restore).
    func wake(makeKey: Bool) {
        if makeKey {
            panel.makeKeyAndOrderFront(nil)
            DispatchQueue.main.async { [weak self] in
                self?.content.focusEditor()
            }
        } else {
            panel.orderFront(nil)
        }
    }

    /// Hide for set-switch without destroying the editor (keeps TextKit/WebKit warm).
    func hibernate() {
        detachColorPanelIfNeeded()
        content.flushPendingPublish()
        if isDirty {
            saveNow()
        }
        panel.orderOut(nil)
    }

    func orderFront() {
        panel.orderFront(nil)
    }

    func orderOut() {
        panel.orderOut(nil)
    }

    var isVisible: Bool {
        panel.isVisible
    }

    /// True when `window` is this sticky’s panel.
    func owns(_ window: NSWindow) -> Bool {
        window === panel
    }

    var frame: CGRect {
        frameForPersistence
    }

    private var frameForPersistence: CGRect {
        if isCollapsed, let expandedFrame {
            return expandedFrame
        }
        return panel.frame
    }

    func closePreservingFile() {
        detachColorPanelIfNeeded()
        saveNow()
        manager?.writer?.editors.setUnsavedEdits(false, for: notePath)
        panel.delegate = nil
        panel.close()
    }

    /// Closes without saving (the note is being deleted).
    func closeDiscardingEdits() {
        detachColorPanelIfNeeded()
        isDiscarded = true
        saveTask?.cancel()
        pendingSave?.cancel()
        isDirty = false
        panel.delegate = nil
        panel.close()
    }

    private func toggleCollapsed() {
        if isCollapsed {
            expandFromTitlebar()
        } else {
            collapseToTitlebar()
        }
    }

    private func collapseToTitlebar() {
        guard !isCollapsed else { return }
        expandedFrame = panel.frame
        isCollapsed = true
        content.isHidden = true
        // Drop vertical body pins first — otherwise Auto Layout tries to grow the
        // window back to fit the editor and recurses through windowDidResize.
        bodyTopConstraint?.isActive = false
        bodyBottomConstraint?.isActive = false
        let frame = panel.frame
        let newHeight = collapsedHeight
        let newY = frame.origin.y + frame.height - newHeight
        panel.minSize = NSSize(width: normalMinSize.width, height: newHeight)
        applyPanelFrame(
            NSRect(x: frame.origin.x, y: newY, width: frame.width, height: newHeight),
            animate: true
        )
    }

    private func expandFromTitlebar() {
        guard isCollapsed, let expanded = expandedFrame else {
            isCollapsed = false
            bodyTopConstraint?.isActive = true
            bodyBottomConstraint?.isActive = true
            content.isHidden = false
            panel.minSize = normalMinSize
            return
        }
        isCollapsed = false
        bodyTopConstraint?.isActive = true
        bodyBottomConstraint?.isActive = true
        content.isHidden = false
        panel.minSize = normalMinSize
        // Keep current top-left; restore height/width from before collapse.
        let current = panel.frame
        let top = current.origin.y + current.height
        let restored = NSRect(
            x: current.origin.x,
            y: top - expanded.height,
            width: max(expanded.width, normalMinSize.width),
            height: max(expanded.height, normalMinSize.height)
        )
        expandedFrame = nil
        applyPanelFrame(restored, animate: true)
        manager?.stickyFrameChanged(path: notePath, frame: restored)
    }

    private func applyPanelFrame(_ frame: NSRect, animate: Bool) {
        isApplyingPanelFrame = true
        defer { isApplyingPanelFrame = false }
        panel.setFrame(frame, display: true, animate: animate)
    }

    /// The file changed on disk. A clean editor reloads; one with unsaved edits keeps them, and
    /// its next save notices the change and writes a conflict copy instead of overwriting.
    func applyExternalContent(_ text: String, hash: String) {
        guard !isDirty, !content.hasUnpublishedEdits else { return }
        suppressExternalReload = true
        presentDocument(text)
        suppressExternalReload = false
        loadedHash = hash
    }

    /// Soft refresh so newly synced images appear without changing text.
    func reloadInlineImages() {
        content.reloadPreviewMedia()
    }

    private func markTypingActivity() {
        guard !suppressExternalReload, !isReadOnly else { return }
        isDirty = true
        scheduleSave()
    }

    private func handleTextChange(_ text: String) {
        guard !suppressExternalReload, !isReadOnly else { return }
        draftText = showFrontmatter ? text : NoteFrontmatter.joinDocument(prefix: frontmatterPrefix, body: text)
        isDirty = true
        scheduleSave()
    }

    private func handleRenameCommit(_ editedTitle: String) {
        let trimmed = editedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let effective = trimmed.isEmpty ? "Untitled" : trimmed
        guard let manager else {
            let display = NoteFilename.displayTitle(from: NoteFilename.slugify(effective))
            noteTitle = display
            titlebar.noteTitle = display
            return
        }
        if let result = manager.renameNote(path: notePath, toTitle: effective) {
            applyRenamedPath(result.path, displayTitle: result.displayTitle)
        } else {
            titlebar.noteTitle = noteTitle
        }
    }

    func applyRenamedPath(_ newPath: URL, displayTitle: String) {
        manager?.writer?.editors.setUnsavedEdits(false, for: notePath)
        notePath = newPath
        manager?.writer?.editors.setUnsavedEdits(isDirty, for: newPath)
        noteTitle = displayTitle
        titlebar.noteTitle = displayTitle
        content.updateNoteURL(newPath)
    }

    private func handleColorChange(_ color: NoteColor) {
        currentColor = color
        let ns = color.nsColor
        panel.backgroundColor = ns
        rootView.layer?.backgroundColor = ns.cgColor
        titlebar.applyBackground(ns)
        content.applyBackground(ns)
        manager?.noteColorChanged(path: notePath, color: color)
        syncColorMenu()
        writeColorToFrontmatter(color)
    }

    /// Color lives in the note's frontmatter (`stickies-color`) so it syncs. The default color
    /// removes the key. Saved like any edit (debounced).
    private func writeColorToFrontmatter(_ color: NoteColor) {
        guard !isReadOnly else { return }
        let full = fullDocumentMarkdown
        let updated = String(decoding: StickiesFrontmatter.settingColor(color.frontmatter, in: Data(full.utf8)), as: UTF8.self)
        guard updated != full else { return }
        suppressExternalReload = true
        if showFrontmatter {
            content.markdown = updated
        } else {
            frontmatterPrefix = NoteFrontmatter.splitDocument(updated).prefix
        }
        draftText = updated
        suppressExternalReload = false
        isDirty = true
        scheduleSave()
    }

    private func handleTextSizeChange(_ size: Double) {
        let clamped = min(NoteWindowState.maxTextSize, max(NoteWindowState.minTextSize, size))
        textSize = clamped
        textSizeLabel?.stringValue = "\(Int(clamped.rounded()))"
        content.applyFontSize(clamped)
        manager?.noteTextSizeChanged(path: notePath, size: clamped)
    }

    private func handleColumnCountChange(_ count: Int) {
        let clamped = NoteWindowState.clampedColumnCount(count)
        columnLabel?.stringValue = "\(clamped)"
        columnSlider?.doubleValue = Double(clamped)
        guard columnCount != clamped else { return }
        columnCount = clamped
        content.applyColumnCount(clamped)
        manager?.noteColumnCountChanged(path: notePath, count: clamped)
    }

    private func handleFloatChange(_ value: Bool) {
        floatOnTop = value
        panel.level = value ? .floating : .normal
        manager?.noteFloatChanged(path: notePath, floatOnTop: value)
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            saveNow()
        }
    }

    /// Saves through the shared writer, expecting the file to still be what this editor loaded.
    /// Returns the queued save so callers can wait for it.
    @discardableResult
    func saveNow() -> Task<Void, Never>? {
        content.flushPendingPublish()
        saveTask?.cancel()
        let full = fullDocumentMarkdown
        draftText = full
        guard isDirty, !isReadOnly, !isDiscarded else { return pendingSave }
        if showFrontmatter {
            frontmatterPrefix = NoteFrontmatter.splitDocument(full).prefix
        }
        saveGeneration += 1
        let generation = saveGeneration
        let previous = pendingSave
        let task = Task { @MainActor [weak self] in
            await previous?.value
            guard let self, generation == self.saveGeneration, !self.isDiscarded else { return }
            await self.performSave()
        }
        pendingSave = task
        return task
    }

    func saveAndWait() async {
        await saveNow()?.value
    }

    private func performSave() async {
        guard let writer = manager?.writer else { return }
        let text = fullDocumentMarkdown
        let data = Data(text.utf8)
        let expected = loadedHash
        let path = notePath
        guard NoteHashing.fileHash(data) != expected else {
            finishSave(savedText: text, hash: expected)
            return
        }
        // Mark before the write so FSEvents during IO are ignored.
        manager?.noteDidSave(path: path, modifiedAt: Date())
        let result = await Task.detached { () -> Result<String, Error> in
            Result { try writer.write(data, to: path, expect: .hash(expected), origin: .app) }
        }.value

        switch result {
        case .success(let hash):
            manager?.noteDidSave(path: path, modifiedAt: Date())
            finishSave(savedText: text, hash: hash)
        case .failure(NoteWriter.Failure.changedOnDisk), .failure(NoteWriter.Failure.missing):
            saveAsConflictCopy(data, originalPath: path)
        case .failure:
            isDirty = true   // try again on the next save
        }
    }

    private func finishSave(savedText: String, hash: String) {
        loadedHash = hash
        // More keystrokes landed while we wrote — save again.
        if content.hasUnpublishedEdits || fullDocumentMarkdown != savedText {
            isDirty = true
            scheduleSave()
        } else {
            isDirty = false
        }
    }

    /// The file changed underneath this editor (another app, or it was moved or trashed).
    /// Never overwrite: keep the buffer as a conflict copy next to the note, then show the file
    /// as it is now (or keep editing the copy if the original is gone).
    private func saveAsConflictCopy(_ data: Data, originalPath: URL) {
        guard let writer = manager?.writer else { return }
        let originalID = StickiesFrontmatter.id(in: data)
        var copy = StickiesFrontmatter.setting(StickiesFrontmatter.idKey, to: UUID().uuidString, in: data)
        if let originalID {
            copy = StickiesFrontmatter.setting(StickiesFrontmatter.conflictOfKey, to: originalID.uuidString, in: copy)
        }
        let name = ConflictCopy.filename(
            forOriginal: originalPath.lastPathComponent,
            deviceName: manager?.deviceName ?? "Mac",
            date: Date()
        )
        let directory = originalPath.deletingLastPathComponent()
        var copyURL = directory.appendingPathComponent(name)
        var index = 2
        while NoteWriter.existsIgnoringCase(copyURL) {
            let stem = (name as NSString).deletingPathExtension
            copyURL = directory.appendingPathComponent("\(stem) \(index).md")
            index += 1
        }
        do {
            let hash = try writer.write(copy, to: copyURL, expect: .absent, origin: .app)
            manager?.noteDidSave(path: copyURL, modifiedAt: Date())
            if let current = try? Data(contentsOf: originalPath) {
                isDirty = false
                applyExternalContent(String(decoding: current, as: UTF8.self), hash: NoteHashing.fileHash(current))
            } else {
                // The original is gone: keep editing the copy.
                notePath = copyURL
                content.updateNoteURL(copyURL)
                suppressExternalReload = true
                presentDocument(String(decoding: copy, as: UTF8.self))
                suppressExternalReload = false
                loadedHash = hash
                isDirty = false
            }
            let alert = NSAlert()
            alert.messageText = "Your Edits Were Saved as a Copy"
            alert.informativeText = "“\(noteTitle)” changed on disk while you were editing, so your version was saved as “\(copyURL.lastPathComponent)”."
            alert.addButton(withTitle: "OK")
            alert.runModal()
        } catch {
            isDirty = true
        }
    }

    func windowWillClose(_ notification: Notification) {
        detachColorPanelIfNeeded()
        saveNow()
        manager?.stickyWillClose(path: notePath, frame: frameForPersistence)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        titlebar.isActive = true
        manager?.stickyDidBecomeActive(path: notePath)
    }

    func windowDidResignKey(_ notification: Notification) {
        titlebar.isActive = false
        manager?.stickyDidResignActive(path: notePath)
    }

    func windowDidMove(_ notification: Notification) {
        if isCollapsed, let expanded = expandedFrame {
            let current = panel.frame
            let top = current.origin.y + current.height
            expandedFrame = NSRect(
                x: current.origin.x,
                y: top - expanded.height,
                width: current.width,
                height: expanded.height
            )
        }
        manager?.stickyFrameChanged(path: notePath, frame: frameForPersistence)
    }

    func windowDidResize(_ notification: Notification) {
        // Mid-animation / programmatic setFrame — do not re-enter.
        guard !isApplyingPanelFrame else { return }

        if isCollapsed {
            // Keep collapsed height locked if the user drags an edge.
            let frame = panel.frame
            if abs(frame.height - collapsedHeight) > 0.5 {
                let newY = frame.origin.y + frame.height - collapsedHeight
                applyPanelFrame(
                    NSRect(x: frame.origin.x, y: newY, width: frame.width, height: collapsedHeight),
                    animate: false
                )
            }
            if var expanded = expandedFrame {
                expanded.size.width = panel.frame.width
                expanded.origin.x = panel.frame.origin.x
                let top = panel.frame.origin.y + panel.frame.height
                expanded.origin.y = top - expanded.height
                expandedFrame = expanded
            }
            return
        }
        manager?.stickyFrameChanged(path: notePath, frame: panel.frame)
    }

    /// Title-bar double-click (zoom) → collapse / expand instead of fullscreen.
    func windowShouldZoom(_ window: NSWindow, toFrame newFrame: NSRect) -> Bool {
        toggleCollapsed()
        return false
    }

    /// Title-bar double-click (when system preference is minimize) → same collapse.
    func windowShouldMiniaturize(_ sender: NSWindow) -> Bool {
        toggleCollapsed()
        return false
    }
}
