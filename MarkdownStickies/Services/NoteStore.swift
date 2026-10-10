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
    /// Paths written from the peer on the last sync.
    @Published private(set) var syncInboundPaths: Set<String> = []
    /// Paths we sent that the peer has not confirmed yet.
    @Published private(set) var syncOutboundPaths: Set<String> = []
    /// Centered sync result banner (stays until dismissed or next sync).
    @Published var syncBanner: SyncFeedback?
    /// Keep-both conflicts from the last sync — Mac shows a review sheet after the banner.
    @Published var pendingConflicts: [SyncConflict] = []

    let scanConfig: ScanConfigStore
    let stateStore: NoteStateStore
    let windowManager: StickyWindowManager
    let syncService: LanSyncService

    private let watcher = FolderWatcher()
    private var rescanTask: Task<Void, Never>?
    private var didRestoreWindows = false
    private var cancellables = Set<AnyCancellable>()
    /// Paths we just wrote — ignore matching FSEvents so typing doesn't full-rescan.
    private var recentLocalWrites: [String: Date] = [:]
    private let localWriteIgnoreInterval: TimeInterval = 1.5

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
        let deviceName = Host.current().localizedName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let syncService = LanSyncService(
            deviceName: (deviceName?.isEmpty == false ? deviceName! : "Mac")
        )
        self.scanConfig = scanConfig
        self.stateStore = stateStore
        self.windowManager = windowManager
        self.syncService = syncService
        windowManager.attach(noteStore: self)
        configureSync()

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
            self.scanConfig.reload()
            return SyncCatalogBuilder.catalog(
                roots: self.scanConfig.syncedURLs(),
                config: self.scanConfig.config
            )
        }
        syncService.syncRootsProvider = { [weak self] in
            self?.scanConfig.syncedURLs() ?? []
        }
        syncService.onApplyRemoteCatalog = { [weak self] remote, peerLabel in
            self?.applyRemoteCatalog(remote, peerLabel: peerLabel) ?? .empty
        }
        syncService.onExchangeFinished = { [weak self] result, role in
            self?.presentSyncResult(result, role: role)
        }
        syncService.onProgress = { [weak self] feedback in
            self?.syncBanner = feedback
        }
        syncService.onRemoteBannerDismiss = { [weak self] in
            self?.syncBanner = nil
        }
        syncService.onRemoteMergeCancel = { [weak self] in
            self?.syncBanner = nil
            self?.pendingConflicts = []
        }
    }

    private func refreshSyncAdvertising() {
        if scanConfig.syncedURLs().isEmpty {
            syncService.stopAdvertising()
        } else {
            syncService.startAdvertising()
            syncService.requestLocalNetworkAuthorization()
        }
    }

    func setFolderSynced(_ root: ScanRoot, enabled: Bool) {
        scanConfig.setSynced(root, enabled: enabled)
        refreshSyncAdvertising()
    }

    func syncNow() async {
        let roots = scanConfig.syncedURLs()
        guard !roots.isEmpty else {
            lastError = "Enable Sync on a scan folder in Settings first."
            return
        }
        windowManager.saveAllOpen()
        lastError = nil
        pendingConflicts = []
        // Show the green card immediately — LanSyncService keeps it updated.
        syncBanner = SyncFeedback.progress(
            title: "Syncing",
            message: "Looking for peer…",
            startedAt: Date(),
            timeoutSeconds: 20,
            debugCode: "sync:looking"
        )
        do {
            // Final banner + debug log come from onExchangeFinished / onProgress.
            _ = try await syncService.syncWithPeer()
        } catch {
            let message = LanSyncService.friendlyNetworkError(error)
            let feedback = SyncFeedback(
                kind: .failure,
                title: "Sync failed",
                message: message,
                statusLine: "Sync failed — \(message)",
                detail: String(describing: error),
                debugCode: "sync:transport-error",
                receivedCount: 0,
                sentConfirmedCount: 0,
                sentExpectedCount: 0
            )
            syncBanner = feedback
            syncService.setStatus(feedback.statusLine)
            if let dir = preferredCreateDirectory() ?? scanConfig.syncedURLs().first {
                SyncDebugLog.appendExchange(
                    directory: dir,
                    deviceName: syncService.deviceName,
                    role: .client,
                    feedback: feedback,
                    result: nil
                )
            }
        }
    }

    func dismissSyncBanner() {
        if syncBanner?.debugCode == "sync:await-mac-merge" {
            abortMergeSession(notifyPeer: true)
            return
        }
        let shouldNotifyPeer = syncBanner?.kind == .success
        syncBanner = nil
        // Only clear the peer's success card. Never resurrect progress via Bonjour side effects.
        if shouldNotifyPeer {
            syncService.notifyPeerDismissBanner()
        }
    }

    /// Later / Sync Later — close merge UI on both devices; note bodies stay as they are.
    func dismissPendingConflicts() {
        abortMergeSession(notifyPeer: true)
    }

    private func abortMergeSession(notifyPeer: Bool) {
        pendingConflicts = []
        syncBanner = nil
        if notifyPeer {
            syncService.notifyPeerCancelMerge()
        }
    }

    /// Open both sides of a keep-both conflict (local + sibling).
    func openConflictNotes(_ conflict: SyncConflict) {
        let roots = scanConfig.syncedURLs()
        let paths = SyncCatalogBuilder.pathIndex(roots: roots)
        if let localPath = paths[conflict.id] {
            let note = notes.first(where: { $0.path.standardizedFileURL == localPath.standardizedFileURL })
                ?? Note(
                    path: localPath,
                    date: conflict.local.modifiedAt,
                    title: conflict.local.title,
                    modifiedAt: conflict.local.modifiedAt
                )
            openNote(note)
        }
        if let sibling = conflict.remoteCopyPath {
            let note = notes.first(where: { $0.path.standardizedFileURL == sibling.standardizedFileURL })
                ?? Note(
                    path: sibling,
                    date: conflict.remote.modifiedAt,
                    title: "\(conflict.remote.title) (from \(conflict.peerLabel))",
                    modifiedAt: conflict.remote.modifiedAt
                )
            openNote(note)
        }
    }

    /// Dismiss one conflict after the user confirms keep-both.
    func acknowledgeConflict(_ conflict: SyncConflict) {
        pendingConflicts.removeAll { $0.id == conflict.id }
    }

    /// Write a merged body into the local (primary) note and trash the sibling copy.
    /// Stamps `conflict_resolved` so the next sync applies this body on peers (no re-conflict).
    /// Does **not** create a new note — only updates the original file.
    func mergeConflict(_ conflict: SyncConflict, mergedBody: String) {
        let roots = scanConfig.effectiveScanURLs()
        let synced = scanConfig.syncedURLs()
        let indexRoots = synced.isEmpty ? roots : synced
        let trashRoots = synced.isEmpty ? roots : synced
        let paths = SyncCatalogBuilder.pathIndex(roots: indexRoots)
        guard let localPath = paths[conflict.id] else {
            lastError = "Could not find the local conflict note."
            return
        }
        do {
            let now = Date()
            let cleaned = Self.normalizedMergeBody(mergedBody, fallingBackTo: conflict.local.body)
            // Preserve frontmatter from the chosen markdown when present; always force primary id + resolve.
            let withFrontmatter: String = {
                let parts = NoteFrontmatter.splitDocument(cleaned)
                if parts.prefix.isEmpty {
                    // Editor showed body-only — graft onto existing primary frontmatter.
                    let existing = (try? String(contentsOf: localPath, encoding: .utf8)) ?? conflict.local.body
                    let existingParts = NoteFrontmatter.splitDocument(existing)
                    return NoteFrontmatter.joinDocument(prefix: existingParts.prefix, body: cleaned)
                }
                return cleaned
            }()
            var body = NoteFrontmatter.settingSyncID(conflict.id, in: withFrontmatter)
            body = NoteFrontmatter.settingConflictResolved(now, in: body)
            try body.write(to: localPath, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.modificationDate: now],
                ofItemAtPath: localPath.path
            )
            noteFileDidSave(path: localPath, modifiedAt: now)
            let note = notes.first(where: { $0.path.standardizedFileURL == localPath.standardizedFileURL })
                ?? Note(
                    path: localPath,
                    date: now,
                    title: conflict.local.title,
                    modifiedAt: now
                )
            // Force into the open sticky — a normal reload is refused while dirty, and an
            // in-flight debounce save used to overwrite this stamp before sync left the Mac.
            windowManager.forceReloadIfOpen(note: note, content: body)

            // Remove the keep-both sibling for good (local-only aide — not Trash/sync).
            let siblingPath = conflict.remoteCopyPath
                ?? paths[conflict.remoteCopyID]
            if let sibling = siblingPath,
               sibling.standardizedFileURL != localPath.standardizedFileURL,
               FileManager.default.fileExists(atPath: sibling.path) {
                windowManager.close(path: sibling)
                try? FileManager.default.removeItem(at: sibling)
            }

            try removeConflictSiblingCopies(
                matchingFingerprint: NoteFrontmatter.contentFingerprint(conflict.remote.body),
                exceptID: conflict.id,
                exceptPath: localPath,
                roots: trashRoots
            )

            pendingConflicts.removeAll { $0.id == conflict.id }
            rescan(restoreWindows: false)
            // Push the merge to iOS (Mac is authority) — don't leave the phone on the old body.
            let stampedBody = body
            let stampedPath = localPath
            Task {
                // syncNow saveAllOpen()'s open stickies first. Re-assert stamp on disk so a
                // race can't send an unstamped catalog (iOS then keeps its old body forever).
                self.windowManager.saveAllOpen()
                let onDisk = (try? String(contentsOf: stampedPath, encoding: .utf8)) ?? ""
                if NoteFrontmatter.conflictResolvedAt(in: onDisk) == nil {
                    try? stampedBody.write(to: stampedPath, atomically: true, encoding: .utf8)
                    self.windowManager.forceReloadIfOpen(note: note, content: stampedBody)
                }
                await self.syncNow()
            }
        } catch {
            lastError = "Could not merge conflict: \(error.localizedDescription)"
        }
    }

    /// Drop leftover git-style markers if the user pasted an old merge draft.
    private static func normalizedMergeBody(_ raw: String, fallingBackTo fallback: String) -> String {
        var lines = raw.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        lines.removeAll { line in
            line.hasPrefix("<<<<<<<") || line.hasPrefix(">>>>>>>") || line == "======="
        }
        let cleaned = lines.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? fallback : cleaned + "\n"
    }

    /// Delete leftover keep-both copies of the superseded peer body (not Trash — local only).
    private func removeConflictSiblingCopies(
        matchingFingerprint fingerprint: String,
        exceptID: UUID,
        exceptPath: URL,
        roots: [URL]
    ) throws {
        let except = exceptPath.standardizedFileURL
        for note in NoteScanner.scan(roots: roots) {
            let path = note.path.standardizedFileURL
            guard path != except else { continue }
            guard let text = try? String(contentsOf: path, encoding: .utf8) else { continue }
            if let id = NoteFrontmatter.syncID(in: text), id == exceptID { continue }
            guard NoteFrontmatter.contentFingerprint(text) == fingerprint else { continue }
            if NoteFrontmatter.isTrashed(file: path) { continue }
            windowManager.close(path: path)
            try? FileManager.default.removeItem(at: path)
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

    /// True when this note is in recents or has an inbound badge (and isn’t already buried).
    func canRemoveFromRecents(_ note: Note) -> Bool {
        let key = note.path.standardizedFileURL.path
        if syncInboundPaths.contains(key) { return true }
        guard let state = stateStore.storedState(for: note.path) else { return false }
        return state.removedFromRecentsAt == nil && state.lastOpenedAt != nil
    }

    /// Drop last-opened ranking and color; bury at the bottom of the list until opened again.
    /// Closes the sticky first if it’s currently open.
    func removeFromRecents(_ note: Note) {
        let path = note.path
        if windowManager.openPaths.contains(path.path) {
            windowManager.close(path: path)
        }
        stateStore.markRemovedFromRecents(path)
        acknowledgeInbound(for: path)
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
        acknowledgeInbound(for: path)
        sortNotes()
    }

    private func presentSyncResult(_ result: SyncExchangeResult, role: SyncExchangeRole) {
        let roots = scanConfig.syncedURLs()
        let localPaths = SyncCatalogBuilder.pathIndex(roots: roots)
        syncOutboundPaths = Set(
            result.peerAppliedIDs.compactMap { localPaths[$0]?.standardizedFileURL.path }
        )

        pendingConflicts = result.conflicts

        let feedback = SyncFeedback.from(
            result: result,
            role: role,
            peerName: result.peerDeviceName
        )
        syncService.setStatus(feedback.statusLine)
        // Banner carries sync errors; avoid a second alert.
        if feedback.kind == .success
            || feedback.debugCode == "sync:conflicts"
            || feedback.debugCode == "sync:await-mac-merge"
        {
            lastError = nil
        }

        // Conflicts → skip the orange “kept both” card and open the merge sheet directly.
        if !result.conflicts.isEmpty {
            syncBanner = nil
        } else {
            syncBanner = feedback
        }

        if let dir = preferredCreateDirectory() ?? roots.first {
            SyncDebugLog.appendExchange(
                directory: dir,
                deviceName: syncService.deviceName,
                role: role,
                feedback: feedback,
                result: result
            )
            // Debug note is new/updated — refresh list so it appears.
            rescan(restoreWindows: false)
        }

        if result.imagesReceived > 0 {
            windowManager.reloadOpenPreviewMedia()
        }
    }

    @discardableResult
    private func applyRemoteCatalog(
        _ remote: [SyncNotePayload],
        peerLabel: String?
    ) -> SyncApplyAck {
        let roots = scanConfig.syncedURLs()
        guard !roots.isEmpty else {
            lastError = "No synced folder to receive notes."
            return SyncApplyAck(errorDescription: "No synced folder")
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
            let result = try SyncCatalogBuilder.applyRemoteCatalog(
                remote,
                roots: roots,
                createDirectory: createDir,
                peerLabel: peerLabel,
                conflictRole: .mergeAuthority
            )
            // Surface received notes at the top of the list (sort uses lastOpenedAt + inbound).
            let receivedAt = Date()
            for path in result.appliedPaths {
                stateStore.touchLastOpened(path, at: receivedAt)
            }
            syncInboundPaths = Set(result.appliedPaths.map { $0.standardizedFileURL.path })
            rescan(restoreWindows: false)
            return SyncApplyAck(
                appliedIDs: result.appliedIDs,
                conflicts: result.conflicts,
                awaitingAuthorityMerge: result.awaitingAuthorityMerge
            )
        } catch {
            lastError = "Could not apply sync: \(error.localizedDescription)"
            return SyncApplyAck(errorDescription: error.localizedDescription)
        }
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
    /// Just-received sync inbound notes are also opened-touched so they float to the top.
    private func sortNotes() {
        notes = notes.sorted { lhs, rhs in
            let leftInbound = syncInboundPaths.contains(lhs.path.standardizedFileURL.path)
            let rightInbound = syncInboundPaths.contains(rhs.path.standardizedFileURL.path)
            if leftInbound != rightInbound { return leftInbound && !rightInbound }

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
