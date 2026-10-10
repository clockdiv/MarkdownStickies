import AppKit
import Foundation
import MarkdownStickiesCore

@MainActor
final class StickyWindowManager: ObservableObject {
    @Published private(set) var openPaths: Set<String> = []
    /// Path of the sticky that currently is the key window (if any).
    @Published private(set) var activePath: String?

    private var controllers: [String: StickyWindowController] = [:]
    /// Hibernated stickies per set index — set switch reuses these instead of rebuilding editors.
    private var parkedBySet: [Int: [String: StickyWindowController]] = [:]
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

    func open(note: Note, makeKey: Bool = true) {
        if let existing = controllers[note.path.path] {
            // Already open — focus only; don't bump list order.
            if makeKey {
                existing.show()
            } else {
                existing.wake(makeKey: false)
            }
            return
        }

        let content: String
        do {
            let raw = try String(contentsOf: note.path, encoding: .utf8)
            let ensured = NoteFrontmatter.ensuringSyncID(raw)
            content = ensured.markdown
            if ensured.didChange {
                try? writePreservingModifiedDate(ensured.markdown, to: note.path)
            }
        } catch {
            content = NoteFrontmatter.initialDocument(
                title: note.title,
                createdOn: noteStore?.syncService.deviceName
            )
            try? content.write(to: note.path, atomically: true, encoding: .utf8)
        }

        // Open stickies are remembered on the active set’s layout (not note ownership).
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
        if makeKey {
            controller.show()
        } else {
            controller.wake(makeKey: false)
        }
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

    /// Hibernate every sticky but keep them listed as open for the current set.
    /// Controllers stay warm in `parkedBySet` so switching back is cheap.
    func parkAllForSetSwitch() {
        saveAllOpen()
        let setIndex = stateStore.activeSet
        let paths = Array(controllers.keys)
        for path in paths {
            if let controller = controllers[path] {
                stateStore.setFrame(URL(fileURLWithPath: path), frame: controller.frame)
            }
        }
        stateStore.replaceOpenPaths(paths, inSet: setIndex)

        var bag: [String: StickyWindowController] = [:]
        for path in paths {
            guard let controller = controllers.removeValue(forKey: path) else { continue }
            controller.hibernate()
            bag[path] = controller
        }
        // Drop any stale parked entries for this set that are no longer open.
        if let previous = parkedBySet[setIndex] {
            for (path, controller) in previous where bag[path] == nil {
                controller.closePreservingFile()
            }
        }
        parkedBySet[setIndex] = bag
        openPaths = []
        activePath = nil
    }

    /// Switch open-layout set (0…9): park current stickies, restore the target set.
    func switchToSet(_ index: Int) {
        let next = NoteWindowState.clampedSetIndex(index)
        guard next != stateStore.activeSet else { return }
        parkAllForSetSwitch()
        stateStore.setActiveSet(next)
        stateStore.saveNow()
        noteStore?.restoreActiveSetWindows()
    }

    func restoreOpenNotes(from notes: [Note]) {
        let byPath = Dictionary(notes.map { ($0.path.path, $0) }, uniquingKeysWith: { _, new in new })
        let setIndex = stateStore.activeSet
        let planned = stateStore.openPaths(inSet: setIndex).compactMap { path -> (String, Note)? in
            guard let note = byPath[path] else { return nil }
            return (path, note)
        }
        var bag = parkedBySet.removeValue(forKey: setIndex) ?? [:]
        var kept: [String] = []

        for (index, item) in planned.enumerated() {
            let pathString = item.0
            let note = item.1
            let isLast = index == planned.count - 1
            if let hibernated = bag.removeValue(forKey: pathString) {
                controllers[pathString] = hibernated
                openPaths.insert(pathString)
                hibernated.wake(makeKey: isLast)
                kept.append(pathString)
            } else {
                open(note: note, makeKey: isLast)
                kept.append(pathString)
            }
        }

        // Controllers parked for paths that are no longer in this set.
        for (_, leftover) in bag {
            leftover.closePreservingFile()
        }

        stateStore.replaceOpenPaths(kept, inSet: setIndex)
        if !kept.isEmpty {
            NSApp.activate(ignoringOtherApps: true)
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

    /// Merge authority: replace open editor even if dirty, and invalidate in-flight saves.
    func forceReloadIfOpen(note: Note, content: String) {
        controllers[note.path.path]?.forceApplyExternalContent(content)
    }

    /// Refresh open previews (e.g. after image assets sync).
    func reloadOpenPreviewMedia() {
        for controller in controllers.values {
            controller.reloadPreviewMedia()
        }
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
        noteStore?.noteDidOpen(path: path)
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
    /// Filename is the title source of truth — bumps mtime so LAN sync converges the name
    /// (identical-body + divergent titles already merge via `SyncMerge`).
    @discardableResult
    func renameNote(path: URL, toTitle title: String) -> (path: URL, displayTitle: String)? {
        guard let controller = controllers[path.path] else { return nil }
        controller.saveNow()

        let slug = NoteFilename.slugify(title)
        let displayTitle = NoteFilename.displayTitle(from: slug)

        let newURL = NoteFilename.uniqueRenamedURL(from: path, newTitle: title)

        if newURL.standardizedFileURL == path.standardizedFileURL {
            touchForSync(path)
            controller.applyRenamedPath(path, displayTitle: displayTitle)
            noteStore?.noteDidRename(from: path, to: path, displayTitle: displayTitle)
            return (path, displayTitle)
        }

        do {
            try FileManager.default.moveItem(at: path, to: newURL)
            touchForSync(newURL)
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

    /// Moves the note into the vault `Trash/` folder (synced), closes the sticky, refreshes the list.
    func deleteNote(path: URL) {
        if let controller = controllers[path.path] {
            controller.saveNow()
            controller.closePreservingFile()
            controllers.removeValue(forKey: path.path)
            openPaths.remove(path.path)
        }
        let roots = noteStore?.scanConfig.effectiveScanURLs() ?? []
        do {
            let trashed = try NoteFrontmatter.moveToTrash(file: path, roots: roots)
            stateStore.relocate(from: path, to: trashed)
            stateStore.setOpen(trashed, isOpen: false)
            noteStore?.noteWasDeleted(path: path)
        } catch {
            // Last resort: system Trash (won’t sync).
            try? FileManager.default.trashItem(at: path, resultingItemURL: nil)
            stateStore.remove(path: path)
            noteStore?.noteWasDeleted(path: path)
        }
    }

    /// Bump mtime so a rename wins the next LAN merge without rewriting the body.
    private func touchForSync(_ url: URL) {
        let now = Date()
        try? FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: url.path)
        noteStore?.noteFileDidSave(path: url, modifiedAt: now)
    }

    /// Stamp missing sync id without making the note look newly edited.
    private func writePreservingModifiedDate(_ text: String, to url: URL) throws {
        let previous = try url.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate
        try text.write(to: url, atomically: true, encoding: .utf8)
        if let previous {
            try FileManager.default.setAttributes(
                [.modificationDate: previous],
                ofItemAtPath: url.path
            )
        }
    }
}
