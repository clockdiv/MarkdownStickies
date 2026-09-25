import AppKit

/// Custom sticky title bar: centered title, hover-close, menu chevron, drag + double-click.
final class StickyTitlebarView: NSView, NSTextFieldDelegate {
    var onDoubleClick: (() -> Void)?
    var onMenuButton: ((NSButton) -> Void)?
    var onClose: (() -> Void)?
    /// Called with the edited display title when the user commits a rename.
    var onRenameCommit: ((String) -> Void)?

    private let titleLabel = NSTextField(labelWithString: "")
    private let titleField = NSTextField(string: "")
    private let closeButton = NSButton(frame: .zero)
    private let menuButton = NSButton(frame: .zero)
    private var tracking: NSTrackingArea?
    private var isRenaming = false
    private let dragThreshold: CGFloat = 4

    var noteTitle: String {
        get { titleLabel.stringValue }
        set {
            titleLabel.stringValue = newValue
            if !isRenaming {
                titleField.stringValue = newValue
            }
        }
    }

    /// Key / focused sticky → black title; inactive stickies stay secondary gray.
    var isActive: Bool = false {
        didSet {
            guard isActive != oldValue else { return }
            updateTitleColor()
        }
    }

    private func updateTitleColor() {
        titleLabel.textColor = isActive ? .labelColor : .secondaryLabelColor
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = NSColor.secondaryLabelColor
        titleLabel.alignment = .center
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        titleField.font = .systemFont(ofSize: 13, weight: .semibold)
        titleField.textColor = NSColor.labelColor
        titleField.alignment = .center
        titleField.isBordered = true
        titleField.isBezeled = true
        titleField.bezelStyle = .roundedBezel
        titleField.isEditable = true
        titleField.isSelectable = true
        titleField.focusRingType = .default
        titleField.delegate = self
        titleField.isHidden = true
        titleField.translatesAutoresizingMaskIntoConstraints = false
        titleField.cell?.sendsActionOnEndEditing = true
        titleField.target = self
        titleField.action = #selector(titleFieldAction(_:))

        configureIconButton(
            closeButton,
            systemName: "xmark.circle.fill",
            label: "Close",
            tint: .systemRed,
            action: #selector(closePressed)
        )
        closeButton.alphaValue = 0

        configureIconButton(
            menuButton,
            systemName: "chevron.down",
            label: "Note Options",
            tint: .secondaryLabelColor,
            action: #selector(menuPressed)
        )
        menuButton.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
        menuButton.sendAction(on: .leftMouseDown)

        addSubview(titleLabel)
        addSubview(titleField)
        addSubview(menuButton)
        addSubview(closeButton) // on top for hit-testing when visible

        NSLayoutConstraint.activate([
            closeButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 16),
            closeButton.heightAnchor.constraint(equalToConstant: 16),

            menuButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            menuButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            menuButton.widthAnchor.constraint(equalToConstant: 16),
            menuButton.heightAnchor.constraint(equalToConstant: 16),

            titleLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.leadingAnchor.constraint(greaterThanOrEqualTo: closeButton.trailingAnchor, constant: 8),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: menuButton.leadingAnchor, constant: -8),

            titleField.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleField.leadingAnchor.constraint(equalTo: closeButton.trailingAnchor, constant: 8),
            titleField.trailingAnchor.constraint(equalTo: menuButton.leadingAnchor, constant: -8),
            titleField.heightAnchor.constraint(equalToConstant: 22),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func applyBackground(_ color: NSColor) {
        layer?.backgroundColor = color.cgColor
    }

    func beginRenaming() {
        guard !isRenaming else { return }
        isRenaming = true
        titleField.stringValue = titleLabel.stringValue
        titleLabel.isHidden = true
        titleField.isHidden = false
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(titleField)
        titleField.currentEditor()?.selectAll(nil)
    }

    func cancelRenaming() {
        guard isRenaming else { return }
        finishRenaming(commit: false)
    }

    private func finishRenaming(commit: Bool) {
        guard isRenaming else { return }
        isRenaming = false
        let edited = titleField.stringValue
        titleField.isHidden = true
        titleLabel.isHidden = false
        window?.makeFirstResponder(nil)

        if commit {
            onRenameCommit?(edited)
        } else {
            titleField.stringValue = titleLabel.stringValue
        }
    }

    private func configureIconButton(
        _ button: NSButton,
        systemName: String,
        label: String,
        tint: NSColor,
        action: Selector
    ) {
        button.bezelStyle = .inline
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.image = NSImage(systemSymbolName: systemName, accessibilityDescription: label)
        button.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
        button.contentTintColor = tint
        button.target = self
        button.action = action
        button.setAccessibilityLabel(label)
        button.toolTip = label
        button.translatesAutoresizingMaskIntoConstraints = false
    }

    @objc private func closePressed() {
        if isRenaming {
            cancelRenaming()
        }
        onClose?()
    }

    @objc private func menuPressed() {
        if isRenaming {
            finishRenaming(commit: true)
        }
        onMenuButton?(menuButton)
    }

    @objc private func titleFieldAction(_ sender: Any?) {
        finishRenaming(commit: true)
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard isRenaming else { return }
        finishRenaming(commit: true)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            cancelRenaming()
            return true
        }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            finishRenaming(commit: true)
            return true
        }
        return false
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking {
            removeTrackingArea(tracking)
        }
        // Floating panels often aren't key — use activeAlways so hover still works.
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseEnteredAndExited, .mouseMoved, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        setCloseVisible(true)
    }

    override func mouseExited(with event: NSEvent) {
        setCloseVisible(false)
    }

    override func mouseMoved(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        setCloseVisible(bounds.contains(local))
    }

    private func setCloseVisible(_ visible: Bool) {
        let target: CGFloat = visible ? 1 : 0
        guard abs(closeButton.alphaValue - target) > 0.01 else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            closeButton.animator().alphaValue = target
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // When invisible, don't steal clicks meant for dragging — except keep menu clickable.
        let result = super.hitTest(point)
        if result === closeButton, closeButton.alphaValue < 0.5 {
            return self
        }
        return result
    }

    override func mouseDown(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        if closeButton.alphaValue > 0.5, closeButton.frame.insetBy(dx: -4, dy: -4).contains(local) {
            closePressed()
            return
        }
        if menuButton.frame.insetBy(dx: -4, dy: -4).contains(local) {
            menuPressed()
            return
        }
        if isRenaming {
            if titleField.frame.contains(local) {
                return
            }
            finishRenaming(commit: true)
            return
        }
        // Title press: wait for mouse-up to rename, or drag past threshold to move the note.
        if titleLabel.frame.insetBy(dx: -4, dy: -2).contains(local) {
            trackTitleClickOrDrag(with: event)
            return
        }
        if event.clickCount == 2 {
            onDoubleClick?()
            return
        }
        performWindowDrag(with: event)
    }

    /// Rename on mouse-up only when the pointer never crossed the drag threshold.
    private func trackTitleClickOrDrag(with downEvent: NSEvent) {
        guard let window else { return }
        let start = downEvent.locationInWindow

        while true {
            guard let next = window.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]) else { return }
            switch next.type {
            case .leftMouseDragged:
                let dx = next.locationInWindow.x - start.x
                let dy = next.locationInWindow.y - start.y
                if hypot(dx, dy) >= dragThreshold {
                    performWindowDrag(with: downEvent)
                    return
                }
            case .leftMouseUp:
                // Only a simple click (no drag) enters rename.
                if downEvent.clickCount == 1 {
                    beginRenaming()
                } else if downEvent.clickCount == 2 {
                    onDoubleClick?()
                }
                return
            default:
                continue
            }
        }
    }

    private func performWindowDrag(with event: NSEvent) {
        guard let window else { return }
        window.isMovableByWindowBackground = true
        window.performDrag(with: event)
        window.isMovableByWindowBackground = false
    }

    override var mouseDownCanMoveWindow: Bool { !isRenaming }
}
