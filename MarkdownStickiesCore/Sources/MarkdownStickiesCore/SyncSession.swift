import Foundation

/// The Mac side of a sync (spec §3.6). Whoever opened the connection, the Mac plans
/// and the iOS device carries out the steps.
public enum MacSyncSession {
    public struct Configuration: Sendable {
        public var deviceID: UUID
        public var deviceName: String
        /// Folder that holds `SyncState/<device>/<vault>` (Application Support).
        public var stateRoot: URL
        public var roots: [SyncRoot]
        public var config: ScanConfig
        /// "Default for New Notes" root; used for iOS Inbox notes if it's synced.
        public var defaultRootID: UUID?
        public var now: Date
        public var timeZone: TimeZone

        public init(
            deviceID: UUID,
            deviceName: String,
            stateRoot: URL,
            roots: [SyncRoot],
            config: ScanConfig,
            defaultRootID: UUID?,
            now: Date = Date(),
            timeZone: TimeZone = .current
        ) {
            self.deviceID = deviceID
            self.deviceName = deviceName
            self.stateRoot = stateRoot
            self.roots = roots
            self.config = config
            self.defaultRootID = defaultRootID
            self.now = now
            self.timeZone = timeZone
        }
    }

    public struct Hooks: Sendable {
        public var saveOpenEditors: @Sendable () async -> Void
        /// Bulk-delete guard: return true to continue.
        public var confirmBulkTrash: @Sendable (SyncPlan) async -> Bool
        public var progress: @Sendable (SyncProgress) -> Void

        public init(
            saveOpenEditors: @escaping @Sendable () async -> Void = {},
            confirmBulkTrash: @escaping @Sendable (SyncPlan) async -> Bool = { _ in false },
            progress: @escaping @Sendable (SyncProgress) -> Void = { _ in }
        ) {
            self.saveOpenEditors = saveOpenEditors
            self.confirmBulkTrash = confirmBulkTrash
            self.progress = progress
        }
    }

    public static func run(
        connection: SyncConnection,
        configuration: Configuration,
        writer: NoteWriter,
        hooks: Hooks = Hooks()
    ) async -> SyncOutcome {
        var run = MacRun(connection: connection, configuration: configuration, writer: writer, hooks: hooks)
        do {
            let outcome = try await run.execute()
            connection.close()
            return outcome
        } catch {
            connection.close()
            if Task.isCancelled { return .cancelled }
            return .failed(SyncErrorText.describe(error, peer: run.peerName))
        }
    }
}

/// Raised inside a session when the other side aborts or breaks the protocol.
struct SessionAbort: Error {
    var message: String
}

private struct MacRun {
    let connection: SyncConnection
    let configuration: MacSyncSession.Configuration
    let writer: NoteWriter
    let hooks: MacSyncSession.Hooks

    var peerName = "iPhone or iPad"
    var rootPaths: [UUID: URL] = [:]
    var macLocations: [UUID: NoteLocation] = [:]
    var fetched: [SyncItem: Data] = [:]
    var succeeded: Set<Int> = []
    var summary = SyncSummary(peerName: "", isFirstSync: false)

    init(connection: SyncConnection, configuration: MacSyncSession.Configuration, writer: NoteWriter, hooks: MacSyncSession.Hooks) {
        self.connection = connection
        self.configuration = configuration
        self.writer = writer
        self.hooks = hooks
    }

    mutating func execute() async throws -> SyncOutcome {
        hooks.progress(.preparing)

        // 1 hello
        try await connection.send(.hello(SyncHello(
            deviceID: configuration.deviceID,
            deviceName: configuration.deviceName,
            platform: .mac
        )))
        guard case .hello(let peer) = try await receive() else { throw SessionAbort(message: "Unexpected answer.") }
        peerName = peer.deviceName
        guard peer.protocolVersion == SyncWire.protocolVersion else {
            try? await connection.send(.abort("Update Markdown Stickies on both devices."))
            throw SessionAbort(message: "Update Markdown Stickies on \(peer.deviceName).")
        }
        guard peer.platform == .ios, let vaultID = peer.vaultID else {
            throw SessionAbort(message: "\(peer.deviceName) isn't an iPhone or iPad.")
        }

        let store = SyncStateStore(directory: SyncStateStore.directory(
            in: configuration.stateRoot,
            deviceID: peer.deviceID,
            vaultID: vaultID
        ))
        let base = try store.loadBase()
        summary = SyncSummary(peerName: peer.deviceName, isFirstSync: !store.hasBase)

        // 2 prepare
        let synced = configuration.roots.filter(\.isSynced)
        for root in synced where (try? FileManager.default.contentsOfDirectory(atPath: root.url.path)) == nil {
            let message = "Folder '\(root.url.lastPathComponent)' can't be read on this Mac."
            try? await connection.send(.abort(message))
            throw SessionAbort(message: message)
        }
        let records = RootRecord.assign(existing: try store.loadRoots(), synced: synced.map { ($0.id, $0.url.path) })
        rootPaths = Dictionary(records.map { ($0.rootID, URL(fileURLWithPath: $0.macPath)) }, uniquingKeysWith: { first, _ in first })
        for root in configuration.roots { rootPaths[root.id] = root.url }

        await hooks.saveOpenEditors()
        let defaultRoot = synced.first { $0.id == configuration.defaultRootID }?.id ?? synced.first?.id
        try await connection.send(.prepare(SyncPrepare(
            macDeviceID: configuration.deviceID,
            roots: records.map { VaultInfo.RootFolder(rootID: $0.rootID, folderName: $0.iosFolderName, isSynced: $0.isSynced) },
            defaultRootID: defaultRoot,
            knownImages: base.images.keys.sorted()
        )))

        // 3 manifest
        let iosManifest = try await receiveManifest(records: records)

        // 4 plan
        let iosRefs = Set(iosManifest.notes.flatMap { note in
            note.location.rootID.map { root in note.imageRefs.map { ImageKey(rootID: root, path: $0) } } ?? []
        })
        let set = try await buildSet(base: base, extraImages: iosRefs)
        let plan = SyncPlanner.plan(
            mac: set.manifest,
            ios: iosManifest,
            base: base,
            context: SyncPlanner.Context(
                defaultRootID: defaultRoot,
                peerDeviceName: peer.deviceName,
                now: configuration.now,
                timeZone: configuration.timeZone,
                macAllows: set.allows
            )
        )
        summary.skipped = plan.skipped
        if plan.needsConfirmation {
            let hooks = self.hooks
            let confirmed = try await connection.withKeepalive { await hooks.confirmBulkTrash(plan) }
            guard confirmed else {
                try? await connection.send(.cancelled)
                return .cancelled
            }
        }

        // 5 fetch what the Mac steps need from iOS
        for item in Self.items(neededBy: plan.macSteps) {
            try await connection.send(.fetch(item))
            switch try await receive() {
            case .chunk(let first):
                var data = first.data
                if !first.isLast { data += try await connection.receiveContent() }
                if NoteHashing.fileHash(data) == Self.expectedHash(of: item, in: iosManifest) {
                    fetched[item] = data
                }
            case .unavailable:
                break   // the steps that need it are skipped below
            default:
                throw SessionAbort(message: "Unexpected answer.")
            }
        }

        // 6 apply on the Mac
        let total = plan.steps.count
        var done = 0
        macLocations = Dictionary(set.manifest.notes.map { ($0.id, $0.location) }, uniquingKeysWith: { first, _ in first })
        for step in plan.macSteps {
            if let reason = await applyOnMac(step, store: store) {
                summary.failedSteps.append(SyncFailedStep(device: .mac, action: step.action, reason: reason))
            } else {
                succeeded.insert(step.id)
                count(step.action)
            }
            done += 1
            hooks.progress(.syncing(done: done, total: total))
        }

        // 7–8 iOS steps, built from the Mac results: a step whose prerequisite failed isn't sent
        for step in plan.iosSteps {
            defer {
                done += 1
                hooks.progress(.syncing(done: done, total: total))
            }
            guard step.dependsOn.allSatisfy(succeeded.contains) else {
                summary.failedSteps.append(SyncFailedStep(device: .ios, action: step.action, reason: "an earlier step didn't run"))
                continue
            }
            var content: Data?
            if step.action.carriesContent {
                guard let data = macContent(for: step.action) else {
                    summary.failedSteps.append(SyncFailedStep(device: .ios, action: step.action, reason: "couldn't read the file on this Mac"))
                    continue
                }
                content = data
            }
            try await connection.send(.step(step))
            if let content { try await connection.sendContent(content) }
            guard case .stepResult(let result) = try await receive(), result.stepID == step.id else {
                throw SessionAbort(message: "Unexpected answer.")
            }
            switch result.outcome {
            case .done:
                succeeded.insert(step.id)
                count(step.action)
            case .skipped(let reason):
                summary.failedSteps.append(SyncFailedStep(device: .ios, action: step.action, reason: reason))
            }
        }

        // 9 commit, from what both devices really have now
        hooks.progress(.finishing)
        try await connection.send(.rescan)
        let iosAfter = try await receiveManifest(records: records)
        let after = try await buildSet(base: base, extraImages: iosRefs)
        let next = SyncCommit.nextBase(
            previous: base,
            macNotes: after.manifest.notes,
            iosNotes: iosAfter.notes,
            macImages: after.manifest.images,
            iosImages: iosAfter.images,
            frozenNoteIDs: plan.frozenNoteIDs,
            frozenImages: plan.frozenImages
        )
        for (id, entry) in next.notes where base.notes[id] != entry {
            if let url = after.url(for: entry.location), let data = try? Data(contentsOf: url),
               NoteHashing.fileHash(data) == entry.fileHash {
                try? store.saveBaseText(data, for: id)
            }
        }
        for id in base.notes.keys where next.notes[id] == nil {
            store.removeBaseText(for: id)
        }
        try store.saveBase(next)
        try store.saveRoots(records)
        store.pruneConflictBases(keeping: Set(after.manifest.notes.map(\.id)))

        // 10 summary
        try await connection.send(.summary(summary))
        return .completed(summary)
    }

    // MARK: - Steps

    /// Runs one Mac step. Returns `nil` on success, otherwise why it didn't run.
    private mutating func applyOnMac(_ step: SyncStep, store: SyncStateStore) async -> String? {
        guard step.dependsOn.allSatisfy(succeeded.contains) else { return "an earlier step didn't run" }
        do {
            switch step.action {
            case .writeNote(let id, let at, let expect, let source):
                guard let data = iosContent(source) else { return "couldn't get the file from \(peerName)" }
                try writer.write(data, to: try noteURL(at), expect: expect, origin: .sync)
                macLocations[id] = at

            case .writeConflictCopy(let id, let original, let at, _):
                guard let data = fetched[.note(original)] else { return "couldn't get the file from \(peerName)" }
                var copy = StickiesFrontmatter.setting(StickiesFrontmatter.idKey, to: id.uuidString, in: data)
                copy = StickiesFrontmatter.setting(StickiesFrontmatter.conflictOfKey, to: original.uuidString, in: copy)
                try writer.write(copy, to: try noteURL(at), expect: .absent, origin: .sync)
                macLocations[id] = at
                try? store.snapshotConflictBase(copy: id, original: original)
                summary.conflicts.append(SyncConflictRecord(copyID: id, originalID: original))

            case .moveNote(let id, let from, let to, let hash):
                try writer.move(from: try noteURL(from), to: try noteURL(to), expectHash: hash, origin: .sync)
                macLocations[id] = to

            case .trashNote(let id, let at, let hash):
                try writer.trash(try noteURL(at), expectHash: hash, origin: .sync)
                macLocations[id] = nil

            case .writeImage(let key, let expect, let source):
                guard let data = iosContent(source) else { return "couldn't get the image from \(peerName)" }
                try writer.write(data, to: try imageURL(key), expect: expect, origin: .sync)

            case .trashImage:
                return "images are never trashed on the Mac"
            }
            return nil
        } catch {
            return SyncErrorText.stepReason(error)
        }
    }

    private func iosContent(_ source: SyncContentSource) -> Data? {
        switch source {
        case .iosNote(let id): return fetched[.note(id)]
        case .iosImage(let key): return fetched[.image(key)]
        default: return nil
        }
    }

    /// Bytes the Mac sends for an iOS write: its file as it is now, after the Mac steps.
    private func macContent(for action: SyncAction) -> Data? {
        switch action {
        case .writeNote(_, _, _, .macNote(let id)):
            guard let location = macLocations[id], let url = try? noteURL(location) else { return nil }
            return try? Data(contentsOf: url)
        case .writeImage(_, _, .macImage(let key)):
            guard let url = try? imageURL(key) else { return nil }
            return try? Data(contentsOf: url)
        default:
            return nil
        }
    }

    private mutating func count(_ action: SyncAction) {
        switch action {
        case .writeNote(_, _, .hash, _): summary.updated += 1
        case .writeNote(_, _, .absent, _): summary.created += 1
        case .writeConflictCopy: summary.conflictCopies += 1
        case .moveNote: summary.moved += 1
        case .trashNote: summary.trashed += 1
        case .writeImage, .trashImage: break
        }
    }

    // MARK: - Helpers

    private func receive() async throws -> SyncMessage {
        let message = try await connection.receiveSkippingKeepalives()
        switch message {
        case .abort(let reason): throw SessionAbort(message: reason)
        case .cancelled: throw SessionAbort(message: "Sync cancelled on \(peerName).")
        default: return message
        }
    }

    private func receiveManifest(records: [RootRecord]) async throws -> SyncManifest {
        guard case .manifest(let manifest) = try await receive() else { throw SessionAbort(message: "Unexpected answer.") }
        return Self.sanitized(manifest, knownRoots: Set(records.map(\.rootID)))
    }

    private func buildSet(base: SyncBase, extraImages: Set<ImageKey>) async throws -> MacSyncSet {
        let configuration = self.configuration
        let rootPaths = self.rootPaths
        return try await connection.withKeepalive {
            SyncSetBuilder.build(
                roots: configuration.roots,
                rootPaths: rootPaths,
                config: configuration.config,
                base: base,
                extraImages: extraImages
            )
        }
    }

    private func noteURL(_ location: NoteLocation) throws -> URL {
        guard let rootID = location.rootID, let root = rootPaths[rootID],
              case .success(let url) = PathRules.resolve(location.path, as: .note, in: root)
        else { throw SessionAbort(message: "invalid location") }
        return url
    }

    private func imageURL(_ key: ImageKey) throws -> URL {
        guard let root = rootPaths[key.rootID],
              case .success(let url) = PathRules.resolve(key.path, as: .image, in: root)
        else { throw SessionAbort(message: "invalid location") }
        return url
    }

    /// Drops entries with invalid paths or unknown roots (§3.7: every incoming path is checked).
    static func sanitized(_ manifest: SyncManifest, knownRoots: Set<UUID>) -> SyncManifest {
        func valid(_ location: NoteLocation) -> Bool {
            if let rootID = location.rootID {
                guard knownRoots.contains(rootID) else { return false }
            } else if location.path.contains("/") {
                return false
            }
            if case .success = PathRules.validate(location.path, as: .note) { return true }
            return false
        }
        var clean = manifest
        clean.notes = manifest.notes.filter { valid($0.location) }
        clean.unreadable = manifest.unreadable.filter(valid)
        clean.left = []
        clean.images = manifest.images.filter { image in
            guard knownRoots.contains(image.key.rootID) else { return false }
            if case .success = PathRules.validate(image.key.path, as: .image) { return true }
            return false
        }
        return clean
    }

    static func items(neededBy steps: [SyncStep]) -> [SyncItem] {
        var items: [SyncItem] = []
        for step in steps {
            let item: SyncItem?
            switch step.action {
            case .writeNote(_, _, _, .iosNote(let id)): item = .note(id)
            case .writeConflictCopy(_, let original, _, _): item = .note(original)
            case .writeImage(_, _, .iosImage(let key)): item = .image(key)
            default: item = nil
            }
            if let item, !items.contains(item) { items.append(item) }
        }
        return items
    }

    static func expectedHash(of item: SyncItem, in manifest: SyncManifest) -> String? {
        switch item {
        case .note(let id): return manifest.notes.first { $0.id == id }?.fileHash
        case .image(let key): return manifest.images.first { $0.key == key }?.hash
        }
    }
}

// MARK: - iOS

/// The iOS side of a sync: reports the vault and carries out the Mac's steps.
public enum IOSSyncResponder {
    public struct Configuration: Sendable {
        public var deviceID: UUID
        public var deviceName: String
        public var vault: URL
        /// App-owned folder for the vault info (see `VaultScanner.infoURL`).
        public var storage: URL

        public init(deviceID: UUID, deviceName: String, vault: URL, storage: URL) {
            self.deviceID = deviceID
            self.deviceName = deviceName
            self.vault = vault.standardizedFileURL
            self.storage = storage
        }
    }

    public struct Hooks: Sendable {
        public var saveOpenEditors: @Sendable () async -> Void
        /// Called after each step that ran, so an open editor can reload, follow a move or close.
        public var stepApplied: @Sendable (SyncAction) async -> Void
        public var progress: @Sendable (SyncProgress) -> Void

        public init(
            saveOpenEditors: @escaping @Sendable () async -> Void = {},
            stepApplied: @escaping @Sendable (SyncAction) async -> Void = { _ in },
            progress: @escaping @Sendable (SyncProgress) -> Void = { _ in }
        ) {
            self.saveOpenEditors = saveOpenEditors
            self.stepApplied = stepApplied
            self.progress = progress
        }
    }

    public static func run(
        connection: SyncConnection,
        configuration: Configuration,
        writer: NoteWriter,
        hooks: Hooks = Hooks()
    ) async -> SyncOutcome {
        var peerName = "the Mac"
        do {
            let vault = configuration.vault
            let storage = configuration.storage
            var info = try VaultScanner.loadOrCreateInfo(vault: vault, storage: storage)
            hooks.progress(.preparing)

            try await connection.send(.hello(SyncHello(
                deviceID: configuration.deviceID,
                deviceName: configuration.deviceName,
                platform: .ios,
                vaultID: info.vaultID
            )))
            guard case .hello(let mac) = try await receive(connection, peer: peerName) else {
                throw SessionAbort(message: "Unexpected answer.")
            }
            peerName = mac.deviceName
            guard mac.protocolVersion == SyncWire.protocolVersion, mac.platform == .mac else {
                try? await connection.send(.abort("Update Markdown Stickies on both devices."))
                throw SessionAbort(message: "Update Markdown Stickies on \(mac.deviceName).")
            }

            guard case .prepare(let prepare) = try await receive(connection, peer: peerName) else {
                throw SessionAbort(message: "Unexpected answer.")
            }
            do {
                info = try VaultScanner.applyingRoots(prepare.roots, to: info, vault: vault)
            } catch VaultScanner.Failure.missingRootFolder(let name) {
                let message = "Folder '\(name)' is missing on \(configuration.deviceName). Restore it in the Files app, or choose Settings → Start Fresh on \(configuration.deviceName). Don't recreate it empty: that counts as deleting its notes."
                try? await connection.send(.abort(message))
                throw SessionAbort(message: message)
            }
            info.macDeviceID = prepare.macDeviceID
            try VaultScanner.saveInfo(info, vault: vault, storage: storage)

            await hooks.saveOpenEditors()
            let knownImages = Set(prepare.knownImages)
            let currentInfo = info
            var manifest = try await connection.withKeepalive {
                try VaultScanner.scan(vault: vault, info: currentInfo, knownImages: knownImages)
            }
            try await connection.send(.manifest(manifest))

            var done = 0
            while true {
                switch try await receive(connection, peer: peerName) {
                case .fetch(let item):
                    if let url = url(for: item, manifest: manifest, vault: vault, info: info),
                       let data = try? Data(contentsOf: url) {
                        try await connection.sendContent(data)
                    } else {
                        try await connection.send(.unavailable("not found"))
                    }

                case .step(let step):
                    let content = step.action.carriesContent ? try await connection.receiveContent() : nil
                    let outcome = await apply(step.action, content: content, writer: writer, vault: vault, info: info)
                    try await connection.send(.stepResult(SyncStepResult(stepID: step.id, outcome: outcome)))
                    if outcome == .done { await hooks.stepApplied(step.action) }
                    done += 1
                    hooks.progress(.syncing(done: done, total: done))

                case .rescan:
                    hooks.progress(.finishing)
                    manifest = try await connection.withKeepalive {
                        try VaultScanner.scan(vault: vault, info: currentInfo, knownImages: knownImages)
                    }
                    try await connection.send(.manifest(manifest))

                case .summary(let summary):
                    connection.close()
                    return .completed(summary)

                default:
                    throw SessionAbort(message: "Unexpected message.")
                }
            }
        } catch {
            connection.close()
            if Task.isCancelled { return .cancelled }
            if let abort = error as? SessionAbort, abort.message.hasPrefix("Sync cancelled") { return .cancelled }
            return .failed(SyncErrorText.describe(error, peer: peerName))
        }
    }

    private static func receive(_ connection: SyncConnection, peer: String) async throws -> SyncMessage {
        let message = try await connection.receiveSkippingKeepalives()
        switch message {
        case .abort(let reason): throw SessionAbort(message: reason)
        case .cancelled: throw SessionAbort(message: "Sync cancelled on \(peer).")
        default: return message
        }
    }

    private static func url(for item: SyncItem, manifest: SyncManifest, vault: URL, info: VaultInfo) -> URL? {
        switch item {
        case .note(let id):
            guard let location = manifest.notes.first(where: { $0.id == id })?.location else { return nil }
            return try? noteURL(location, vault: vault, info: info)
        case .image(let key):
            return try? imageURL(key, vault: vault, info: info)
        }
    }

    private static func apply(
        _ action: SyncAction,
        content: Data?,
        writer: NoteWriter,
        vault: URL,
        info: VaultInfo
    ) async -> SyncStepOutcome {
        do {
            switch action {
            case .writeNote(_, let at, let expect, _):
                try writer.write(content ?? Data(), to: try noteURL(at, vault: vault, info: info), expect: expect, origin: .sync)
            case .moveNote(_, let from, let to, let hash):
                try writer.move(
                    from: try noteURL(from, vault: vault, info: info),
                    to: try noteURL(to, vault: vault, info: info),
                    expectHash: hash,
                    origin: .sync
                )
            case .trashNote(_, let at, let hash):
                try writer.trash(try noteURL(at, vault: vault, info: info), expectHash: hash, origin: .sync)
            case .writeImage(let key, let expect, _):
                try writer.write(content ?? Data(), to: try imageURL(key, vault: vault, info: info), expect: expect, origin: .sync)
            case .trashImage(let key, let hash):
                try writer.trash(try imageURL(key, vault: vault, info: info), expectHash: hash, origin: .sync)
            case .writeConflictCopy:
                return .skipped("conflict copies are only made on the Mac")
            }
            return .done
        } catch {
            return .skipped(SyncErrorText.stepReason(error))
        }
    }

    /// Paths from the Mac are checked too (§3.7).
    static func noteURL(_ location: NoteLocation, vault: URL, info: VaultInfo) throws -> URL {
        if location.rootID == nil {
            guard !location.path.contains("/"), case .success = PathRules.validate(location.path, as: .note) else {
                throw SessionAbort(message: "invalid location")
            }
            return vault.appendingPathComponent(location.path)
        }
        guard let folder = info.roots.first(where: { $0.rootID == location.rootID })?.folderName,
              case .success(let url) = PathRules.resolve(location.path, as: .note, in: vault.appendingPathComponent(folder, isDirectory: true))
        else { throw SessionAbort(message: "invalid location") }
        return url
    }

    static func imageURL(_ key: ImageKey, vault: URL, info: VaultInfo) throws -> URL {
        guard let folder = info.roots.first(where: { $0.rootID == key.rootID })?.folderName,
              case .success(let url) = PathRules.resolve(key.path, as: .image, in: vault.appendingPathComponent(folder, isDirectory: true))
        else { throw SessionAbort(message: "invalid location") }
        return url
    }
}

// MARK: - Error texts

enum SyncErrorText {
    static func describe(_ error: Error, peer: String) -> String {
        switch error {
        case let abort as SessionAbort:
            return abort.message
        case SyncTransportError.timedOut:
            return "\(peer) stopped responding. Make sure both apps are open on the same Wi-Fi."
        case SyncTransportError.closed:
            return "The connection to \(peer) was closed."
        case SyncTransportError.malformed:
            return "Update Markdown Stickies on both devices."
        case let failure as VaultScanner.Failure:
            switch failure {
            case .vaultUnreadable: return "The notes folder can't be read. Choose it again in Settings."
            case .missingRootFolder(let name): return "Folder '\(name)' is missing."
            }
        default:
            return error.localizedDescription
        }
    }

    static func stepReason(_ error: Error) -> String {
        switch error {
        case NoteWriter.Failure.changedOnDisk: return "the file changed during the sync"
        case NoteWriter.Failure.missing: return "the file is gone"
        case NoteWriter.Failure.alreadyExists: return "a file with that name already exists"
        case NoteWriter.Failure.unsavedEdits: return "the note has unsaved edits"
        case NoteWriter.Failure.io(let text): return text
        case let abort as SessionAbort: return abort.message
        default: return error.localizedDescription
        }
    }
}
