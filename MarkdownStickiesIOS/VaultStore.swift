import Combine
import Foundation
import MarkdownStickiesCore
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// A file that a sync wrote, moved or trashed, for open editors.
enum SyncFileChange {
    case written(URL)
    case moved(from: URL, to: URL)
    case trashed(URL)
}

/// How a note in the list relates to sync.
enum NoteSyncStatus {
    /// In a root folder, tracked.
    case synced
    /// Top level of the vault: placed into a folder at the next sync.
    case inbox
    case conflictCopy
    /// No `stickies-id` yet, or outside the root folders.
    case notSynced
}

/// The user-picked notes folder ("vault") and the sync with the Mac.
@MainActor
final class VaultStore: ObservableObject {
    @Published private(set) var rootURL: URL?
    @Published private(set) var notes: [Note] = []
    @Published var filterText = ""
    @Published var lastError: String?
    @Published var isScanning = false
    /// Shown when the chosen folder is in iCloud Drive or another cloud location.
    @Published private(set) var folderWarning: String?
    /// Shown in `created_on` and to the Mac — editable in Settings.
    @Published var deviceDisplayName: String {
        didSet {
            let trimmed = deviceDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            UserDefaults.standard.set(trimmed, forKey: Self.deviceNameKey)
            sync.updateDeviceName(trimmed)
        }
    }

    let sync: SyncService
    /// Which notes have unsaved edits (sync never touches those).
    let editors = EditorRegistry()
    /// `stickies-id`, color and conflict marker per file.
    let idIndex = NoteIDIndex()
    /// Every note write goes through this writer (set while a folder is chosen).
    private(set) var writer: NoteWriter?
    /// Files a sync changed, for open editors.
    let fileChanges = PassthroughSubject<SyncFileChange, Never>()

    private var vaultInfo: VaultInfo?
    /// App-owned storage for the vault info (nothing of the sync lives in the user's folder).
    private static var storage: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MarkdownStickies", isDirectory: true)
    }
    private var editorSavers: [UUID: () -> Void] = [:]
    private var cancellables = Set<AnyCancellable>()

    private let bookmarkKey = "vaultFolderBookmark"
    private static let deviceNameKey = "deviceDisplayName"
    private static let lastOpenedKey = "vaultNoteLastOpened"
    private var isAccessing = false
    private var didStart = false
    /// Path → last time the user opened the note (not last save).
    private var lastOpenedAt: [String: Date] = [:]

    var filteredNotes: [Note] {
        let query = filterText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return notes }
        let roots = rootURL.map { [$0] } ?? []
        return notes
            .compactMap { note -> (Note, Int)? in
                let location = Note.locationLabel(for: note.path, scanRoots: roots)
                let score = FuzzyMatch.bestScore(
                    query: query,
                    in: [
                        (note.title, 3),
                        (location, 2),
                        (note.path.path, 1),
                    ]
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
        let resolved = Self.resolveDeviceDisplayName()
        weak var weakSelf: VaultStore?
        self.sync = SyncService(deviceName: resolved, platform: .ios) { connection, progress in
            guard let store = await MainActor.run(body: { weakSelf }) else { return .failed("The app is closing.") }
            return await store.runSyncSession(connection, progress: progress)
        }
        self.deviceDisplayName = resolved
        lastOpenedAt = Self.loadLastOpened()
        weakSelf = self
        sync.onFinished = { [weak self] _ in self?.rescan() }
        sync.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        // Do not restore/scan/advertise here — that blocked launch on the main thread.
    }

    /// Call once the UI is up (e.g. `ContentView.onAppear`).
    func startIfNeeded() {
        guard !didStart else { return }
        didStart = true
        // Let the first frame paint before disk / network work.
        Task { @MainActor in
            await Task.yield()
            restoreBookmark()
        }
    }

    /// iOS 16+ hides the user-assigned name behind an entitlement; fall back to hostname.
    private static func resolveDeviceDisplayName() -> String {
        let generics: Set<String> = ["iPhone", "iPad", "iPod", "iPod touch", "Apple Vision Pro", "iOS"]
        if let saved = UserDefaults.standard.string(forKey: deviceNameKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !saved.isEmpty,
           !generics.contains(saved) {
            return saved
        }
        #if canImport(UIKit)
        let assigned = UIDevice.current.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !assigned.isEmpty, !generics.contains(assigned) {
            return assigned
        }
        if let fromHost = friendlyHostName(), !fromHost.isEmpty {
            return fromHost
        }
        return assigned.isEmpty ? "iPhone" : assigned
        #else
        return "iOS"
        #endif
    }

    private static func friendlyHostName() -> String? {
        var host = ProcessInfo.processInfo.hostName
        if let dot = host.firstIndex(of: ".") {
            host = String(host[..<dot])
        }
        host = host.replacingOccurrences(of: "-", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, host.caseInsensitiveCompare("localhost") != .orderedSame else {
            return nil
        }
        return host
    }

    // MARK: - Sync

    func syncNow() {
        guard rootURL != nil else {
            lastError = "Choose a notes folder before syncing."
            return
        }
        lastError = nil
        sync.syncNow()
    }

    /// Settings → Start Fresh: the next sync treats this folder as new (no deletes anywhere).
    func startSyncFresh() {
        guard let root = rootURL else { return }
        do {
            try VaultScanner.forgetInfo(vault: root, storage: Self.storage)
            vaultInfo = nil
            sync.dismissResult()
        } catch {
            lastError = "Could not reset sync: \(error.localizedDescription)"
        }
    }

    func cancelSync() {
        sync.cancel()
    }

    func dismissSyncResult() {
        sync.dismissResult()
    }

    /// Call when the app returns to the foreground — Bonjour often goes stale after sleep.
    func ensureDiscoverable() {
        guard rootURL != nil else { return }
        sync.refreshAdvertising()
    }

    private func refreshSyncAdvertising() {
        if rootURL == nil {
            sync.stopAdvertising()
        } else {
            // iOS must stay discoverable so the Mac can start a sync.
            sync.startAdvertising()
        }
    }

    /// The iOS side of one session: report the vault, carry out the Mac's steps.
    private func runSyncSession(
        _ connection: SyncConnection,
        progress: @escaping @Sendable (SyncProgress) -> Void
    ) async -> SyncOutcome {
        guard let root = rootURL, let writer else {
            connection.close()
            return .failed("Choose a notes folder on \(deviceDisplayName) first.")
        }
        #if canImport(UIKit)
        let background = UIApplication.shared.beginBackgroundTask(withName: "Sync")
        defer { UIApplication.shared.endBackgroundTask(background) }
        #endif
        let configuration = IOSSyncResponder.Configuration(
            deviceID: sync.deviceID,
            deviceName: deviceDisplayName,
            vault: root,
            storage: Self.storage
        )
        let hooks = IOSSyncResponder.Hooks(
            saveOpenEditors: { [weak self] in await self?.saveOpenEditors() },
            stepApplied: { [weak self] action in await self?.publishChange(action) },
            progress: progress
        )
        let outcome = await IOSSyncResponder.run(connection: connection, configuration: configuration, writer: writer, hooks: hooks)
        vaultInfo = try? VaultScanner.loadOrCreateInfo(vault: root, storage: Self.storage)
        return outcome
    }

    private func publishChange(_ action: SyncAction) {
        guard let root = rootURL, let info = try? VaultScanner.loadOrCreateInfo(vault: root, storage: Self.storage) else { return }
        func url(_ location: NoteLocation) -> URL? {
            VaultScanner.url(for: location, vault: root, info: info)?.standardizedFileURL
        }
        switch action {
        case .writeNote(_, let at, _, _):
            if let url = url(at) {
                idIndex.invalidate(url)
                fileChanges.send(.written(url))
            }
        case .moveNote(_, let from, let to, _):
            if let source = url(from), let target = url(to) {
                idIndex.invalidate(source)
                fileChanges.send(.moved(from: source, to: target))
            }
        case .trashNote(_, let at, _):
            if let url = url(at) { fileChanges.send(.trashed(url)) }
        default:
            break
        }
    }

    // MARK: - Editors

    /// Open editors register a save function, so a sync can save them first.
    func registerEditor(_ id: UUID, save: @escaping () -> Void) {
        editorSavers[id] = save
    }

    func unregisterEditor(_ id: UUID) {
        editorSavers[id] = nil
    }

    private func saveOpenEditors() {
        for save in editorSavers.values { save() }
    }

    /// The app wrote a file itself (editor save, new note).
    func noteWritten(_ url: URL) {
        idIndex.invalidate(url)
    }

    // MARK: - Folder

    func stopAccessingIfNeeded() {
        if isAccessing, let url = rootURL {
            url.stopAccessingSecurityScopedResource()
            isAccessing = false
        }
    }

    func setFolder(_ url: URL) {
        stopAccessingIfNeeded()
        lastError = nil

        guard url.startAccessingSecurityScopedResource() else {
            lastError = "Could not access the selected folder."
            rootURL = nil
            notes = []
            writer = nil
            refreshSyncAdvertising()
            return
        }
        isAccessing = true
        activate(url.standardizedFileURL)

        do {
            let data = try url.bookmarkData(
                options: .minimalBookmark,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            UserDefaults.standard.set(data, forKey: bookmarkKey)
        } catch {
            lastError = "Could not save folder access: \(error.localizedDescription)"
        }
    }

    func clearFolder() {
        stopAccessingIfNeeded()
        rootURL = nil
        notes = []
        writer = nil
        vaultInfo = nil
        UserDefaults.standard.removeObject(forKey: bookmarkKey)
        refreshSyncAdvertising()
    }

    private func activate(_ root: URL) {
        rootURL = root
        let trash = FolderTrash(vault: root)
        writer = NoteWriter(trash: trash, backup: trash, editors: editors)
        trash.purge()
        vaultInfo = try? VaultScanner.loadOrCreateInfo(vault: root, storage: Self.storage)
        let isCloud = (try? root.resourceValues(forKeys: [.isUbiquitousItemKey]))?.isUbiquitousItem == true
        folderWarning = isCloud
            ? "This folder is in iCloud Drive. Files iCloud removed from this device are skipped during syncs. A folder “On My iPhone” works best."
            : nil
        rescan()
        refreshSyncAdvertising()
    }

    func rescan() {
        guard let root = rootURL else {
            notes = []
            isScanning = false
            return
        }
        isScanning = true
        let scanRoot = root
        Task.detached(priority: .userInitiated) {
            let trash = scanRoot.appendingPathComponent(FolderTrash.folderName).standardizedFileURL.path + "/"
            let scanned = NoteScanner.scan(roots: [scanRoot], config: .empty)
                .filter { !$0.path.standardizedFileURL.path.hasPrefix(trash) }
            await MainActor.run {
                // Ignore stale results if the folder changed mid-scan.
                guard self.rootURL?.standardizedFileURL == scanRoot.standardizedFileURL else { return }
                self.vaultInfo = try? VaultScanner.loadOrCreateInfo(vault: scanRoot, storage: Self.storage)
                self.notes = Self.sortedNotes(scanned, lastOpened: self.lastOpenedAt)
                self.isScanning = false
            }
        }
    }

    // MARK: - Notes

    func status(of note: Note) -> NoteSyncStatus {
        guard let root = rootURL else { return .notSynced }
        let entry = idIndex.entry(for: note.path)
        let rootPath = root.standardizedFileURL.path + "/"
        let path = note.path.standardizedFileURL.path
        guard path.hasPrefix(rootPath), entry.id != nil else { return .notSynced }
        let components = path.dropFirst(rootPath.count).split(separator: "/")
        if components.count == 1 { return .inbox }
        let folders = Set(vaultInfo?.roots.map(\.folderName) ?? [])
        guard let first = components.first, folders.contains(String(first)) else { return .notSynced }
        return entry.conflictOf != nil ? .conflictCopy : .synced
    }

    func color(of note: Note) -> MarkdownStickiesCore.NoteColor? {
        idIndex.entry(for: note.path).color
    }

    /// New notes go to the top level of the vault (the Inbox); the next sync places them.
    func createNote(title: String) -> Note? {
        guard let root = rootURL, let writer else { return nil }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let effective = trimmed.isEmpty ? "Untitled" : trimmed
        let url = NoteFilename.uniqueURL(in: root, date: Date(), title: effective)
        let initial = NoteFrontmatter.initialDocument(title: effective, createdOn: deviceDisplayName)
        do {
            try writer.write(Data(initial.utf8), to: url, expect: .absent, origin: .app)
            noteWritten(url)
            rescan()
            return NoteFilename.parse(url: url.standardizedFileURL, modifiedAt: Date())
                ?? Note(path: url.standardizedFileURL, date: Date(), title: effective, modifiedAt: Date())
        } catch {
            lastError = "Could not create note: \(error.localizedDescription)"
            return nil
        }
    }

    /// Call when the user opens a note (not on save / swipe-away).
    func touchLastOpened(_ path: URL) {
        let key = path.standardizedFileURL.path
        lastOpenedAt[key] = Date()
        Self.persistLastOpened(lastOpenedAt)
        notes = Self.sortedNotes(notes, lastOpened: lastOpenedAt)
    }

    /// Moves a note to the `Stickies Trash` folder (kept 30 days). The next sync moves the Mac's copy
    /// to the Trash, unless the Mac edited it meanwhile.
    func moveNoteToTrash(_ note: Note) {
        guard let writer, let hash = NoteWriter.currentHash(of: note.path) else {
            lastError = "Could not move to Trash: the file can’t be read."
            return
        }
        do {
            try writer.trash(note.path, expectHash: hash, origin: .app)
            rescan()
        } catch {
            lastError = "Could not move to Trash: \(error.localizedDescription)"
        }
    }

    /// Recent opens first; never-opened notes fall back to file modification date.
    private static func sortedNotes(_ notes: [Note], lastOpened: [String: Date]) -> [Note] {
        notes.sorted { lhs, rhs in
            let leftOpened = lastOpened[lhs.path.standardizedFileURL.path]
            let rightOpened = lastOpened[rhs.path.standardizedFileURL.path]
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

    private static func loadLastOpened() -> [String: Date] {
        guard let raw = UserDefaults.standard.dictionary(forKey: lastOpenedKey) as? [String: Double]
        else { return [:] }
        return raw.mapValues { Date(timeIntervalSince1970: $0) }
    }

    private static func persistLastOpened(_ map: [String: Date]) {
        let raw = map.mapValues { $0.timeIntervalSince1970 }
        UserDefaults.standard.set(raw, forKey: lastOpenedKey)
    }

    private func restoreBookmark() {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return }
        var isStale = false
        do {
            let url = try URL(
                resolvingBookmarkData: data,
                options: [.withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            // Access before mutating published state so a failed scope doesn't flash empty UI.
            guard url.startAccessingSecurityScopedResource() else {
                lastError = "Could not access the saved folder. Pick it again."
                UserDefaults.standard.removeObject(forKey: bookmarkKey)
                return
            }
            isAccessing = true
            if isStale,
               let refreshed = try? url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil) {
                UserDefaults.standard.set(refreshed, forKey: bookmarkKey)
            }
            activate(url.standardizedFileURL)
        } catch {
            lastError = "Saved folder is no longer available. Pick it again."
            UserDefaults.standard.removeObject(forKey: bookmarkKey)
        }
    }
}

extension MarkdownStickiesCore.NoteColor {
    /// Same fills as the Mac stickies.
    var swiftUIColor: Color {
        switch self {
        case .preset(.yellow): return Color(red: 1.0, green: 0.95, blue: 0.6)
        case .preset(.blue): return Color(red: 0.72, green: 0.88, blue: 1.0)
        case .preset(.green): return Color(red: 0.75, green: 0.95, blue: 0.75)
        case .preset(.pink): return Color(red: 1.0, green: 0.8, blue: 0.85)
        case .preset(.purple): return Color(red: 0.88, green: 0.8, blue: 0.95)
        case .preset(.gray): return Color(red: 0.9, green: 0.9, blue: 0.9)
        case .custom(let hex):
            let digits = hex.dropFirst()
            guard digits.count == 6, let value = Int(digits, radix: 16) else { return .yellow }
            return Color(
                red: Double((value >> 16) & 0xFF) / 255,
                green: Double((value >> 8) & 0xFF) / 255,
                blue: Double(value & 0xFF) / 255
            )
        }
    }
}
