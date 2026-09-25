import AppKit
import Combine
import Foundation
import SwiftUI

@MainActor
final class NoteStore: ObservableObject {
    @Published private(set) var notes: [Note] = []
    @Published var filterText: String = ""
    @Published var lastError: String?
    @Published var isScanning = false
    /// Temporary: fuzzy search cutoff (Settings slider). Higher = fewer / stricter hits.
    @Published var fuzzyMinimumScore: Double = Double(FuzzyMatch.defaultMinimumScore)

    let bookmarks: BookmarkStore
    let stateStore: NoteStateStore
    let windowManager: StickyWindowManager

    private let watcher = FolderWatcher()
    private var rescanTask: Task<Void, Never>?
    private var didRestoreWindows = false
    private var cancellables = Set<AnyCancellable>()

    /// Filtered notes when searching; otherwise the full note list.
    var filteredNotes: [Note] {
        let query = filterText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return notes }
        let roots = bookmarks.effectiveScanURLs()
        let minimumScore = Int(fuzzyMinimumScore.rounded())
        return notes
            .compactMap { note -> (Note, Int)? in
                let location = Note.locationLabel(for: note.path, scanRoots: roots)
                let score = FuzzyMatch.bestScore(
                    query: query,
                    in: [
                        (note.title, 3),
                        (location, 2),
                        (note.path.path, 1),
                    ],
                    minimumScore: minimumScore
                )
                guard let score else { return nil }
                return (note, score)
            }
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
                return lhs.0.title.localizedCaseInsensitiveCompare(rhs.0.title) == .orderedAscending
            }
            .map(\.0)
    }

    init() {
        let bookmarks = BookmarkStore()
        let stateStore = NoteStateStore()
        let windowManager = StickyWindowManager(stateStore: stateStore)
        self.bookmarks = bookmarks
        self.stateStore = stateStore
        self.windowManager = windowManager
        windowManager.attach(noteStore: self)

        bookmarks.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        windowManager.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
    }

    func start() {
        rescan(restoreWindows: true)
        restartWatcher()
    }

    func addScanFolder() {
        if bookmarks.addFolder() {
            rescan(restoreWindows: false)
            restartWatcher()
        }
    }

    func removeScanFolder(_ root: ScanRoot) {
        bookmarks.remove(root)
        rescan(restoreWindows: false)
        restartWatcher()
    }

    func rescan(restoreWindows: Bool = false) {
        isScanning = true
        lastError = nil
        let roots = bookmarks.effectiveScanURLs()
        let scanned = NoteScanner.scan(roots: roots)
        let previous = Dictionary(notes.map { ($0.path.path, $0) }, uniquingKeysWith: { _, new in new })
        notes = scanned
        sortNotes()

        let newPaths = Set(scanned.map(\.path.path))
        for path in previous.keys where !newPaths.contains(path) {
            windowManager.handleNoteRemoved(path: URL(fileURLWithPath: path))
        }

        for note in scanned {
            if let old = previous[note.path.path],
               old.modifiedAt != note.modifiedAt,
               windowManager.isOpen(note.path) {
                if let content = try? String(contentsOf: note.path, encoding: .utf8) {
                    windowManager.reloadIfOpen(note: note, content: content)
                }
            }
        }

        isScanning = false

        if restoreWindows || !didRestoreWindows {
            windowManager.restoreOpenNotes(from: scanned)
            didRestoreWindows = true
        }
    }

    func openNote(_ note: Note) {
        windowManager.open(note: note)
    }

    /// Called when a sticky is opened (or re-focused) — bumps list order.
    func noteDidOpen(path: URL) {
        sortNotes()
    }

    func createNote(title: String, in directory: URL) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveTitle = trimmed.isEmpty ? "Untitled" : trimmed
        let url = NoteFilename.uniqueURL(in: directory, date: Date(), title: effectiveTitle)
        let initial = "# \(effectiveTitle)\n\n"
        do {
            try initial.write(to: url, atomically: true, encoding: .utf8)
            rescan(restoreWindows: false)
            let standardized = url.standardizedFileURL
            if let note = notes.first(where: { $0.path.standardizedFileURL == standardized })
                ?? NoteFilename.parse(url: standardized, modifiedAt: Date()) {
                windowManager.open(note: note)
            }
        } catch {
            lastError = "Could not create note: \(error.localizedDescription)"
        }
    }

    func promptCreateNote() {
        guard let directory = preferredCreateDirectory() else {
            let alert = NSAlert()
            alert.messageText = "No Scan Folder"
            alert.informativeText = "Add a folder under Settings before creating a note."
            alert.alertStyle = .informational
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }

        let folderName = directory.lastPathComponent
        let alert = NSAlert()
        alert.messageText = "New Note"
        alert.informativeText = "Saved to \(folderName)."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        input.stringValue = "Untitled"
        alert.accessoryView = input
        alert.window.initialFirstResponder = input

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        createNote(title: input.stringValue, in: directory)
        rememberCreateDirectory(directory)
    }

    /// Last-used scan root if still valid; else Desktop when scanned; else first scan root.
    func preferredCreateDirectory() -> URL? {
        let roots = bookmarks.effectiveScanURLs()
        guard !roots.isEmpty else { return nil }

        if let stored = UserDefaults.standard.string(forKey: Self.preferredCreateDirectoryKey) {
            let storedURL = URL(fileURLWithPath: stored).standardizedFileURL
            if let match = roots.first(where: { $0.standardizedFileURL == storedURL }) {
                return match
            }
        }

        let desktop = BookmarkStore.desktopURL.standardizedFileURL
        if let match = roots.first(where: { $0.standardizedFileURL == desktop }) {
            return match
        }
        return roots.first
    }

    private func rememberCreateDirectory(_ url: URL) {
        UserDefaults.standard.set(url.standardizedFileURL.path, forKey: Self.preferredCreateDirectoryKey)
    }

    private static let preferredCreateDirectoryKey = "preferredCreateDirectoryPath"

    func noteFileDidSave(path: URL, modifiedAt: Date) {
        if let index = notes.firstIndex(where: { $0.path.path == path.path }) {
            notes[index].modifiedAt = modifiedAt
            // Keep list order stable on save/close — order follows lastOpenedAt.
            sortNotes()
        }
    }

    func noteDidRename(from oldPath: URL, to newPath: URL, displayTitle: String) {
        if let index = notes.firstIndex(where: { $0.path.path == oldPath.path }) {
            let old = notes[index]
            let updated = Note(
                path: newPath,
                date: old.date,
                title: displayTitle,
                modifiedAt: old.modifiedAt
            )
            notes[index] = updated
            sortNotes()
        } else if oldPath.path == newPath.path,
                  let index = notes.firstIndex(where: { $0.path.path == newPath.path }) {
            let old = notes[index]
            notes[index] = Note(
                path: old.path,
                date: old.date,
                title: displayTitle,
                modifiedAt: old.modifiedAt
            )
        }
        // Watcher will rescan soon; this keeps the list correct immediately.
    }

    func noteWasDeleted(path: URL) {
        notes.removeAll { $0.path.path == path.path }
        rescan(restoreWindows: false)
    }

    func showAllStickies() {
        windowManager.showAll()
    }

    func hideAllStickies() {
        windowManager.hideAll()
    }

    func prepareToTerminate() {
        windowManager.saveAllOpen()
        stateStore.saveNow()
    }

    /// Recent opens first; never-opened notes fall back to file modification date.
    private func sortNotes() {
        notes.sort { lhs, rhs in
            let leftOpened = stateStore.storedState(for: lhs.path)?.lastOpenedAt
            let rightOpened = stateStore.storedState(for: rhs.path)?.lastOpenedAt
            switch (leftOpened, rightOpened) {
            case let (l?, r?):
                if l != r { return l > r }
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            case (nil, nil):
                break
            }
            if lhs.modifiedAt != rhs.modifiedAt {
                return lhs.modifiedAt > rhs.modifiedAt
            }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    }

    private func restartWatcher() {
        let roots = bookmarks.effectiveScanURLs()
        watcher.start(roots: roots) { [weak self] in
            Task { @MainActor in
                self?.scheduleRescanFromWatcher()
            }
        }
    }

    private func scheduleRescanFromWatcher() {
        rescanTask?.cancel()
        rescanTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            rescan(restoreWindows: false)
        }
    }
}
