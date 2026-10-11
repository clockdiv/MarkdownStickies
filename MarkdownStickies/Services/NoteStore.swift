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

    let scanConfig: ScanConfigStore
    let stateStore: NoteStateStore
    let windowManager: StickyWindowManager
    /// Every note write on this Mac goes through this writer (editor saves, app actions, sync).
    let writer: NoteWriter
    /// `stickies-id` and color per file, cached by modification date.
    let idIndex = NoteIDIndex()
    let sync: SyncService
    let deviceName: String

    private let watcher = FolderWatcher()
    private var rescanTask: Task<Void, Never>?
    private var didRestoreWindows = false
    private var cancellables = Set<AnyCancellable>()
    /// Paths we just wrote — ignore matching FSEvents so typing doesn't full-rescan.
    private var recentLocalWrites: [String: Date] = [:]
    private let localWriteIgnoreInterval: TimeInterval = 1.5

    /// `~/Library/Application Support/MarkdownStickies` — sync state and backups, never in project folders.
    static var supportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MarkdownStickies", isDirectory: true)
    }

    /// Filtered notes when searching; otherwise the full note list (sets only affect open stickies).
    var filteredNotes: [Note] {
        let query = filterText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return notes }
        let roots = scanConfig.effectiveScanURLs()
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
                    minimumScore: FuzzyMatch.defaultMinimumScore
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
        let scanConfig = ScanConfigStore()
        let stateStore = NoteStateStore()
        let windowManager = StickyWindowManager(stateStore: stateStore)
        let name = Host.current().localizedName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let deviceName = (name?.isEmpty == false ? name! : "Mac")
        let writer = NoteWriter(
            trash: SystemTrash(),
            backup: BackupFolder(directory: Self.supportDirectory.appendingPathComponent("Backups", isDirectory: true)),
            editors: EditorRegistry()
        )
        self.scanConfig = scanConfig
        self.stateStore = stateStore
        self.windowManager = windowManager
        self.writer = writer
        self.deviceName = deviceName

        weak var weakSelf: NoteStore?
        self.sync = SyncService(deviceName: deviceName, platform: .mac) { connection, progress in
            guard let store = await MainActor.run(body: { weakSelf }) else { return .failed("The app is closing.") }
            return await store.runSyncSession(connection, progress: progress)
        }
        weakSelf = self

        let index = idIndex
        stateStore.resolveID = { index.entry(for: $0).id }
        windowManager.attach(noteStore: self)
        sync.onFinished = { [weak self] outcome in
            guard let self else { return }
            self.rescan(restoreWindows: false)
            self.windowManager.reloadInlineImages()
            if case .completed(let summary) = outcome, !summary.conflicts.isEmpty {
                self.queueMerges(for: summary.conflicts)
            }
        }

        scanConfig.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
                self?.refreshSyncAdvertising()
            }
            .store(in: &cancellables)

        stateStore.objectWillChange
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

        sync.objectWillChange
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
        BackupFolder(directory: Self.supportDirectory.appendingPathComponent("Backups", isDirectory: true)).purge()
    }

    // MARK: - Sync

    private func refreshSyncAdvertising() {
        if scanConfig.syncedURLs().isEmpty {
            sync.stopAdvertising()
        } else {
            sync.startAdvertising()
        }
    }

    /// Turning Sync off removes the folder's notes from the iOS device at the next sync
    /// (they stay on this Mac), so it asks first.
    func setFolderSynced(_ root: ScanRoot, enabled: Bool) {
        if !enabled {
            let alert = NSAlert()
            alert.messageText = "Turn Off Sync for “\(root.path?.lastPathComponent ?? root.pattern)”?"
            alert.informativeText = "The next sync removes this folder’s notes from your iPhone or iPad. They stay on this Mac. Notes edited on the device but not synced yet are kept there and listed in the sync summary."
            alert.addButton(withTitle: "Turn Sync Off")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        scanConfig.setSynced(root, enabled: enabled)
        refreshSyncAdvertising()
    }

    func syncNow() {
        guard !scanConfig.syncedURLs().isEmpty else {
            lastError = "Turn on Sync for a folder in Settings first."
            return
        }
        lastError = nil
        sync.syncNow(choose: { peers in Self.choosePeer(peers) })
    }

    func cancelSync() {
        sync.cancel()
    }

    func dismissSyncResult() {
        sync.dismissResult()
    }

    /// Runs the Mac side of one session with the current folders and settings.
    private func runSyncSession(
        _ connection: SyncConnection,
        progress: @escaping @Sendable (SyncProgress) -> Void
    ) async -> SyncOutcome {
        scanConfig.reload()
        let defaultRoot = preferredCreateDirectory().map { scanConfig.rootID(for: $0) }
        let configuration = MacSyncSession.Configuration(
            deviceID: sync.deviceID,
            deviceName: deviceName,
            stateRoot: Self.supportDirectory,
            roots: scanConfig.syncRoots(),
            config: scanConfig.config,
            defaultRootID: defaultRoot
        )
        let hooks = MacSyncSession.Hooks(
            saveOpenEditors: { [weak self] in await self?.windowManager.saveAllOpenAndWait() },
            confirmBulkTrash: { [weak self] plan in await self?.confirmBulkTrash(plan) ?? false },
            progress: progress
        )
        return await MacSyncSession.run(connection: connection, configuration: configuration, writer: writer, hooks: hooks)
    }

    /// Bulk-delete guard (spec §3.8): more than 10 notes would move to the trash.
    private func confirmBulkTrash(_ plan: SyncPlan) -> Bool {
        sync.setWaitingForConfirmation(true)
        defer { sync.setWaitingForConfirmation(false) }
        let peer = sync.lastPeerName ?? sync.genericPeerName
        var lines: [String] = []
        var macCount = 0
        var peerCount = 0
        for step in plan.steps {
            guard case .trashNote(_, let at, _) = step.action else { continue }
            if step.device == .mac { macCount += 1 } else { peerCount += 1 }
            if lines.count < 15 { lines.append("• \(at.filename) (\(step.device == .mac ? "this Mac" : peer))") }
        }
        let total = macCount + peerCount
        if total > lines.count { lines.append("… and \(total - lines.count) more") }

        let alert = NSAlert()
        alert.messageText = "Move \(total) Notes to the Trash?"
        var where_: [String] = []
        if macCount > 0 { where_.append("\(macCount) on this Mac") }
        if peerCount > 0 { where_.append("\(peerCount) on \(peer)") }
        alert.informativeText = "This sync would move " + where_.joined(separator: " and ")
            + " to the Trash, because they were deleted on the other device.\n\n" + lines.joined(separator: "\n")
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel Sync")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private static func choosePeer(_ peers: [SyncPeer]) -> SyncPeer? {
        let alert = NSAlert()
        alert.messageText = "Sync with Which Device?"
        alert.informativeText = "More than one device with Markdown Stickies is on this network."
        for peer in peers.prefix(3) { alert.addButton(withTitle: peer.name) }
        alert.addButton(withTitle: "Cancel")
        let index = alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        return index >= 0 && index < min(peers.count, 3) ? peers[index] : nil
    }

    // MARK: - Conflict copies and merge

    @Published var mergeRequest: MergeRequest?
    /// Conflicts from the last sync, merged one after another.
    private var pendingMerges: [MergeRequest] = []
    /// Filled at each rescan: paths of conflict copies, and ids that have a conflict copy.
    @Published private(set) var conflictCopyPaths: Set<String> = []
    /// `stickies-color` per note path, read from the files (the frontmatter is the only source).
    @Published private(set) var noteColors: [String: NoteColor] = [:]
    @Published private(set) var idsWithConflictCopies: Set<UUID> = []

    /// A sticky changed its color (the file is saved shortly after); show it in the list now.
    func noteColorChanged(path: URL, color: NoteColor) {
        noteColors[path.path] = color
    }

    func isConflictCopy(_ note: Note) -> Bool {
        conflictCopyPaths.contains(note.path.path)
    }

    /// The note a conflict copy belongs to, if it's in the list.
    func originalNote(ofConflictCopy note: Note) -> Note? {
        guard let originalID = idIndex.entry(for: note.path).conflictOf else { return nil }
        return notes.first { idIndex.entry(for: $0.path).id == originalID }
    }

    func hasConflictCopy(_ note: Note) -> Bool {
        guard !idsWithConflictCopies.isEmpty, let id = idIndex.entry(for: note.path).id else { return false }
        return idsWithConflictCopies.contains(id)
    }

    /// Opens the merge view for a conflict copy (after saving open stickies).
    func requestMerge(copy: Note) {
        Task { @MainActor in
            await windowManager.saveAllOpenAndWait()
            guard let request = makeMergeRequest(copy: copy) else {
                lastError = "The original of “\(copy.title)” wasn’t found. Edit or delete the copy by hand."
                return
            }
            mergeRequest = request
        }
    }

    /// After a sync that made conflict copies: open the merge view for each, one after another.
    private func queueMerges(for conflicts: [SyncConflictRecord]) {
        let requests = conflicts.compactMap { conflict -> MergeRequest? in
            guard let copy = notes.first(where: { idIndex.entry(for: $0.path).id == conflict.copyID }) else { return nil }
            return makeMergeRequest(copy: copy)
        }
        guard !requests.isEmpty else { return }
        pendingMerges += requests
        AppDelegate.showControlWindow()   // the merge view is a sheet on the notes window
        if mergeRequest == nil { showNextMerge() }
    }

    private func makeMergeRequest(copy: Note) -> MergeRequest? {
        guard let copyID = idIndex.entry(for: copy.path).id,
              let original = originalNote(ofConflictCopy: copy),
              let originalData = try? Data(contentsOf: original.path),
              let copyData = try? Data(contentsOf: copy.path)
        else { return nil }
        return MergeRequest(
            original: original,
            copy: copy,
            originalData: originalData,
            copyData: copyData,
            baseData: SyncStateStore.conflictBase(for: copyID, stateRoot: Self.supportDirectory)
        )
    }

    /// "Later" or after saving: the copy stays (or is gone); go on with the next conflict.
    func finishMerge() {
        mergeRequest = nil
        DispatchQueue.main.async { [weak self] in self?.showNextMerge() }
    }

    private func showNextMerge() {
        while !pendingMerges.isEmpty {
            let next = pendingMerges.removeFirst()
            if FileManager.default.fileExists(atPath: next.copy.path.path) {
                mergeRequest = next
                return
            }
        }
    }

    /// Writes the merged body into the original (keeping its frontmatter; the previous version
    /// goes to Backups) and moves the copy to the Trash. Returns an error text, or nil.
    func saveMerge(_ request: MergeRequest, body: String) -> String? {
        let originalText = String(decoding: request.originalData, as: UTF8.self)
        let prefix = NoteFrontmatter.splitDocument(originalText).prefix
        var merged = NoteFrontmatter.joinDocument(prefix: prefix, body: body)
        if !merged.hasSuffix("\n") { merged += "\n" }
        do {
            try writer.write(
                Data(merged.utf8),
                to: request.original.path,
                expect: .hash(NoteHashing.fileHash(request.originalData)),
                origin: .app
            )
            idIndex.invalidate(request.original.path)
            noteFileDidSave(path: request.original.path, modifiedAt: Date())
        } catch NoteWriter.Failure.changedOnDisk, NoteWriter.Failure.missing {
            return "“\(request.original.title)” changed since the merge view opened. Nothing was saved; open the merge again."
        } catch {
            return error.localizedDescription
        }
        windowManager.close(path: request.copy.path)
        do {
            try writer.trash(request.copy.path, expectHash: NoteHashing.fileHash(request.copyData), origin: .app)
        } catch {
            lastError = "The merge was saved, but the copy couldn’t be moved to the Trash: \(error.localizedDescription)"
        }
        rescan(restoreWindows: false)
        finishMerge()
        return nil
    }

    // MARK: - Notes

    func openNote(_ note: Note) {
        windowManager.open(note: note)
    }

    /// True when this note is in recents or has an inbound badge (and isn’t already buried).
    func canRemoveFromRecents(_ note: Note) -> Bool {
        guard let state = stateStore.storedState(for: note.path) else { return false }
        return state.removedFromRecentsAt == nil && state.lastOpenedAt != nil
    }

    /// Drop the last-opened ranking; bury at the bottom of the list until opened again. The color stays (it lives in the note).
    /// Closes the sticky first if it’s currently open.
    func removeFromRecents(_ note: Note) {
        let path = note.path
        if windowManager.openPaths.contains(path.path) {
            windowManager.close(path: path)
        }
        stateStore.markRemovedFromRecents(path)
        sortNotes()
    }

    func switchToSet(_ index: Int) {
        windowManager.switchToSet(index)
    }

    func restoreActiveSetWindows() {
        windowManager.restoreOpenNotes(from: notes)
    }

    /// Called when a sticky is opened (or re-focused) — bumps list order.
    func noteDidOpen(path: URL) {
        sortNotes()
    }


    func addScanFolder() {
        if scanConfig.addFolder() {
            rescan(restoreWindows: false)
            restartWatcher()
        }
    }

    func removeScanFolder(_ root: ScanRoot) {
        if let path = root.path, isDefaultCreateDirectory(path) {
            UserDefaults.standard.removeObject(forKey: Self.defaultCreateDirectoryKey)
        }
        scanConfig.remove(root)
        rescan(restoreWindows: false)
        restartWatcher()
        refreshSyncAdvertising()
    }

    func addExcludeFolder() {
        if scanConfig.addExcludeFolder() {
            rescan(restoreWindows: false)
        }
    }

    func addExcludePattern(_ pattern: String) {
        scanConfig.addExcludePattern(pattern)
        rescan(restoreWindows: false)
    }

    func openFolderInFinder(_ url: URL) {
        NSWorkspace.shared.open(url.standardizedFileURL)
    }

    /// - Parameter includingSubfolders: `false` → only notes directly in the folder (`…/folder/*.md`);
    ///   `true` → that folder and everything under it.
    func excludeFolder(_ url: URL, includingSubfolders: Bool) {
        let base = ScanGlob.compactHomePath(url.standardizedFileURL)
        let pattern = includingSubfolders ? base : "\(base)/*.md"
        if scanConfig.config.rules.contains(where: { $0.kind == .exclude && $0.pattern == pattern }) {
            return
        }
        scanConfig.addExcludePattern(pattern)
        rescan(restoreWindows: false)
    }

    func updateScanRule(id: String, kind: ScanRule.Kind? = nil, pattern: String? = nil) {
        let kindChanged = kind != nil
        scanConfig.updateRule(id: id, kind: kind, pattern: pattern)
        if kindChanged {
            rescan(restoreWindows: false)
            restartWatcher()
            refreshSyncAdvertising()
        }
    }

    func moveScanRule(from offsets: IndexSet, to offset: Int) {
        scanConfig.moveRule(from: offsets, to: offset)
        rescan(restoreWindows: false)
    }

    func reloadScanConfigFromDisk() {
        scanConfig.reload()
        rescan(restoreWindows: false)
        restartWatcher()
        refreshSyncAdvertising()
    }


    func rescan(restoreWindows: Bool = false) {
        isScanning = true
        lastError = nil
        scanConfig.reload()
        let roots = scanConfig.effectiveScanURLs()
        let scanned = NoteScanner.scan(roots: roots, config: scanConfig.config)
            .filter { !NoteFrontmatter.isLegacyTrash(file: $0.path, roots: roots) }
        let previous = Dictionary(notes.map { ($0.path.path, $0) }, uniquingKeysWith: { _, new in new })
        let openIDs = windowManager.openNoteIDs()
        notes = scanned
        stateStore.migrateLegacyKeys(for: scanned.map(\.path))
        var copies = Set<String>()
        var originals = Set<UUID>()
        var colors: [String: NoteColor] = [:]
        for note in scanned {
            let entry = idIndex.entry(for: note.path)
            if let original = entry.conflictOf {
                copies.insert(note.path.path)
                originals.insert(original)
            }
            if let color = entry.color { colors[note.path.path] = NoteColor(frontmatter: color) }
        }
        noteColors = colors
        conflictCopyPaths = copies
        idsWithConflictCopies = originals
        sortNotes()

        let newPaths = Set(scanned.map(\.path.path))
        for path in previous.keys where !newPaths.contains(path) {
            // An open note that moved (sync, Finder) keeps its window.
            if let id = openIDs[path],
               let moved = scanned.first(where: { previous[$0.path.path] == nil && idIndex.entry(for: $0.path).id == id }) {
                windowManager.noteMoved(from: URL(fileURLWithPath: path), to: moved.path, title: moved.title)
                continue
            }
            windowManager.handleNoteRemoved(path: URL(fileURLWithPath: path))
        }

        for note in scanned {
            guard let old = previous[note.path.path], old.modifiedAt != note.modifiedAt,
                  windowManager.isOpen(note.path),
                  let data = try? Data(contentsOf: note.path)
            else { continue }
            windowManager.reloadIfOpen(
                note: note,
                content: String(decoding: data, as: UTF8.self),
                hash: NoteHashing.fileHash(data)
            )
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
            createdOn: deviceName
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
        let roots = scanConfig.effectiveScanURLs()
        guard !roots.isEmpty else { return nil }

        if let match = defaultCreateDirectory(),
           roots.contains(where: { $0.standardizedFileURL == match.standardizedFileURL }) {
            return match
        }

        let desktop = ScanConfigStore.desktopURL.standardizedFileURL
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
        let roots = scanConfig.effectiveScanURLs()
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
        recentLocalWrites[path.standardizedFileURL.path] = Date()
        // Intentionally do not mutate `notes` here. Autosave used to re-sort/republish
        // the whole list on every keystroke burst, which rebuilt every row.
        _ = modifiedAt
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

    /// Recent opens first; never-opened by file mtime; explicitly removed-from-recents last.
    private func sortNotes() {
        notes = notes.sorted { lhs, rhs in
            let leftState = stateStore.storedState(for: lhs.path)
            let rightState = stateStore.storedState(for: rhs.path)
            let leftBuried = leftState?.removedFromRecentsAt != nil
            let rightBuried = rightState?.removedFromRecentsAt != nil
            if leftBuried != rightBuried { return !leftBuried && rightBuried }

            let leftOpened = leftState?.lastOpenedAt
            let rightOpened = rightState?.lastOpenedAt
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
        let roots = scanConfig.effectiveScanURLs()
        watcher.start(roots: roots) { [weak self] paths in
            Task { @MainActor in
                self?.scheduleRescanFromWatcher(changedPaths: paths)
            }
        }
    }

    private func scheduleRescanFromWatcher(changedPaths: [String]) {
        let now = Date()
        recentLocalWrites = recentLocalWrites.filter {
            now.timeIntervalSince($0.value) < localWriteIgnoreInterval
        }

        let ignoredParents = Set(recentLocalWrites.keys.map {
            URL(fileURLWithPath: $0).deletingLastPathComponent().standardizedFileURL.path
        })
        let external = changedPaths.filter { raw in
            let path = URL(fileURLWithPath: raw).standardizedFileURL.path
            if recentLocalWrites[path] != nil { return false }
            if ignoredParents.contains(path) { return false }
            return true
        }

        // Autosave-only FSEvents — don't rescan the whole tree while typing.
        if !changedPaths.isEmpty && external.isEmpty {
            return
        }

        rescanTask?.cancel()
        rescanTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            rescan(restoreWindows: false)
        }
    }
}
