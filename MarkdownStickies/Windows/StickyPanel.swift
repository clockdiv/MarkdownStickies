import AppKit

/// Borderless sticky panel that can become key (needed for typing).
final class StickyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
