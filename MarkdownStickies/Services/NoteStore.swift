import AppKit
import Combine
import Foundation
import MarkdownStickiesCore
import SwiftUI

@MainActor
final class NoteStore: ObservableObject {
    @Published private(set) var notes: [Note] = []
    @Published var filterText: String = ""
    @Published var lastError: String?
    @Published var isScanning = false
    /// Temporary: fuzzy search cutoff (Settings slider). Higher = fewer / stricter hits.
    @Published var fuzzyMinimumScore: Double = Double(FuzzyMatch.defaultMinimumScore)
    /// Paths written from the peer on the last sync.
    @Published private(set) var syncInboundPaths: Set<String> = []
    /// Paths we sent that the peer would accept on the last sync.
    @Published private(set) var syncOutboundPaths: Set<String> = []

    let bookmarks: BookmarkStore
    let stateStore: NoteStateStore
    let windowManager: StickyWindowManager
    let syncService: LanSyncService

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
        let deviceName = Host.current().localizedName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let syncService = LanSyncService(
            deviceName: (deviceName?.isEmpty == false ? deviceName! : "Mac")
        )
        self.bookmarks = bookmarks
        self.stateStore = stateStore
        self.windowManager = windowManager
        self.syncService = syncService
        windowManager.attach(noteStore: self)
        configureSync()

        bookmarks.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
                self?.refreshSyncAdvertising()
            }
            .store(in: &cancellables)

        windowManager.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        syncService.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
    }

    func start() {
        rescan(restoreWindows: true)
        restartWatcher()
        refreshSyncAdvertising()
    }

    private func configureSync() {
        syncService.catalogProvider = { [weak self] in
            guard let self else { return [] }
            return SyncCatalogBuilder.catalog(roots: self.bookmarks.syncedURLs())
        }
        syncService.onInboundCatalog = { [weak self] remote in
            self?.applyRemoteCatalog(remote)
        }
    }

    private func refreshSyncAdvertising() {
        if bookmarks.syncedURLs().isEmpty {
            syncService.stopAdvertising()
        } else {
            syncService.startAdvertising()
            syncService.requestLocalNetworkAuthorization()
        }
    }

    func setFolderSynced(_ root: ScanRoot, enabled: Bool) {
        bookmarks.setSynced(root, enabled: enabled)
        refreshSyncAdvertising()
    }

    func syncNow() async {
        let roots = bookmarks.syncedURLs()
        guard !roots.isEmpty else {
            lastError = "Enable Sync on a scan folder in Settings first."
            return
        }
        windowManager.saveAllOpen()
        lastError = nil
        do {
            let remote = try await syncService.syncWithPeer()
            applyRemoteCatalog(remote)
        } catch {
            lastError = LanSyncService.friendlyNetworkError(error)
        }
    }

    /// User opened/focused a note — drop the “received” badge (they’ve seen it).
    func acknowledgeInbound(for path: URL) {
        let key = path.standardizedFileURL.path
        guard syncInboundPaths.contains(key) else { return }
        syncInboundPaths.remove(key)
    }

    func openNote(_ note: Note) {
        acknowledgeInbound(for: note.path)
        windowManager.open(note: note)
    }

    /// Called when a sticky is opened (or re-focused) — bumps list order.
    func noteDidOpen(path: URL) {
        acknowledgeInbound(for: path)
        sortNotes()
    }

    private func applyRemoteCatalog(_ remote: [SyncNotePayload]) {
        let roots = bookmarks.syncedURLs()
        guard !roots.isEmpty else {
            lastError = "No synced folder to receive notes."
            return
        }
        // Prefer the marked Default folder when it is synced; else first synced root.
        let createDir: URL = {
            if let preferred = preferredCreateDirectory(),
               roots.contains(where: { $0.standardizedFileURL == preferred.standardizedFileURL }) {
                return preferred
            }
            return roots[0]
        }()
        do {
            let local = SyncCatalogBuilder.catalog(roots: roots)
            let outboundIDs = SyncMerge.outboundIDs(ours: local, theirs: remote)
            let localPaths = SyncCatalogBuilder.pathIndex(roots: roots)

            let result = try SyncCatalogBuilder.applyRemoteCatalog(
                remote,
                roots: roots,
                createDirectory: createDir
            )
            // Surface received notes at the top of the list (sort uses lastOpenedAt + inbound).
            let receivedAt = Date()
            for path in result.appliedPaths {
                stateStore.touchLastOpened(path, at: receivedAt)
            }
            syncInboundPaths = Set(result.appliedPaths.map { $0.standardizedFileURL.path })
            syncOutboundPaths = Set(outboundIDs.compactMap { localPaths[$0]?.standardizedFileURL.path })
            rescan(restoreWindows: false)
            syncService.setStatus(
                "In \(result.count) · out \(outboundIDs.count) → \(createDir.lastPathComponent)"
            )
        } catch {
            lastError = "Could not apply sync: \(error.localizedDescription)"
        }
    }

    func addScanFolder() {
        if bookmarks.addFolder() {
            rescan(restoreWindows: false)
            restartWatcher()
        }
    }

    func removeScanFolder(_ root: ScanRoot) {
        if isDefaultCreateDirectory(root.path) {
            UserDefaults.standard.removeObject(forKey: Self.defaultCreateDirectoryKey)
        }
        bookmarks.remove(root)
        rescan(restoreWindows: false)
        restartWatcher()
    }

    func rescan(restoreWindows: Bool = false) {
        isScanning = true
        lastError = nil
        let roots = bookmarks.effectiveScanURLs()
        let scanned = NoteScanner.scan(roots: roots)
            .filter { !NoteFrontmatter.isTrashed(file: $0.path) }
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
                    let ensured = NoteFrontmatter.ensuringSyncID(content)
                    if ensured.didChange {
                        let previous = note.modifiedAt
                        try? ensured.markdown.write(to: note.path, atomically: true, encoding: .utf8)
                        try? FileManager.default.setAttributes(
                            [.modificationDate: previous],
                            ofItemAtPath: note.path.path
                        )
                    }
                    windowManager.reloadIfOpen(note: note, content: ensured.markdown)
                }
            }
        }

        isScanning = false

        if restoreWindows || !didRestoreWindows {
            windowManager.restoreOpenNotes(from: scanned)
            didRestoreWindows = true
        }
    }

    func createNote(title: String, in directory: URL) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveTitle = trimmed.isEmpty ? "Untitled" : trimmed
        let url = NoteFilename.uniqueURL(in: directory, date: Date(), title: effectiveTitle)
        let initial = NoteFrontmatter.initialDocument(
            title: effectiveTitle,
            createdOn: syncService.deviceName
        )
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
        alert.layout()
        alert.window.initialFirstResponder = input
        input.selectText(nil)

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        createNote(title: input.stringValue, in: directory)
    }

    /// Explicit default scan root from Settings; else Desktop when scanned; else first root.
    func preferredCreateDirectory() -> URL? {
        let roots = bookmarks.effectiveScanURLs()
        guard !roots.isEmpty else { return nil }

        if let match = defaultCreateDirectory(),
           roots.contains(where: { $0.standardizedFileURL == match.standardizedFileURL }) {
            return match
        }

        let desktop = BookmarkStore.desktopURL.standardizedFileURL
        if let match = roots.first(where: { $0.standardizedFileURL == desktop }) {
            return match
        }
        return roots.first
    }

    /// Marked default create folder, if still present in scan roots.
    func defaultCreateDirectory() -> URL? {
        guard let stored = UserDefaults.standard.string(forKey: Self.defaultCreateDirectoryKey) else {
            return nil
        }
        let url = URL(fileURLWithPath: stored).standardizedFileURL
        let roots = bookmarks.effectiveScanURLs()
        return roots.first(where: { $0.standardizedFileURL == url })
    }

    func isDefaultCreateDirectory(_ url: URL) -> Bool {
        defaultCreateDirectory()?.standardizedFileURL == url.standardizedFileURL
    }

    func setDefaultCreateDirectory(_ url: URL) {
        UserDefaults.standard.set(url.standardizedFileURL.path, forKey: Self.defaultCreateDirectoryKey)
        objectWillChange.send()
    }

    /// Same UserDefaults key as before so an existing preference becomes the default.
    private static let defaultCreateDirectoryKey = "preferredCreateDirectoryPath"

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
    /// Just-received sync inbound notes are also opened-touched so they float to the top.
    private func sortNotes() {
        notes.sort { lhs, rhs in
            let leftInbound = syncInboundPaths.contains(lhs.path.standardizedFileURL.path)
            let rightInbound = syncInboundPaths.contains(rhs.path.standardizedFileURL.path)
            if leftInbound != rightInbound { return leftInbound && !rightInbound }

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
