import AppKit

/// Shared surface for the sticky note body editor.
@MainActor
protocol StickyNoteEditorBody: AnyObject {
    var onTextChange: ((String) -> Void)? { get set }
    var onTypingActivity: (() -> Void)? { get set }
    var onRequestImmediateSave: (() -> Void)? { get set }

    var markdown: String { get set }
    var hasUnpublishedEdits: Bool { get }

    func updateNoteURL(_ url: URL)
    func reloadInlineImages()
    func applyBackground(_ color: NSColor)
    func applyFontSize(_ size: Double)
    func applyColumnCount(_ count: Int)
    func focusEditor()
    func flushPendingPublish()
}
