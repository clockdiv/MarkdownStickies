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

        // Remote swapped names + slightly newer bodies.
        let remoteA = SyncNotePayload(
            id: idA,
            title: "Beta",
            modifiedAt: Date().addingTimeInterval(10),
            body: bodyA + "\nA"
        )
        let remoteB = SyncNotePayload(
            id: idB,
            title: "Alpha",
            modifiedAt: Date().addingTimeInterval(10),
            body: bodyB + "\nB"
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

        let remote = SyncNotePayload(
            id: id,
            title: "Beta",
            modifiedAt: Date(timeIntervalSince1970: 200),
            body: NoteFrontmatter.initialDocument(title: "Beta", id: id, createdOn: "Julian’s iPhone")
        )
        _ = try SyncCatalogBuilder.applyRemoteCatalog([remote], roots: [dir], createDirectory: dir)

        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .map(\.lastPathComponent)
            .sorted()
        XCTAssertEqual(files, ["2024-01-01-beta.md"])
        let text = try String(contentsOf: dir.appendingPathComponent("2024-01-01-beta.md"), encoding: .utf8)
        XCTAssertEqual(NoteFrontmatter.syncID(in: text), id)
        XCTAssertNil(NoteFrontmatter.displayTitle(in: text))
        // Remote body wins entirely (including created_on).
        XCTAssertEqual(NoteFrontmatter.createdOn(in: text), "Julian’s iPhone")
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

    func testMoveToTrashUpdatesFolderAndSyncPlacesPeerInTrash() throws {
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
        let trashedBody = try String(contentsOf: trashed, encoding: .utf8)
        XCTAssertEqual(NoteFrontmatter.folder(in: trashedBody), "Trash")
        XCTAssertTrue(NoteFrontmatter.isTrashFolder(NoteFrontmatter.folder(in: trashedBody)))

        // Peer vault with the note still active.
        let peer = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdstickies-trash-peer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: peer, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: peer) }
        let peerPath = peer.appendingPathComponent("2024-01-01-note.md")
        try NoteFrontmatter.initialDocument(title: "Note", id: id)
            .write(to: peerPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 100)],
            ofItemAtPath: peerPath.path
        )

        let remote = try SyncCatalogBuilder.payload(fromFile: trashed, roots: [root])!
        _ = try SyncCatalogBuilder.applyRemoteCatalog([remote], roots: [peer], createDirectory: peer)

        XCTAssertFalse(FileManager.default.fileExists(atPath: peerPath.path))
        let peerTrash = peer.appendingPathComponent("Trash")
        let peerFiles = try FileManager.default.contentsOfDirectory(at: peerTrash, includingPropertiesForKeys: nil)
        XCTAssertEqual(peerFiles.count, 1)
        XCTAssertTrue(NoteFrontmatter.isTrashed(file: peerFiles[0]))
    }
}
