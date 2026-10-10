import AppKit
import MarkdownStickiesCore

/// Separate floating sticky-styled window for list hover peeks.
/// Not a child of the control window — lives on its own window level.
@MainActor
enum NoteHoverPreviewPanel {
    private static var panel: HoverPreviewNSPanel?
    private static var titleLabel: NSTextField?
    private static var bodyView: NSTextView?
    private static var chrome: HoverPreviewRootView?
    private static var hideTask: Task<Void, Never>?
    private static var keyMonitor: Any?
    private static var isPointerInside = false

    static let previewSize = NSSize(width: 280, height: 220)
    /// Short intentional-hover delay before a peek appears.
    static let showDelayNanoseconds: UInt64 = 300_000_000
    /// Grace so the pointer can cross from the title into the preview.
    private static let hideGraceNanoseconds: UInt64 = 400_000_000

    static var isVisible: Bool {
        panel?.isVisible == true
    }

    static func show(title: String, body: String, color: NSColor) {
        cancelScheduledHide()
        let panel = ensurePanel()
        titleLabel?.stringValue = title
        if let bodyView {
            bodyView.string = body
            bodyView.scrollToBeginningOfDocument(nil)
        }
        chrome?.layer?.backgroundColor = color.cgColor

        let size = previewSize
        let origin = preferredOrigin(size: size)
        // Detach from any parent so we’re never clipped/hosted by the control window.
        if let parent = panel.parent {
            parent.removeChildWindow(panel)
        }
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.level = .popUpMenu
        panel.orderFrontRegardless()
        installKeyMonitorIfNeeded()
    }

    /// Immediate dismiss (Escape, open note, settings, etc.).
    static func hide() {
        cancelScheduledHide()
        isPointerInside = false
        removeKeyMonitor()
        panel?.orderOut(nil)
    }

    /// Hide shortly unless the pointer is (or becomes) over the preview.
    static func scheduleHide() {
        hideTask?.cancel()
        if isPointerInside { return }
        hideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: hideGraceNanoseconds)
            guard !Task.isCancelled, !isPointerInside else { return }
            hide()
        }
    }

    static func cancelScheduledHide() {
        hideTask?.cancel()
        hideTask = nil
    }

    nonisolated static func loadBody(from path: URL) -> String {
        guard let raw = try? String(contentsOf: path, encoding: .utf8) else {
            return "(Could not read note)"
        }
        let body = NoteFrontmatter.splitDocument(raw).body
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return "(Empty note)" }
        let maxChars = 1_400
        guard body.count > maxChars else { return body }
        let end = body.index(body.startIndex, offsetBy: maxChars)
        return String(body[..<end]).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }

    /// Classic tooltip placement: preview’s top-left sits a little right + below the cursor.
    private static func preferredOrigin(size: NSSize) -> NSPoint {
        let mouse = NSEvent.mouseLocation
        // Hotspot offset — enough to clear the pointer tip without feeling detached.
        let offsetX: CGFloat = 14
        let offsetY: CGFloat = 18

        // AppKit origin is bottom-left; top-left of panel ≈ (mouse.x + offsetX, mouse.y - offsetY).
        var origin = NSPoint(
            x: mouse.x + offsetX,
            y: mouse.y - offsetY - size.height
        )

        let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) })
            ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            let margin: CGFloat = 6
            // Flip to the left of the cursor when the right side would clip.
            if origin.x + size.width > visible.maxX - margin {
                origin.x = mouse.x - offsetX - size.width
            }
            // If still clipped vertically below, lift so the top sits above the cursor instead.
            if origin.y < visible.minY + margin {
                origin.y = mouse.y + offsetY
            }
            origin.x = min(max(visible.minX + margin, origin.x), visible.maxX - size.width - margin)
            origin.y = min(max(visible.minY + margin, origin.y), visible.maxY - size.height - margin)
        }
        return origin
    }

    private static func pointerHoverChanged(_ inside: Bool) {
        isPointerInside = inside
        if inside {
            cancelScheduledHide()
        } else {
            scheduleHide()
        }
    }

    private static func installKeyMonitorIfNeeded() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Escape
            guard event.keyCode == 53 else { return event }
            if Thread.isMainThread {
                return MainActor.assumeIsolated {
                    guard isVisible else { return event }
                    hide()
                    return nil
                }
            }
            return DispatchQueue.main.sync {
                MainActor.assumeIsolated {
                    guard isVisible else { return event }
                    hide()
                    return nil
                }
            }
        }
    }

    private static func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }

    private static func ensurePanel() -> HoverPreviewNSPanel {
        if let panel { return panel }

        let panel = HoverPreviewNSPanel(
            contentRect: NSRect(origin: .zero, size: previewSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = false
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        // Receive scroll / hover so the peek can be explored.
        panel.ignoresMouseEvents = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isMovable = false

        let root = HoverPreviewRootView(frame: NSRect(origin: .zero, size: previewSize))
        root.wantsLayer = true
        root.layer?.cornerRadius = 8
        root.layer?.masksToBounds = true
        root.layer?.backgroundColor = StickyColor.yellow.nsColor.cgColor
        // Soft edge so it reads as a real sticky window, not a card in the list.
        root.layer?.borderWidth = 0.5
        root.layer?.borderColor = NSColor.black.withAlphaComponent(0.12).cgColor
        root.onHoverChange = { inside in
            pointerHoverChanged(inside)
        }

        let title = NSTextField(labelWithString: "")
        title.translatesAutoresizingMaskIntoConstraints = false
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = NSColor(calibratedWhite: 0.12, alpha: 1)
        title.lineBreakMode = .byTruncatingTail
        title.maximumNumberOfLines = 1

        let scroll = NSScrollView(frame: .zero)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false

        let body = NSTextView(frame: .zero)
        body.isEditable = false
        body.isSelectable = false
        body.drawsBackground = false
        body.font = .systemFont(ofSize: 12, weight: .regular)
        body.textColor = NSColor(calibratedWhite: 0.22, alpha: 1)
        body.textContainerInset = NSSize(width: 0, height: 0)
        body.isVerticallyResizable = true
        body.isHorizontallyResizable = false
        body.textContainer?.widthTracksTextView = true
        body.textContainer?.lineFragmentPadding = 0
        scroll.documentView = body

        root.addSubview(title)
        root.addSubview(scroll)
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: root.topAnchor, constant: 10),
            title.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            title.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),

            scroll.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -10),
        ])

        panel.contentView = root
        self.panel = panel
        self.titleLabel = title
        self.bodyView = body
        self.chrome = root
        return panel
    }
}

/// Independent panel that never becomes key/main (control window keeps focus).
private final class HoverPreviewNSPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Tracks pointer enter/exit so the peek stays open while scrolling.
private final class HoverPreviewRootView: NSView {
    var onHoverChange: ((Bool) -> Void)?
    private var tracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [
                .activeAlways,
                .mouseEnteredAndExited,
                .inVisibleRect,
            ],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        onHoverChange?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHoverChange?(false)
    }
}
