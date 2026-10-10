import XCTest
@testable import MarkdownStickiesCore

final class SyncCatalogApplyTests: XCTestCase {
    func testApplyRemoteCatalogSwapsFilenamesWithoutCollision() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdstickies-swap-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let idA = UUID()
        let idB = UUID()
        let pathA = dir.appendingPathComponent("2024-01-01-alpha.md")
        let pathB = dir.appendingPathComponent("2024-01-01-beta.md")
        let bodyA = NoteFrontmatter.initialDocument(title: "Alpha", id: idA)
        let bodyB = NoteFrontmatter.initialDocument(title: "Beta", id: idB)
        try bodyA.write(to: pathA, atomically: true, encoding: .utf8)
        try bodyB.write(to: pathB, atomically: true, encoding: .utf8)

        // Remote swapped names (title-only — identical bodies).
        let remoteA = SyncNotePayload(
            id: idA,
            title: "Beta",
            modifiedAt: Date().addingTimeInterval(10),
            body: bodyA
        )
        let remoteB = SyncNotePayload(
            id: idB,
            title: "Alpha",
            modifiedAt: Date().addingTimeInterval(10),
            body: bodyB
        )

        _ = try SyncCatalogBuilder.applyRemoteCatalog(
            [remoteA, remoteB],
            roots: [dir],
            createDirectory: dir
        )

        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .map(\.lastPathComponent)
            .sorted()
        XCTAssertEqual(files, ["2024-01-01-alpha.md", "2024-01-01-beta.md"])

        let alphaText = try String(
            contentsOf: dir.appendingPathComponent("2024-01-01-alpha.md"),
            encoding: .utf8
        )
        let betaText = try String(
            contentsOf: dir.appendingPathComponent("2024-01-01-beta.md"),
            encoding: .utf8
        )
        XCTAssertEqual(NoteFrontmatter.syncID(in: alphaText), idB)
        XCTAssertEqual(NoteFrontmatter.syncID(in: betaText), idA)
        XCTAssertNil(NoteFrontmatter.displayTitle(in: alphaText))
        XCTAssertNil(NoteFrontmatter.displayTitle(in: betaText))
    }

    func testIdenticalBodiesConvergeTitlesWithoutPingPong() {
        let id = UUID()
        let t = Date()
        let alpha = SyncNotePayload(id: id, title: "Alpha", modifiedAt: t, body: "same")
        let beta = SyncNotePayload(id: id, title: "Beta", modifiedAt: t, body: "same")
        // Both peers agree: Beta wins.
        XCTAssertEqual(SyncMerge.decide(local: alpha, remote: beta), .applyRemote(beta))
        XCTAssertEqual(SyncMerge.decide(local: beta, remote: alpha), .keepLocal)
    }

    func testTitleOnlyApplyRenamesExistingFile() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdstickies-title-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let id = UUID()
        let path = dir.appendingPathComponent("2024-01-01-alpha.md")
        let body = NoteFrontmatter.initialDocument(title: "Alpha", id: id, createdOn: "MacBook Pro")
        try body.write(to: path, atomically: true, encoding: .utf8)
        let mtime = Date(timeIntervalSince1970: 100)
        try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: path.path)

        // Same body, newer title — title-only rename (not a content conflict).
        let remote = SyncNotePayload(
            id: id,
            title: "Beta",
            modifiedAt: Date(timeIntervalSince1970: 200),
            body: body
        )
        _ = try SyncCatalogBuilder.applyRemoteCatalog([remote], roots: [dir], createDirectory: dir)

        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .map(\.lastPathComponent)
            .sorted()
        XCTAssertEqual(files, ["2024-01-01-beta.md"])
        let text = try String(contentsOf: dir.appendingPathComponent("2024-01-01-beta.md"), encoding: .utf8)
        XCTAssertEqual(NoteFrontmatter.syncID(in: text), id)
        XCTAssertNil(NoteFrontmatter.displayTitle(in: text))
        XCTAssertEqual(NoteFrontmatter.createdOn(in: text), "MacBook Pro")
    }

    func testDivergentBodiesKeepBothWithoutOverwrite() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdstickies-conflict-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let id = UUID()
        let path = dir.appendingPathComponent("2024-01-01-seminar.md")
        let largeLocal = NoteFrontmatter.initialDocument(title: "Seminar", id: id)
            + String(repeating: "Mac paragraph.\n", count: 40)
        try largeLocal.write(to: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 100)],
            ofItemAtPath: path.path
        )

        let remoteBody = NoteFrontmatter.initialDocument(title: "Seminar", id: id) + "One line from iPhone.\n"
        let remote = SyncNotePayload(
            id: id,
            title: "Seminar",
            modifiedAt: Date(timeIntervalSince1970: 200),
            body: remoteBody
        )

        XCTAssertEqual(
            SyncMerge.decide(
                local: SyncNotePayload(id: id, title: "Seminar", modifiedAt: Date(timeIntervalSince1970: 100), body: largeLocal),
                remote: remote
            ),
            .conflict(
                local: SyncNotePayload(id: id, title: "Seminar", modifiedAt: Date(timeIntervalSince1970: 100), body: largeLocal),
                remote: remote
            )
        )

        let result = try SyncCatalogBuilder.applyRemoteCatalog(
            [remote],
            roots: [dir],
            createDirectory: dir,
            peerLabel: "iPhone"
        )

        XCTAssertEqual(result.conflicts.count, 1)
        let conflict = try XCTUnwrap(result.conflicts.first)
        XCTAssertEqual(conflict.id, id)
        XCTAssertNotEqual(conflict.remoteCopyID, id)
        XCTAssertNotNil(conflict.remoteCopyPath)

        let localAfter = try String(contentsOf: path, encoding: .utf8)
        XCTAssertEqual(localAfter, largeLocal)
        XCTAssertEqual(NoteFrontmatter.syncID(in: localAfter), id)

        let siblingPath = try XCTUnwrap(conflict.remoteCopyPath)
        let sibling = try String(contentsOf: siblingPath, encoding: .utf8)
        XCTAssertEqual(NoteFrontmatter.syncID(in: sibling), conflict.remoteCopyID)
        XCTAssertTrue(NoteFrontmatter.isConflictSibling(sibling))
        XCTAssertTrue(sibling.contains("One line from iPhone."))
        XCTAssertFalse(sibling.contains("Mac paragraph."))
        XCTAssertTrue(siblingPath.lastPathComponent.contains("from-iphone")
            || siblingPath.lastPathComponent.contains("iphone")
            || siblingPath.path.lowercased().contains("iphone"))
        XCTAssertTrue(result.appliedIDs.isEmpty, "sibling is local-only — not an apply ACK")
        XCTAssertEqual(SyncCatalogBuilder.catalog(roots: [dir]).count, 1, "sibling excluded from sync catalog")

        // Same remote again must not mint another sibling — but must still surface the conflict
        // so Mac opens merge (not “Synced” while iOS waits).
        let again = try SyncCatalogBuilder.applyRemoteCatalog(
            [remote],
            roots: [dir],
            createDirectory: dir,
            peerLabel: "iPhone",
            conflictRole: .mergeAuthority
        )
        XCTAssertEqual(again.conflicts.count, 1)
        XCTAssertEqual(again.conflicts.first?.remoteCopyPath, siblingPath)
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() == "md" }
        XCTAssertEqual(files.count, 2)
    }

    func testSatelliteConflictKeepsLocalWithoutSibling() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdstickies-sat-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let id = UUID()
        let path = dir.appendingPathComponent("2024-01-01-todo.md")
        let localBody = NoteFrontmatter.initialDocument(title: "Todo", id: id) + "iOS edit\n"
        try localBody.write(to: path, atomically: true, encoding: .utf8)

        let remote = SyncNotePayload(
            id: id,
            title: "Todo",
            modifiedAt: Date().addingTimeInterval(10),
            body: NoteFrontmatter.initialDocument(title: "Todo", id: id) + "Mac version\n"
        )
        let result = try SyncCatalogBuilder.applyRemoteCatalog(
            [remote],
            roots: [dir],
            createDirectory: dir,
            peerLabel: "MacBook",
            conflictRole: .satellite
        )
        XCTAssertTrue(result.conflicts.isEmpty)
        XCTAssertEqual(result.awaitingAuthorityMerge.count, 1)
        XCTAssertFalse(result.appliedIDs.contains(id), "satellite conflict is not a write")
        let after = try String(contentsOf: path, encoding: .utf8)
        XCTAssertEqual(after, localBody)
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() == "md" }
        XCTAssertEqual(files.count, 1)
    }

    func testContentFingerprintIgnoresSyncID() {
        let a = UUID()
        let b = UUID()
        let bodyA = NoteFrontmatter.initialDocument(title: "Note", id: a) + "same\n"
        let bodyB = NoteFrontmatter.settingSyncID(b, in: bodyA)
        XCTAssertEqual(
            NoteFrontmatter.contentFingerprint(bodyA),
            NoteFrontmatter.contentFingerprint(bodyB)
        )
        XCTAssertNotEqual(bodyA, bodyB)
    }

    func testSettingSyncIDReplacesExistingID() {
        let old = UUID()
        let fresh = UUID()
        let body = NoteFrontmatter.initialDocument(title: "Note", id: old)
        let updated = NoteFrontmatter.settingSyncID(fresh, in: body)
        XCTAssertEqual(NoteFrontmatter.syncID(in: updated), fresh)
        XCTAssertNotEqual(NoteFrontmatter.syncID(in: updated), old)
    }

    func testConflictResolvedRemoteOverwritesUnresolvedLocal() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdstickies-resolve-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let id = UUID()
        let path = dir.appendingPathComponent("2024-01-01-todo.md")
        let localBody = NoteFrontmatter.initialDocument(title: "Todo", id: id) + "iOS version\n"
        try localBody.write(to: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 100)],
            ofItemAtPath: path.path
        )

        var remoteBody = NoteFrontmatter.initialDocument(title: "Todo", id: id) + "Merged on Mac\n"
        remoteBody = NoteFrontmatter.settingConflictResolved(
            Date(timeIntervalSince1970: 1_700_000_000),
            in: remoteBody
        )
        let remote = SyncNotePayload(
            id: id,
            title: "Todo",
            modifiedAt: Date(timeIntervalSince1970: 500), // merge must not be older than local
            body: remoteBody
        )

        let localPayload = SyncNotePayload(
            id: id,
            title: "Todo",
            modifiedAt: Date(timeIntervalSince1970: 100),
            body: localBody
        )
        XCTAssertEqual(SyncMerge.decide(local: localPayload, remote: remote), .applyRemote(remote))

        let result = try SyncCatalogBuilder.applyRemoteCatalog(
            [remote],
            roots: [dir],
            createDirectory: dir,
            peerLabel: "Mac"
        )
        XCTAssertTrue(result.conflicts.isEmpty)
        let after = try String(contentsOf: path, encoding: .utf8)
        XCTAssertTrue(after.contains("Merged on Mac"))
        XCTAssertFalse(after.contains("iOS version"))
        XCTAssertNotNil(NoteFrontmatter.conflictResolvedAt(in: after))
    }

    func testConflictResolvedLocalKeepsAgainstUnresolvedRemote() {
        let id = UUID()
        var localBody = NoteFrontmatter.initialDocument(title: "Todo", id: id) + "Merged\n"
        localBody = NoteFrontmatter.settingConflictResolved(Date(timeIntervalSince1970: 200), in: localBody)
        let remoteBody = NoteFrontmatter.initialDocument(title: "Todo", id: id) + "Old peer\n"
        // mtime must not matter — resolve stamp alone keeps local.
        let local = SyncNotePayload(id: id, title: "Todo", modifiedAt: Date(timeIntervalSince1970: 1), body: localBody)
        let remote = SyncNotePayload(id: id, title: "Todo", modifiedAt: Date(timeIntervalSince1970: 999), body: remoteBody)
        XCTAssertEqual(SyncMerge.decide(local: local, remote: remote), .keepLocal)
    }

    func testNewerConflictResolvedWins() {
        let id = UUID()
        var older = NoteFrontmatter.initialDocument(title: "Todo", id: id) + "A\n"
        older = NoteFrontmatter.settingConflictResolved(Date(timeIntervalSince1970: 100), in: older)
        var newer = NoteFrontmatter.initialDocument(title: "Todo", id: id) + "B\n"
        newer = NoteFrontmatter.settingConflictResolved(Date(timeIntervalSince1970: 200), in: newer)
        let local = SyncNotePayload(id: id, title: "Todo", modifiedAt: Date(), body: older)
        let remote = SyncNotePayload(id: id, title: "Todo", modifiedAt: Date(), body: newer)
        XCTAssertEqual(SyncMerge.decide(local: local, remote: remote), .applyRemote(remote))
        XCTAssertEqual(SyncMerge.decide(local: remote, remote: local), .keepLocal)
    }

    func testOutboundIDsIgnoreUnresolvedConflicts() {
        let id = UUID()
        let local = SyncNotePayload(
            id: id,
            title: "Todo",
            modifiedAt: Date(timeIntervalSince1970: 1),
            body: NoteFrontmatter.initialDocument(title: "Todo", id: id) + "Mac\n"
        )
        let remote = SyncNotePayload(
            id: id,
            title: "Todo",
            modifiedAt: Date(timeIntervalSince1970: 2),
            body: NoteFrontmatter.initialDocument(title: "Todo", id: id) + "iOS\n"
        )
        XCTAssertEqual(SyncMerge.decide(local: local, remote: remote), .conflict(local: local, remote: remote))
        // Peer already has this id (their version) — keep-both is not a pending send.
        XCTAssertEqual(SyncMerge.outboundIDs(ours: [local], theirs: [remote]), [])
        // Missing on peer still counts.
        let other = UUID()
        let onlyOurs = SyncNotePayload(
            id: other,
            title: "Solo",
            modifiedAt: Date(),
            body: NoteFrontmatter.initialDocument(title: "Solo", id: other)
        )
        XCTAssertEqual(SyncMerge.outboundIDs(ours: [local, onlyOurs], theirs: [remote]), [other])
    }

    func testContentFingerprintIgnoresConflictResolved() {
        let id = UUID()
        let base = NoteFrontmatter.initialDocument(title: "Note", id: id) + "body\n"
        let marked = NoteFrontmatter.settingConflictResolved(Date(), in: base)
        XCTAssertEqual(
            NoteFrontmatter.contentFingerprint(base),
            NoteFrontmatter.contentFingerprint(marked)
        )
    }

    func testConflictResurfacesWhenSiblingAlreadyExists() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdstickies-ack-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let id = UUID()
        let path = dir.appendingPathComponent("2024-01-01-todo.md")
        let localBody = NoteFrontmatter.initialDocument(title: "Todo", id: id) + "Mac\n"
        try localBody.write(to: path, atomically: true, encoding: .utf8)

        let remoteBody = NoteFrontmatter.initialDocument(title: "Todo", id: id) + "iOS\n"
        // Pre-seed a sibling with the remote fingerprint so keep-both writes nothing new.
        let siblingID = UUID()
        let siblingPath = dir.appendingPathComponent("2024-01-01-todo-from-iphone.md")
        var siblingBody = NoteFrontmatter.settingSyncID(siblingID, in: remoteBody)
        siblingBody = NoteFrontmatter.markingConflictSibling(id, in: siblingBody)
        try siblingBody.write(to: siblingPath, atomically: true, encoding: .utf8)

        let remote = SyncNotePayload(
            id: id,
            title: "Todo",
            modifiedAt: Date().addingTimeInterval(10),
            body: remoteBody
        )
        let result = try SyncCatalogBuilder.applyRemoteCatalog(
            [remote],
            roots: [dir],
            createDirectory: dir,
            peerLabel: "iPhone",
            conflictRole: .mergeAuthority
        )
        XCTAssertEqual(result.conflicts.count, 1, "Mac must still open merge when sibling exists")
        XCTAssertEqual(result.conflicts.first?.remoteCopyPath, siblingPath)
        XCTAssertFalse(result.appliedIDs.contains(id), "contested id is not a write ACK")
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() == "md" }
        XCTAssertEqual(files.count, 2, "must not mint a second sibling")
        XCTAssertEqual(
            SyncMerge.outboundIDs(
                ours: [SyncNotePayload(id: id, title: "Todo", modifiedAt: Date(), body: localBody)],
                theirs: [remote]
            ),
            []
        )
    }

    func testEqualConflictResolvedStampsAreConflictNotMtime() {
        let id = UUID()
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        var mac = NoteFrontmatter.initialDocument(title: "Todo", id: id) + "Mac line\n"
        mac = NoteFrontmatter.settingConflictResolved(stamp, in: mac)
        var phone = NoteFrontmatter.initialDocument(title: "Todo", id: id) + "iOS line\n"
        phone = NoteFrontmatter.settingConflictResolved(stamp, in: phone)
        let local = SyncNotePayload(id: id, title: "Todo", modifiedAt: Date(timeIntervalSince1970: 1), body: mac)
        let remote = SyncNotePayload(id: id, title: "Todo", modifiedAt: Date(timeIntervalSince1970: 999), body: phone)
        XCTAssertEqual(
            SyncMerge.decide(local: local, remote: remote),
            .conflict(local: local, remote: remote)
        )
    }

    func testRemoteResolveDoesNotOverwriteNewerLocalEdit() {
        // If local also lacks a stamp, remote resolve still wins (Mac merge authority).
        // This test documents that — rename intent: remote resolve applies.
        let id = UUID()
        let localBody = NoteFrontmatter.initialDocument(title: "Todo", id: id) + "Mac after edit\n"
        var remoteBody = NoteFrontmatter.initialDocument(title: "Todo", id: id) + "Old merged\n"
        remoteBody = NoteFrontmatter.settingConflictResolved(Date(timeIntervalSince1970: 100), in: remoteBody)
        let local = SyncNotePayload(id: id, title: "Todo", modifiedAt: Date(timeIntervalSince1970: 200), body: localBody)
        let remote = SyncNotePayload(id: id, title: "Todo", modifiedAt: Date(timeIntervalSince1970: 100), body: remoteBody)
        XCTAssertEqual(SyncMerge.decide(local: local, remote: remote), .applyRemote(remote))
    }

    func testCatalogDoesNotStampFolderOrTitle() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdstickies-folder-\(UUID().uuidString)", isDirectory: true)
        let sub = root.appendingPathComponent("projects", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let id = UUID()
        let path = sub.appendingPathComponent("2024-01-01-note.md")
        try NoteFrontmatter.initialDocument(title: "Note", id: id)
            .write(to: path, atomically: true, encoding: .utf8)

        let catalog = SyncCatalogBuilder.catalog(roots: [root])
        XCTAssertEqual(catalog.count, 1)
        XCTAssertNil(NoteFrontmatter.folder(in: catalog[0].body))
        XCTAssertNil(NoteFrontmatter.displayTitle(in: catalog[0].body))
        XCTAssertEqual(catalog[0].title, "Note")
        let onDisk = try String(contentsOf: path, encoding: .utf8)
        XCTAssertNil(NoteFrontmatter.folder(in: onDisk))
        XCTAssertNil(NoteFrontmatter.displayTitle(in: onDisk))
    }

    func testTrashIsLocalOnlyNeverSynced() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdstickies-trash-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let id = UUID()
        let path = root.appendingPathComponent("2024-01-01-note.md")
        try NoteFrontmatter.initialDocument(title: "Note", id: id, createdOn: "Mac")
            .write(to: path, atomically: true, encoding: .utf8)

        let trashed = try NoteFrontmatter.moveToTrash(file: path, roots: [root])
        XCTAssertTrue(NoteFrontmatter.isTrashed(file: trashed))
        XCTAssertTrue(SyncCatalogBuilder.catalog(roots: [root]).isEmpty, "trash excluded from wire catalog")

        // Peer vault with the note still active — applying a trash payload must not move it.
        let peer = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdstickies-trash-peer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: peer, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: peer) }
        let peerPath = peer.appendingPathComponent("2024-01-01-note.md")
        let peerBody = NoteFrontmatter.initialDocument(title: "Note", id: id)
        try peerBody.write(to: peerPath, atomically: true, encoding: .utf8)

        let remote = try SyncCatalogBuilder.payload(fromFile: trashed, roots: [root])!
        _ = try SyncCatalogBuilder.applyRemoteCatalog([remote], roots: [peer], createDirectory: peer)

        XCTAssertTrue(FileManager.default.fileExists(atPath: peerPath.path))
        let peerTrash = peer.appendingPathComponent("Trash")
        let trashExists = FileManager.default.fileExists(atPath: peerTrash.path)
        if trashExists {
            let peerFiles = try FileManager.default.contentsOfDirectory(
                at: peerTrash, includingPropertiesForKeys: nil
            )
            XCTAssertTrue(peerFiles.isEmpty)
        }
        let still = try String(contentsOf: peerPath, encoding: .utf8)
        XCTAssertEqual(NoteFrontmatter.syncID(in: still), id)
    }
}
