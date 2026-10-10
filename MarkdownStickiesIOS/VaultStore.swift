import Foundation
import MarkdownStickiesCore
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Persists a security-scoped bookmark for a user-picked notes folder.
@MainActor
final class VaultStore: ObservableObject {
    @Published private(set) var rootURL: URL?
    @Published private(set) var notes: [Note] = []
    @Published var filterText = ""
    @Published var lastError: String?
    @Published var isScanning = false
    /// Shown in `created_on` and LAN hello — editable in Settings.
    @Published var deviceDisplayName: String {
        didSet {
            let trimmed = deviceDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            UserDefaults.standard.set(trimmed, forKey: Self.deviceNameKey)
            syncService.updateDeviceName(trimmed)
        }
    }
    /// Paths written from the peer on the last sync.
    @Published private(set) var syncInboundPaths: Set<String> = []
    /// Paths we sent that the peer has not confirmed yet.
    @Published private(set) var syncOutboundPaths: Set<String> = []
    /// Centered sync result banner (stays until dismissed or next sync).
    @Published var syncBanner: SyncFeedback?

    let syncService: LanSyncService

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
        let syncService = LanSyncService(deviceName: resolved)
        self.syncService = syncService
        self.deviceDisplayName = resolved
        lastOpenedAt = Self.loadLastOpened()
        configureSync()
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

    private func configureSync() {
        syncService.catalogProvider = { [weak self] in
            guard let self, let root = self.rootURL else { return [] }
            return SyncCatalogBuilder.catalog(roots: [root], config: ScanConfig.load())
        }
        syncService.syncRootsProvider = { [weak self] in
            guard let root = self?.rootURL else { return [] }
            return [root]
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
        }
    }

    private func refreshSyncAdvertising() {
        if rootURL == nil {
            syncService.stopAdvertising()
            return
        }
        // iOS must stay discoverable so Mac→iOS sync can find this device.
        syncService.requestLocalNetworkAuthorization()
        syncService.startAdvertising()
    }

    /// Call when the app returns to the foreground — Bonjour often goes stale after sleep.
    func ensureDiscoverable() {
        guard rootURL != nil else { return }
        syncService.ensureAdvertisingFresh()
    }

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
            refreshSyncAdvertising()
            return
        }
        isAccessing = true
        rootURL = url.standardizedFileURL

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

        rescan()
        refreshSyncAdvertising()
    }

    func clearFolder() {
        stopAccessingIfNeeded()
        rootURL = nil
        notes = []
        UserDefaults.standard.removeObject(forKey: bookmarkKey)
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
            let scanned = NoteScanner.scan(roots: [scanRoot], config: ScanConfig.load())
                .filter { !NoteFrontmatter.isTrashed(file: $0.path) }
            await MainActor.run {
                // Ignore stale results if the folder changed mid-scan.
                guard self.rootURL?.standardizedFileURL == scanRoot.standardizedFileURL else { return }
                self.notes = Self.sortedNotes(
                    scanned,
                    inbound: self.syncInboundPaths,
                    lastOpened: self.lastOpenedAt
                )
                self.isScanning = false
            }
        }
    }

    /// Call when the user opens a note (not on save / swipe-away).
    func touchLastOpened(_ path: URL) {
        let key = path.standardizedFileURL.path
        lastOpenedAt[key] = Date()
        Self.persistLastOpened(lastOpenedAt)
        notes = Self.sortedNotes(notes, inbound: syncInboundPaths, lastOpened: lastOpenedAt)
    }

    /// Moves a note into the vault `Trash/` folder so the next sync propagates the delete.
    func moveNoteToTrash(_ note: Note) {
        guard let root = rootURL else { return }
        do {
            _ = try NoteFrontmatter.moveToTrash(file: note.path, roots: [root])
            rescan()
        } catch {
            lastError = "Could not move to Trash: \(error.localizedDescription)"
        }
    }

    func syncNow() async {
        guard let root = rootURL else {
            lastError = "Pick a folder before syncing."
            return
        }
        lastError = nil
        syncBanner = SyncFeedback.progress(
            title: "Syncing",
            message: "Looking for peer…",
            startedAt: Date(),
            timeoutSeconds: 20,
            debugCode: "sync:looking"
        )
        do {
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
            SyncDebugLog.appendExchange(
                directory: root,
                deviceName: syncService.deviceName,
                role: .client,
                feedback: feedback,
                result: nil
            )
        }
    }

    func dismissSyncBanner() {
        if syncBanner?.debugCode == "sync:await-mac-merge" {
            // Sync Later — cancel merge session on Mac too; leave note bodies unchanged.
            syncBanner = nil
            syncService.notifyPeerCancelMerge()
            return
        }
        let shouldNotifyPeer = syncBanner?.kind == .success
        syncBanner = nil
        if shouldNotifyPeer {
            syncService.notifyPeerDismissBanner()
        }
    }

    /// User opened a note — drop the “received” badge (they’ve seen the new content).
    func acknowledgeInbound(for path: URL) {
        let key = path.standardizedFileURL.path
        guard syncInboundPaths.contains(key) else { return }
        syncInboundPaths.remove(key)
    }

    private func presentSyncResult(_ result: SyncExchangeResult, role: SyncExchangeRole) {
        guard let root = rootURL else { return }
        let localPaths = SyncCatalogBuilder.pathIndex(roots: [root])
        syncOutboundPaths = Set(
            result.peerAppliedIDs.compactMap { localPaths[$0]?.standardizedFileURL.path }
        )

        let feedback = SyncFeedback.from(
            result: result,
            role: role,
            peerName: result.peerDeviceName
        )
        syncBanner = feedback
        syncService.setStatus(feedback.statusLine)
        if feedback.kind == .success
            || feedback.debugCode == "sync:conflicts"
            || feedback.debugCode == "sync:await-mac-merge"
        {
            lastError = nil
        }

        SyncDebugLog.appendExchange(
            directory: root,
            deviceName: syncService.deviceName,
            role: role,
            feedback: feedback,
            result: result
        )
        rescan()
    }

    @discardableResult
    private func applyRemoteCatalog(
        _ remote: [SyncNotePayload],
        peerLabel: String?
    ) -> SyncApplyAck {
        guard let root = rootURL else {
            return SyncApplyAck(errorDescription: "No folder")
        }
        do {
            let result = try SyncCatalogBuilder.applyRemoteCatalog(
                remote,
                roots: [root],
                createDirectory: root,
                peerLabel: peerLabel ?? "Mac",
                conflictRole: .satellite
            )

            // Replace marks from this exchange only — blues not re-sent disappear.
            syncInboundPaths = Set(result.appliedPaths.map { $0.standardizedFileURL.path })
            let receivedAt = Date()
            for path in result.appliedPaths {
                lastOpenedAt[path.standardizedFileURL.path] = receivedAt
            }
            if !result.appliedPaths.isEmpty {
                Self.persistLastOpened(lastOpenedAt)
            }
            rescan()
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

    /// Recent opens first; never-opened notes fall back to file modification date.
    /// Inbound sync notes are open-touched so they float to the top.
    private static func sortedNotes(
        _ notes: [Note],
        inbound: Set<String>,
        lastOpened: [String: Date]
    ) -> [Note] {
        notes.sorted { lhs, rhs in
            let leftKey = lhs.path.standardizedFileURL.path
            let rightKey = rhs.path.standardizedFileURL.path
            let leftInbound = inbound.contains(leftKey)
            let rightInbound = inbound.contains(rightKey)
            if leftInbound != rightInbound { return leftInbound && !rightInbound }

            let leftOpened = lastOpened[leftKey]
            let rightOpened = lastOpened[rightKey]
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
            rootURL = url.standardizedFileURL
            if isStale {
                if let refreshed = try? url.bookmarkData(
                    options: .minimalBookmark,
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                ) {
                    UserDefaults.standard.set(refreshed, forKey: bookmarkKey)
                }
            }
            rescan()
            refreshSyncAdvertising()
        } catch {
            lastError = "Saved folder is no longer available. Pick it again."
            UserDefaults.standard.removeObject(forKey: bookmarkKey)
        }
    }
}
