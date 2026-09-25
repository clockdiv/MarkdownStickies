import AppKit
import SwiftUI

@MainActor
final class StickyWindowController: NSObject, NSWindowDelegate {
    private(set) var notePath: URL
    private let panel: StickyPanel
    private let rootView: NSView
    private let titlebar: StickyTitlebarView
    private let content: LivePreviewView
    private var colorMenu: NSMenu?
    private weak var manager: StickyWindowManager?

    private(set) var draftText: String
    private var isDirty = false
    private var saveTask: Task<Void, Never>?
    private var suppressExternalReload = false

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
    private var isCollapsed = false
    private var expandedFrame: NSRect?
    private let normalMinSize = NSSize(width: 180, height: 140)
    private let collapsedHeight: CGFloat = 28

    init(
        note: Note,
        content initialText: String,
        state: NoteWindowState,
        manager: StickyWindowManager
    ) {
        self.notePath = note.path
        self.manager = manager
        self.currentColor = state.color
        self.floatOnTop = state.floatOnTop
        self.noteTitle = note.title
        self.textSize = state.textSize
        self.columnCount = state.columnCount
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

        let body = LivePreviewView(
            noteURL: note.path,
            text: initialText,
            background: bg,
            fontSize: state.textSize,
            columnCount: state.columnCount
        )
        body.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(titlebar)
        root.addSubview(body)
        NSLayoutConstraint.activate([
            titlebar.topAnchor.constraint(equalTo: root.topAnchor),
            titlebar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            titlebar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            titlebar.heightAnchor.constraint(equalToConstant: collapsedHeight),

            body.topAnchor.constraint(equalTo: titlebar.bottomAnchor),
            body.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            body.bottomAnchor.constraint(equalTo: root.bottomAnchor),
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
        let deleteBtn = makeActionIconButton(
            systemName: "trash",
            accessibilityLabel: "Delete Note",
            action: #selector(deleteNotePressed(_:))
        )
        deleteBtn.contentTintColor = .systemRed

        stack.addArrangedSubview(floatBtn)
        stack.addArrangedSubview(finderBtn)
        stack.addArrangedSubview(deleteBtn)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 4),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -4),
            floatBtn.heightAnchor.constraint(equalToConstant: 28),
            finderBtn.heightAnchor.constraint(equalToConstant: 28),
            deleteBtn.heightAnchor.constraint(equalToConstant: 28),
        ])

        floatButton = floatBtn
        updateFloatButtonAppearance()
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
        // Keep menu open isn't needed; dismiss happens naturally for view buttons sometimes.
        colorMenu?.cancelTracking()
    }

    @objc private func revealInFinder(_ sender: Any?) {
        colorMenu?.cancelTracking()
        NSWorkspace.shared.activateFileViewerSelecting([notePath])
    }

    @objc private func deleteNotePressed(_ sender: Any?) {
        colorMenu?.cancelTracking()
        confirmAndDeleteNote()
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
        let frame = panel.frame
        let newHeight = collapsedHeight
        let newY = frame.origin.y + frame.height - newHeight
        panel.minSize = NSSize(width: normalMinSize.width, height: newHeight)
        panel.setFrame(
            NSRect(x: frame.origin.x, y: newY, width: frame.width, height: newHeight),
            display: true,
            animate: true
        )
        content.isHidden = true
    }

    private func expandFromTitlebar() {
        guard isCollapsed, let expanded = expandedFrame else {
            isCollapsed = false
            content.isHidden = false
            panel.minSize = normalMinSize
            return
        }
        isCollapsed = false
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
        panel.setFrame(restored, display: true, animate: true)
        manager?.stickyFrameChanged(path: notePath, frame: restored)
    }

    func applyExternalContent(_ text: String) {
        guard !isDirty else { return }
        suppressExternalReload = true
        draftText = text
        content.markdown = text
        suppressExternalReload = false
    }

    private func handleTextChange(_ text: String) {
        guard !suppressExternalReload else { return }
        draftText = text
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
        notePath = newPath
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
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            saveNow()
        }
    }

    @discardableResult
    func saveNow() -> Bool {
        saveTask?.cancel()
        draftText = content.markdown
        guard isDirty else { return true }
        do {
            try draftText.write(to: notePath, atomically: true, encoding: .utf8)
            isDirty = false
            let values = try notePath.resourceValues(forKeys: [.contentModificationDateKey])
            manager?.noteDidSave(path: notePath, modifiedAt: values.contentModificationDate ?? Date())
            return true
        } catch {
            return false
        }
    }

    func windowWillClose(_ notification: Notification) {
        detachColorPanelIfNeeded()
        isDirty = true
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
        if isCollapsed {
            // Keep collapsed height locked if the user drags an edge.
            let frame = panel.frame
            if abs(frame.height - collapsedHeight) > 0.5 {
                let newY = frame.origin.y + frame.height - collapsedHeight
                panel.setFrame(
                    NSRect(x: frame.origin.x, y: newY, width: frame.width, height: collapsedHeight),
                    display: true
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
