import AppKit
import Foundation

@MainActor
final class StickyWindowManager: ObservableObject {
    @Published private(set) var openPaths: Set<String> = []
    /// Path of the sticky that currently is the key window (if any).
    @Published private(set) var activePath: String?

    private var controllers: [String: StickyWindowController] = [:]
    private let stateStore: NoteStateStore
    private weak var noteStore: NoteStore?

    init(stateStore: NoteStateStore) {
        self.stateStore = stateStore
    }

    func attach(noteStore: NoteStore) {
        self.noteStore = noteStore
    }

    func isOpen(_ path: URL) -> Bool {
        controllers[path.path] != nil
    }

    func open(note: Note) {
        if let existing = controllers[note.path.path] {
            // Already open — focus only; don't bump list order.
            existing.show()
            return
        }

        let content: String
        do {
            content = try String(contentsOf: note.path, encoding: .utf8)
        } catch {
            content = ""
        }

        let state = stateStore.state(for: note.path)
        let controller = StickyWindowController(
            note: note,
            content: content,
            state: state,
            manager: self
        )
        controllers[note.path.path] = controller
        openPaths.insert(note.path.path)
        stateStore.setOpen(note.path, isOpen: true)
        stateStore.touchLastOpened(note.path)
        controller.show()
        noteStore?.noteDidOpen(path: note.path)
    }

    func close(path: URL) {
        guard let controller = controllers[path.path] else { return }
        controller.closePreservingFile()
        controllers.removeValue(forKey: path.path)
        openPaths.remove(path.path)
        stateStore.setOpen(path, isOpen: false)
        stateStore.setFrame(path, frame: controller.frame)
    }

    /// Closes the key sticky note window. Returns `true` if a sticky was closed.
    @discardableResult
    func closeFocusedSticky() -> Bool {
        guard let key = NSApp.keyWindow else { return false }
        guard let entry = controllers.first(where: { $0.value.owns(key) }) else { return false }
        close(path: URL(fileURLWithPath: entry.key))
        return true
    }

    func closeAll() {
        for path in Array(controllers.keys) {
            close(path: URL(fileURLWithPath: path))
        }
    }

    func showAll() {
        for controller in controllers.values {
            controller.show()
        }
    }

    func hideAll() {
        for controller in controllers.values {
            controller.orderOut()
        }
    }

    func saveAllOpen() {
        for controller in controllers.values {
            controller.saveNow()
        }
    }

    func restoreOpenNotes(from notes: [Note]) {
        let byPath = Dictionary(notes.map { ($0.path.path, $0) }, uniquingKeysWith: { _, new in new })
        for pathString in stateStore.openPaths() {
            if let note = byPath[pathString] {
                open(note: note)
            } else {
                stateStore.setOpen(URL(fileURLWithPath: pathString), isOpen: false)
            }
        }
    }

    func handleNoteRemoved(path: URL) {
        if controllers[path.path] != nil {
            close(path: path)
        }
        stateStore.remove(path: path)
    }

    func reloadIfOpen(note: Note, content: String) {
        controllers[note.path.path]?.applyExternalContent(content)
    }

    func stickyWillClose(path: URL, frame: CGRect) {
        controllers.removeValue(forKey: path.path)
        openPaths.remove(path.path)
        if activePath == path.path {
            activePath = nil
        }
        stateStore.setOpen(path, isOpen: false)
        stateStore.setFrame(path, frame: frame)
    }

    func stickyDidBecomeActive(path: URL) {
        activePath = path.path
    }

    func stickyDidResignActive(path: URL) {
        if activePath == path.path {
            activePath = nil
        }
    }

    func stickyFrameChanged(path: URL, frame: CGRect) {
        stateStore.setFrame(path, frame: frame)
    }

    func noteColorChanged(path: URL, color: NoteColor) {
        stateStore.setColor(path, color: color)
    }

    func noteTextSizeChanged(path: URL, size: Double) {
        stateStore.setTextSize(path, size: size)
    }

    func noteColumnCountChanged(path: URL, count: Int) {
        stateStore.setColumnCount(path, count: count)
    }

    func noteFloatChanged(path: URL, floatOnTop: Bool) {
        stateStore.setFloatOnTop(path, value: floatOnTop)
    }

    func noteDidSave(path: URL, modifiedAt: Date) {
        noteStore?.noteFileDidSave(path: path, modifiedAt: modifiedAt)
    }

    /// Renames the on-disk `.md` file (slugified). Preserves date prefix when present.
    @discardableResult
    func renameNote(path: URL, toTitle title: String) -> (path: URL, displayTitle: String)? {
        guard let controller = controllers[path.path] else { return nil }
        controller.saveNow()

        let newURL = NoteFilename.uniqueRenamedURL(from: path, newTitle: title)
        let slug = NoteFilename.slugify(title)
        let displayTitle = NoteFilename.displayTitle(from: slug)

        if newURL.standardizedFileURL == path.standardizedFileURL {
            controller.applyRenamedPath(path, displayTitle: displayTitle)
            noteStore?.noteDidRename(from: path, to: path, displayTitle: displayTitle)
            return (path, displayTitle)
        }

        do {
            try FileManager.default.moveItem(at: path, to: newURL)
        } catch {
            return nil
        }

        // Remap before any FSEvents rescan sees the old path as deleted.
        controllers.removeValue(forKey: path.path)
        controllers[newURL.path] = controller
        openPaths.remove(path.path)
        openPaths.insert(newURL.path)
        stateStore.relocate(from: path, to: newURL)
        stateStore.setOpen(newURL, isOpen: true)

        controller.applyRenamedPath(newURL, displayTitle: displayTitle)
        noteStore?.noteDidRename(from: path, to: newURL, displayTitle: displayTitle)
        return (newURL, displayTitle)
    }

    /// Moves the note file to Trash, closes the sticky, and refreshes the note list.
    func deleteNote(path: URL) {
        if let controller = controllers[path.path] {
            controller.saveNow()
            controller.closePreservingFile()
            controllers.removeValue(forKey: path.path)
            openPaths.remove(path.path)
        }
        do {
            try FileManager.default.trashItem(at: path, resultingItemURL: nil)
        } catch {
            // Fallback: permanent delete if Trash fails.
            try? FileManager.default.removeItem(at: path)
        }
        stateStore.remove(path: path)
        noteStore?.noteWasDeleted(path: path)
    }
}
