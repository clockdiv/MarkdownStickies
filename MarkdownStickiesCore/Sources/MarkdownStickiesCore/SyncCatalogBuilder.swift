import Foundation

/// Build / apply sync payloads against on-disk markdown files.
public enum SyncCatalogBuilder {
    /// Reads a note file into a payload, ensuring a frontmatter sync ID (writes back if added).
    /// Does **not** stamp `folder` / `title` into the file (those fought across devices).
    public static func payload(fromFile url: URL, titleHint: String? = nil, roots: [URL] = []) throws -> SyncNotePayload? {
        _ = roots
        let values = try url.resourceValues(forKeys: [.contentModificationDateKey])
        let previousModified = values.contentModificationDate ?? Date.distantPast

        let raw = try String(contentsOf: url, encoding: .utf8)
        let ensured = NoteFrontmatter.ensuringSyncID(raw)
        let text = ensured.markdown

        if ensured.didChange {
            try text.write(to: url, atomically: true, encoding: .utf8)
            // Pure id stamp → restore previous mtime so id-injection alone does not win merges.
            try FileManager.default.setAttributes(
                [.modificationDate: previousModified],
                ofItemAtPath: url.path
            )
        }

        let title = titleHint
            ?? NoteFilename.parse(url: url, modifiedAt: previousModified)?.title
            ?? url.deletingPathExtension().lastPathComponent
        return SyncNotePayload(
            id: ensured.id,
            title: title,
            modifiedAt: previousModified,
            body: text
        )
    }

    /// Wire catalog: active notes only. Trash and conflict siblings never leave this device.
    public static func catalog(roots: [URL], config: ScanConfig = .empty) -> [SyncNotePayload] {
        payloadsOnDisk(roots: roots, config: config, includeTrash: false)
    }

    /// Local decide/apply index — includes Trash so a locally trashed note is not resurrected.
    public static func localIndexForApply(roots: [URL], config: ScanConfig = .empty) -> [SyncNotePayload] {
        payloadsOnDisk(roots: roots, config: config, includeTrash: true)
    }

    private static func payloadsOnDisk(
        roots: [URL],
        config: ScanConfig,
        includeTrash: Bool
    ) -> [SyncNotePayload] {
        let notes = NoteScanner.scan(roots: roots, config: config)
        var byID: [UUID: SyncNotePayload] = [:]
        for note in notes {
            guard !SyncDebugLog.isDebugNote(url: note.path) else { continue }
            if !includeTrash, NoteFrontmatter.isTrashed(file: note.path) { continue }
            guard let payload = try? payload(fromFile: note.path, titleHint: note.title, roots: roots) else {
                continue
            }
            // Keep-both siblings stay on the merge Mac only.
            if NoteFrontmatter.isConflictSibling(payload.body) { continue }
            if !includeTrash, NoteFrontmatter.isTrashFolder(NoteFrontmatter.folder(in: payload.body)) {
                continue
            }
            if let existing = byID[payload.id] {
                if payload.modifiedAt >= existing.modifiedAt {
                    byID[payload.id] = payload
                }
            } else {
                byID[payload.id] = payload
            }
        }
        return Array(byID.values)
    }

    /// Map sync IDs → file URLs for notes under `roots`.
    /// Duplicate ids keep the newer file’s path.
    public static func pathIndex(roots: [URL], config: ScanConfig = .empty) -> [UUID: URL] {
        var index: [UUID: URL] = [:]
        var mtimes: [UUID: Date] = [:]
        for note in NoteScanner.scan(roots: roots, config: config) {
            guard !SyncDebugLog.isDebugNote(url: note.path) else { continue }
            guard let text = try? String(contentsOf: note.path, encoding: .utf8),
                  let id = NoteFrontmatter.syncID(in: text)
            else { continue }
            let mtime = note.modifiedAt
            if let prev = mtimes[id], prev > mtime { continue }
            mtimes[id] = mtime
            index[id] = note.path.standardizedFileURL
        }
        return index
    }

    /// Writes remote payload body to `existingPath`, or creates under `createDirectory`
    /// (or `{createDirectory}/Trash` when frontmatter `folder` indicates trash).
    /// Moves between active ↔ Trash when the peer’s folder metadata says so.
    @discardableResult
    public static func writeBody(
        _ payload: SyncNotePayload,
        existingPath: URL?,
        createDirectory: URL
    ) throws -> URL {
        let fm = FileManager.default
        var body = NoteFrontmatter.ensuringSyncID(payload.body, id: payload.id).markdown
        // Do not stamp `title` into the body — filename is the source of truth.
        // `created_on` travels with the body (no local-preserve override).

        let wantsTrash = NoteFrontmatter.isTrashFolder(NoteFrontmatter.folder(in: body))
        let preferredDir: URL
        if wantsTrash {
            preferredDir = try NoteFrontmatter.trashDirectory(in: createDirectory)
            // Keep a stable trash marker (`Trash`), not a vault-local path.
            if !NoteFrontmatter.isTrashFolder(NoteFrontmatter.folder(in: body)) {
                body = NoteFrontmatter.settingFolder(NoteFrontmatter.trashFolderName, in: body)
            }
        } else if let existingPath, !NoteFrontmatter.isTrashed(file: existingPath) {
            preferredDir = existingPath.deletingLastPathComponent()
        } else {
            preferredDir = createDirectory.standardizedFileURL
        }

        let target: URL
        if let existingPath {
            var current = existingPath.standardizedFileURL
            let currentDir = current.deletingLastPathComponent().standardizedFileURL
            if currentDir != preferredDir.standardizedFileURL {
                try fm.createDirectory(at: preferredDir, withIntermediateDirectories: true)
                var dest = preferredDir.appendingPathComponent(current.lastPathComponent)
                if fm.fileExists(atPath: dest.path), dest.standardizedFileURL != current {
                    let stem = dest.deletingPathExtension().lastPathComponent
                    var index = 2
                    repeat {
                        dest = preferredDir.appendingPathComponent("\(stem)-\(index).md")
                        index += 1
                    } while fm.fileExists(atPath: dest.path)
                }
                try fm.moveItem(at: current, to: dest)
                current = dest.standardizedFileURL
            }
            let onDisk = try? String(contentsOf: current, encoding: .utf8)
            if onDisk != body {
                try body.write(to: current, atomically: true, encoding: .utf8)
            }
            target = current
        } else {
            target = NoteFilename.uniqueURL(
                in: preferredDir,
                date: payload.modifiedAt,
                title: payload.title
            ).standardizedFileURL
            try body.write(to: target, atomically: true, encoding: .utf8)
        }

        try fm.setAttributes(
            [.modificationDate: payload.modifiedAt],
            ofItemAtPath: target.path
        )
        return target
    }

    /// Writes remote payload: overwrite existing path for that ID, or create under `createDirectory`.
    /// Renames the file when `payload.title` doesn’t match the current filename.
    /// Returns nil only when body and filename are already in sync (no user-visible change).
    @discardableResult
    public static func apply(
        _ payload: SyncNotePayload,
        existingPath: URL?,
        createDirectory: URL
    ) throws -> URL? {
        let before = existingPath?.standardizedFileURL
        let beforeBody = before.flatMap { try? String(contentsOf: $0, encoding: .utf8) }

        let written = try writeBody(
            payload,
            existingPath: existingPath,
            createDirectory: createDirectory
        )
        let final = try finalizeRename(
            from: written,
            namingSource: written,
            title: payload.title,
            modifiedAt: payload.modifiedAt,
            ignoringOccupiedPaths: []
        )

        let afterBody = try? String(contentsOf: final, encoding: .utf8)
        let didChange = before != final || beforeBody != afterBody
        return didChange ? final : nil
    }

    /// Result of applying a remote catalog.
    public struct ApplyResult: Equatable, Sendable {
        public var appliedIDs: [UUID]
        public var appliedPaths: [URL]
        public var conflicts: [SyncConflict]
        public var awaitingAuthorityMerge: [SyncConflict]

        public var count: Int { appliedIDs.count }

        public init(
            appliedIDs: [UUID] = [],
            appliedPaths: [URL] = [],
            conflicts: [SyncConflict] = [],
            awaitingAuthorityMerge: [SyncConflict] = []
        ) {
            self.appliedIDs = appliedIDs
            self.appliedPaths = appliedPaths
            self.conflicts = conflicts
            self.awaitingAuthorityMerge = awaitingAuthorityMerge
        }
    }

    /// Apply merge decisions for a remote catalog.
    /// Renames use a two-phase move so A↔B filename swaps cannot collide mid-apply.
    /// On the merge authority (Mac), divergent bodies keep both (sibling for merge UI).
    /// On a satellite (iOS), divergent bodies keep local only — Mac merges later.
    @discardableResult
    public static func applyRemoteCatalog(
        _ remote: [SyncNotePayload],
        roots: [URL],
        createDirectory: URL,
        peerLabel: String? = nil,
        conflictRole: SyncMerge.ConflictRole = .mergeAuthority
    ) throws -> ApplyResult {
        let label = normalizedPeerLabel(peerLabel)
        let localByID = Dictionary(
            uniqueKeysWithValues: localIndexForApply(roots: roots).map { ($0.id, $0) }
        )
        let paths = pathIndex(roots: roots)
        // Include keep-both siblings so re-sync does not mint duplicates (they are omitted
        // from `catalog` / wire payloads on purpose).
        var localFingerprints = contentFingerprintsOnDisk(roots: roots)

        struct Planned {
            let payload: SyncNotePayload
            let existingPath: URL?
            let localBody: String?
        }

        var planned: [Planned] = []
        var conflicts: [SyncConflict] = []
        var awaitingAuthorityMerge: [SyncConflict] = []

        // Trash never syncs — ignore peer trash payloads entirely.
        let remoteActive = remote.filter {
            !NoteFrontmatter.isTrashFolder(NoteFrontmatter.folder(in: $0.body))
        }

        for decision in SyncMerge.decisions(localByID: localByID, remote: remoteActive) {
            switch decision {
            case .keepLocal:
                continue
            case .applyRemote(let payload):
                let existing = paths[payload.id]
                planned.append(Planned(
                    payload: payload,
                    existingPath: existing,
                    localBody: existing.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
                ))
            case .conflict(let local, let remotePayload):
                switch conflictRole {
                case .satellite:
                    // Keep local only — do not ACK as "written" (avoids inflated sent counts).
                    awaitingAuthorityMerge.append(
                        SyncConflict(
                            id: local.id,
                            local: local,
                            remote: remotePayload,
                            remoteCopyID: remotePayload.id,
                            remoteCopyPath: nil,
                            peerLabel: label
                        )
                    )
                case .mergeAuthority:
                    // Always surface a conflict for UI — even if the peer body is already on
                    // disk as a keep-both sibling. Skipping that made Mac say “Synced” while
                    // iOS correctly said “Waiting for Mac”.
                    let conflict = try preserveConflict(
                        local: local,
                        remote: remotePayload,
                        roots: roots,
                        localFingerprints: &localFingerprints,
                        createDirectory: createDirectory,
                        peerLabel: label
                    )
                    conflicts.append(conflict)
                    // Sibling is local-only (conflict_sibling) — do not ACK as received/sent.
                }
            }
        }

        if planned.isEmpty {
            return ApplyResult(
                appliedIDs: [],
                appliedPaths: [],
                conflicts: conflicts,
                awaitingAuthorityMerge: awaitingAuthorityMerge
            )
        }

        let fm = FileManager.default

        // Phase 1: write all bodies in place (or create new files).
        var currentByID: [UUID: URL] = [:]
        var namingSourceByID: [UUID: URL] = [:]
        for item in planned {
            let url = try writeBody(
                item.payload,
                existingPath: item.existingPath,
                createDirectory: createDirectory
            )
            currentByID[item.payload.id] = url
            namingSourceByID[item.payload.id] = url
        }

        // Paths this batch will vacate (ignored as collisions in phase 3).
        let vacated: Set<String> = Set(
            planned.compactMap { item -> String? in
                guard let existing = item.existingPath?.standardizedFileURL else { return nil }
                let desired = desiredURL(
                    namingSource: existing,
                    title: item.payload.title,
                    ignoringOccupiedPaths: []
                )
                // Ideal name without ignore — if different from existing, path is vacated.
                if desired.standardizedFileURL != existing {
                    return existing.path
                }
                return nil
            }
        )

        // Also treat every existing path in this batch as vacated for swap safety.
        let vacatedAll: Set<String> = vacated.union(
            Set(planned.compactMap { $0.existingPath?.standardizedFileURL.path })
        )

        // Phase 2: stage renames onto temps so A↔B swaps never collide.
        for item in planned {
            guard let current = currentByID[item.payload.id],
                  let namingSource = namingSourceByID[item.payload.id]
            else { continue }

            let desired = desiredURL(
                namingSource: namingSource,
                title: item.payload.title,
                ignoringOccupiedPaths: vacatedAll
            )
            if desired.standardizedFileURL == current.standardizedFileURL {
                continue
            }

            let temp = current
                .deletingLastPathComponent()
                .appendingPathComponent(".mdstickies-sync-\(item.payload.id.uuidString).md")
            if fm.fileExists(atPath: temp.path) {
                try fm.removeItem(at: temp)
            }
            try fm.moveItem(at: current, to: temp)
            currentByID[item.payload.id] = temp
        }

        // Phase 3: move onto final titles.
        var appliedIDs: [UUID] = []
        var appliedPaths: [URL] = []

        for item in planned {
            guard let current = currentByID[item.payload.id],
                  let namingSource = namingSourceByID[item.payload.id]
            else { continue }

            let final = try finalizeRename(
                from: current,
                namingSource: namingSource,
                title: item.payload.title,
                modifiedAt: item.payload.modifiedAt,
                ignoringOccupiedPaths: vacatedAll
            )
            currentByID[item.payload.id] = final

            let afterBody = try? String(contentsOf: final, encoding: .utf8)
            let pathChanged = item.existingPath?.standardizedFileURL != final
            let bodyChanged = item.localBody != afterBody
            if pathChanged || bodyChanged {
                appliedIDs.append(item.payload.id)
                appliedPaths.append(final)
            }
        }

        return ApplyResult(
            appliedIDs: appliedIDs,
            appliedPaths: appliedPaths,
            conflicts: conflicts,
            awaitingAuthorityMerge: awaitingAuthorityMerge
        )
    }

    /// Fingerprints of every on-disk note under `roots`, including local-only conflict siblings.
    private static func contentFingerprintsOnDisk(roots: [URL]) -> Set<String> {
        var fingerprints = Set<String>()
        for note in NoteScanner.scan(roots: roots) {
            guard !SyncDebugLog.isDebugNote(url: note.path) else { continue }
            guard let text = try? String(contentsOf: note.path, encoding: .utf8) else { continue }
            fingerprints.insert(NoteFrontmatter.contentFingerprint(text))
        }
        return fingerprints
    }

    /// Keep local; ensure remote body exists as a local-only sibling for merge UI.
    /// Always returns a conflict — reuses an existing sibling when the fingerprint is already present.
    private static func preserveConflict(
        local: SyncNotePayload,
        remote: SyncNotePayload,
        roots: [URL],
        localFingerprints: inout Set<String>,
        createDirectory: URL,
        peerLabel: String
    ) throws -> SyncConflict {
        let remoteFingerprint = NoteFrontmatter.contentFingerprint(remote.body)
        if localFingerprints.contains(remoteFingerprint),
           let existing = findSiblingFile(
            matchingFingerprint: remoteFingerprint,
            primaryID: local.id,
            roots: roots
           ) {
            let text = (try? String(contentsOf: existing, encoding: .utf8)) ?? remote.body
            let copyID = NoteFrontmatter.syncID(in: text) ?? remote.id
            return SyncConflict(
                id: local.id,
                local: local,
                remote: remote,
                remoteCopyID: copyID,
                remoteCopyPath: existing,
                peerLabel: peerLabel
            )
        }

        let newID = UUID()
        let siblingTitle = "\(remote.title) (from \(peerLabel))"
        var siblingBody = NoteFrontmatter.settingSyncID(newID, in: remote.body)
        siblingBody = NoteFrontmatter.markingConflictSibling(local.id, in: siblingBody)
        let sibling = SyncNotePayload(
            id: newID,
            title: siblingTitle,
            modifiedAt: remote.modifiedAt,
            body: siblingBody
        )
        let path = try writeBody(sibling, existingPath: nil, createDirectory: createDirectory)
        let final = try finalizeRename(
            from: path,
            namingSource: path,
            title: siblingTitle,
            modifiedAt: remote.modifiedAt,
            ignoringOccupiedPaths: []
        )
        localFingerprints.insert(NoteFrontmatter.contentFingerprint(siblingBody))
        return SyncConflict(
            id: local.id,
            local: local,
            remote: remote,
            remoteCopyID: newID,
            remoteCopyPath: final,
            peerLabel: peerLabel
        )
    }

    /// Locate an on-disk keep-both copy of `fingerprint` (prefer marked conflict siblings).
    private static func findSiblingFile(
        matchingFingerprint fingerprint: String,
        primaryID: UUID,
        roots: [URL]
    ) -> URL? {
        var fallback: URL?
        for note in NoteScanner.scan(roots: roots) {
            guard !SyncDebugLog.isDebugNote(url: note.path) else { continue }
            guard let text = try? String(contentsOf: note.path, encoding: .utf8) else { continue }
            guard NoteFrontmatter.contentFingerprint(text) == fingerprint else { continue }
            if let id = NoteFrontmatter.syncID(in: text), id == primaryID { continue }
            if NoteFrontmatter.isConflictSibling(text) {
                return note.path.standardizedFileURL
            }
            fallback = note.path.standardizedFileURL
        }
        return fallback
    }

    private static func normalizedPeerLabel(_ raw: String?) -> String {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "peer" : trimmed
    }

    // MARK: - Private

    private static func finalizeRename(
        from current: URL,
        namingSource: URL,
        title: String,
        modifiedAt: Date,
        ignoringOccupiedPaths: Set<String>
    ) throws -> URL {
        let desired = desiredURL(
            namingSource: namingSource,
            title: title,
            ignoringOccupiedPaths: ignoringOccupiedPaths
        ).standardizedFileURL
        let currentStandard = current.standardizedFileURL
        if desired == currentStandard {
            try FileManager.default.setAttributes(
                [.modificationDate: modifiedAt],
                ofItemAtPath: current.path
            )
            return currentStandard
        }

        let fm = FileManager.default
        var destination = desired
        if fm.fileExists(atPath: destination.path),
           destination != currentStandard,
           !ignoringOccupiedPaths.contains(destination.path) {
            // Unexpected occupant outside this batch — fall back to collision-safe name.
            destination = NoteFilename.uniqueRenamedURL(from: namingSource, newTitle: title)
                .standardizedFileURL
        }
        if destination != currentStandard {
            if fm.fileExists(atPath: destination.path), destination != currentStandard {
                try fm.removeItem(at: destination)
            }
            try fm.moveItem(at: current, to: destination)
        }
        try fm.setAttributes(
            [.modificationDate: modifiedAt],
            ofItemAtPath: destination.path
        )
        return destination
    }

    /// Ideal rename URL using `namingSource` for date-prefix, ignoring vacated paths.
    private static func desiredURL(
        namingSource: URL,
        title: String,
        ignoringOccupiedPaths: Set<String>
    ) -> URL {
        let directory = namingSource.deletingLastPathComponent()
        let slug = NoteFilename.slugify(title)
        let datePart = NoteFilename.datePrefix(from: namingSource)
        let currentStandard = namingSource.standardizedFileURL

        func candidate(_ slugVariant: String) -> URL {
            if let datePart {
                return directory.appendingPathComponent("\(datePart)-\(slugVariant).md")
            }
            return directory.appendingPathComponent("\(slugVariant).md")
        }

        var url = candidate(slug)
        if url.standardizedFileURL == currentStandard {
            return namingSource
        }
        var index = 2
        while FileManager.default.fileExists(atPath: url.path),
              url.standardizedFileURL != currentStandard,
              !ignoringOccupiedPaths.contains(url.standardizedFileURL.path) {
            url = candidate("\(slug)-\(index)")
            index += 1
        }
        return url
    }
}
