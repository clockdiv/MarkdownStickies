import AppKit
import Foundation
import MarkdownStickiesCore

@MainActor
final class StickyWindowManager: ObservableObject {
    @Published private(set) var openPaths: Set<String> = []
    /// Path of the sticky that currently is the key window (if any).
    @Published private(set) var activePath: String?

    /// Runtime maps stay keyed by path (spec §2.3); saved state is keyed by `stickies-id`.
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

    var writer: NoteWriter? { noteStore?.writer }
    var deviceName: String { noteStore?.deviceName ?? "Mac" }

    func isOpen(_ path: URL) -> Bool {
        controllers[path.path] != nil
    }

    /// Ids of open stickies (for following moves after a sync).
    func openNoteIDs() -> [String: UUID] {
        var result: [String: UUID] = [:]
        for path in controllers.keys {
            if let id = noteStore?.idIndex.entry(for: URL(fileURLWithPath: path)).id { result[path] = id }
        }
        return result
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

        guard let prepared = prepareForOpening(note.path) else {
            let alert = NSAlert()
            alert.messageText = "Couldn’t Open “\(note.title)”"
            alert.informativeText = "The file can’t be read."
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }

        // Open stickies are remembered on the active set’s layout (not note ownership).
        let state = stateStore.state(for: note.path)
        let controller = StickyWindowController(
            note: note,
            content: prepared.text,
            loadedHash: prepared.hash,
            isReadOnly: prepared.notice != nil,
            color: prepared.color,
            state: state,
            manager: self
        )
        controllers[note.path.path] = controller
        openPaths.insert(note.path.path)
        stateStore.setOpen(note.path, isOpen: true)
        stateStore.touchLastOpened(note.path)
        noteStore?.noteColorChanged(path: note.path, color: prepared.color)
        if makeKey {
            controller.show()
        } else {
            controller.wake(makeKey: false)
        }
        noteStore?.noteDidOpen(path: note.path)

        if let notice = prepared.notice {
            let alert = NSAlert()
            alert.messageText = "“\(note.title)” Opens Read-Only"
            alert.informativeText = notice
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    private struct Prepared {
        var text: String
        var hash: String
        var color: NoteColor
        /// Set when the note opens read-only.
        var notice: String?
    }

    /// Opening "touches" the note (spec §2.2): adds `stickies-id` once, and `stickies-color` if
    /// missing (the color from before it moved into notes, otherwise yellow). The frontmatter is
    /// the only place a color is kept. Never writes anything else; a file that can't be read as
    /// UTF-8 or can't be written opens read-only instead.
    private func prepareForOpening(_ path: URL) -> Prepared? {
        guard let data = try? Data(contentsOf: path) else { return nil }
        let hash = NoteHashing.fileHash(data)
        let legacy = stateStore.storedState(for: path)?.legacyColor
        guard let text = String(data: data, encoding: .utf8) else {
            return Prepared(
                text: String(decoding: data, as: UTF8.self),
                hash: hash,
                color: legacy ?? .default,
                notice: "This file isn’t UTF-8 text. It’s shown read-only and doesn’t sync."
            )
        }

        var updated = StickiesFrontmatter.ensuringID(in: data).data
        let color: NoteColor
        if let fileColor = StickiesFrontmatter.color(in: updated) {
            color = NoteColor(frontmatter: fileColor)
        } else {
            color = legacy ?? .default
            if StickiesFrontmatter.value(for: StickiesFrontmatter.colorKey, in: updated) == nil {
                updated = StickiesFrontmatter.settingColor(color.frontmatter, in: updated)
            }
        }
        guard updated != data else {
            stateStore.clearLegacyColor(path)
            return Prepared(text: text, hash: hash, color: color)
        }

        do {
            let newHash = try writer?.write(updated, to: path, expect: .hash(hash), origin: .app) ?? hash
            noteStore?.idIndex.invalidate(path)
            noteStore?.noteFileDidSave(path: path, modifiedAt: Date())
            stateStore.migrateLegacyKeys(for: [path])
            stateStore.clearLegacyColor(path)
            return Prepared(text: String(decoding: updated, as: UTF8.self), hash: newHash, color: color)
        } catch {
            return Prepared(
                text: text,
                hash: hash,
                color: color,
                notice: "Markdown Stickies can’t write to this file. It’s shown read-only and doesn’t sync."
            )
        }
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

    /// Saves every open sticky and waits until the files are written (before a sync).
    func saveAllOpenAndWait() async {
        for controller in Array(controllers.values) {
            await controller.saveAndWait()
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
        stateStore.replaceOpenPaths(paths.map { URL(fileURLWithPath: $0) }, inSet: setIndex)

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
        // Saved layouts hold keys (`id:<uuid>` or a legacy path).
        var byKey: [String: Note] = [:]
        for note in notes {
            byKey[note.path.path] = note
            byKey[stateStore.key(for: note.path)] = note
        }
        let setIndex = stateStore.activeSet
        let planned = stateStore.openPaths(inSet: setIndex).compactMap { byKey[$0] }
        var bag = parkedBySet.removeValue(forKey: setIndex) ?? [:]
        var kept: [URL] = []

        for (index, note) in planned.enumerated() {
            let pathString = note.path.path
            let isLast = index == planned.count - 1
            if let hibernated = bag.removeValue(forKey: pathString) {
                controllers[pathString] = hibernated
                openPaths.insert(pathString)
                hibernated.wake(makeKey: isLast)
            } else {
                open(note: note, makeKey: isLast)
            }
            kept.append(note.path)
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

    /// A note moved (sync or Finder): the open sticky follows it instead of closing.
    func noteMoved(from oldPath: URL, to newPath: URL, title: String) {
        guard let controller = controllers.removeValue(forKey: oldPath.path) else { return }
        controllers[newPath.path] = controller
        openPaths.remove(oldPath.path)
        openPaths.insert(newPath.path)
        if activePath == oldPath.path { activePath = newPath.path }
        controller.applyRenamedPath(newPath, displayTitle: title)
    }

    /// The file changed on disk: a clean sticky reloads; one with unsaved edits keeps them
    /// (its next save notices the change and writes a conflict copy).
    func reloadIfOpen(note: Note, content: String, hash: String) {
        controllers[note.path.path]?.applyExternalContent(content, hash: hash)
    }

    /// Refresh inline images (e.g. after a sync brought new ones).
    func reloadInlineImages() {
        for controller in controllers.values {
            controller.reloadInlineImages()
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
        noteStore?.noteColorChanged(path: path, color: color)
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
        noteStore?.idIndex.invalidate(path)
        noteStore?.noteFileDidSave(path: path, modifiedAt: modifiedAt)
    }

    /// Renames the on-disk `.md` file (slugified). Preserves date prefix when present.
    @discardableResult
    func renameNote(path: URL, toTitle title: String) -> (path: URL, displayTitle: String)? {
        guard let controller = controllers[path.path] else { return nil }
        controller.saveNow()

        let slug = NoteFilename.slugify(title)
        let displayTitle = NoteFilename.displayTitle(from: slug)
        let newURL = NoteFilename.uniqueRenamedURL(from: path, newTitle: title)

        if newURL.standardizedFileURL == path.standardizedFileURL {
            controller.applyRenamedPath(path, displayTitle: displayTitle)
            noteStore?.noteDidRename(from: path, to: path, displayTitle: displayTitle)
            return (path, displayTitle)
        }

        do {
            guard let hash = NoteWriter.currentHash(of: path) else { return nil }
            try writer?.move(from: path, to: newURL, expectHash: hash, origin: .app)
            noteStore?.noteFileDidSave(path: newURL, modifiedAt: Date())
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

    /// Moves the note to the macOS Trash, closes the sticky, refreshes the list.
    func deleteNote(path: URL) {
        if let controller = controllers[path.path] {
            controller.closeDiscardingEdits()
            controllers.removeValue(forKey: path.path)
            openPaths.remove(path.path)
        }
        do {
            guard let hash = NoteWriter.currentHash(of: path) else { throw NoteWriter.Failure.missing }
            try writer?.trash(path, expectHash: hash, origin: .app)
            stateStore.setOpen(path, isOpen: false)
            noteStore?.noteWasDeleted(path: path)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn’t Move the Note to the Trash"
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }
}
