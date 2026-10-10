import XCTest
@testable import MarkdownStickiesCore

/// Device-free end-to-end stress of diverge → Mac keep-both → merge → push to satellite.
final class SyncMergeScenarioTests: XCTestCase {
    private var macDir: URL!
    private var iosDir: URL!

    override func setUpWithError() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdstickies-scenario-\(UUID().uuidString)", isDirectory: true)
        macDir = root.appendingPathComponent("Mac", isDirectory: true)
        iosDir = root.appendingPathComponent("iOS", isDirectory: true)
        try FileManager.default.createDirectory(at: macDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: iosDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let macDir {
            try? FileManager.default.removeItem(at: macDir.deletingLastPathComponent())
        }
    }

    func testAppendOnlyDivergenceMergesCleanlyAcrossVaults() throws {
        let id = UUID()
        let base = NoteFrontmatter.initialDocument(title: "Todo", id: id, createdOn: "Mac")
            + "- shared\n"

        try base.write(to: macDir.appendingPathComponent("2024-01-01-todo.md"), atomically: true, encoding: .utf8)
        try base.write(to: iosDir.appendingPathComponent("2024-01-01-todo.md"), atomically: true, encoding: .utf8)

        // Diverge: each side appends.
        var macBody = try String(contentsOf: macDir.appendingPathComponent("2024-01-01-todo.md"), encoding: .utf8)
        macBody += "- mac line\n"
        try macBody.write(to: macDir.appendingPathComponent("2024-01-01-todo.md"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 100)],
            ofItemAtPath: macDir.appendingPathComponent("2024-01-01-todo.md").path
        )

        var iosBody = try String(contentsOf: iosDir.appendingPathComponent("2024-01-01-todo.md"), encoding: .utf8)
        iosBody += "- ios line\n"
        try iosBody.write(to: iosDir.appendingPathComponent("2024-01-01-todo.md"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 200)],
            ofItemAtPath: iosDir.appendingPathComponent("2024-01-01-todo.md").path
        )

        // iOS → Mac (authority keep-both)
        let iosCatalog = SyncCatalogBuilder.catalog(roots: [iosDir])
        let macApply = try SyncCatalogBuilder.applyRemoteCatalog(
            iosCatalog,
            roots: [macDir],
            createDirectory: macDir,
            peerLabel: "tinydancer",
            conflictRole: .mergeAuthority
        )
        XCTAssertEqual(macApply.conflicts.count, 1)
        let conflict = try XCTUnwrap(macApply.conflicts.first)

        let merged = TextMerge.mergeDocuments(
            localMarkdown: conflict.local.body,
            remoteMarkdown: conflict.remote.body,
            keepingID: id,
            localLabel: "This Mac",
            remoteLabel: conflict.peerLabel
        )
        XCTAssertFalse(merged.hasConflicts, merged.body)

        // Write merge + resolve on Mac, trash sibling.
        let now = Date(timeIntervalSince1970: 300)
        var resolved = NoteFrontmatter.settingConflictResolved(now, in: merged.body)
        resolved = NoteFrontmatter.settingSyncID(id, in: resolved)
        let macPath = try XCTUnwrap(SyncCatalogBuilder.pathIndex(roots: [macDir])[id])
        try resolved.write(to: macPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: macPath.path)
        if let sibling = conflict.remoteCopyPath {
            _ = try NoteFrontmatter.moveToTrash(file: sibling, roots: [macDir])
        }

        // Mac → iOS (satellite should apply resolve)
        let macCatalog = SyncCatalogBuilder.catalog(roots: [macDir])
        let iosApply = try SyncCatalogBuilder.applyRemoteCatalog(
            macCatalog,
            roots: [iosDir],
            createDirectory: iosDir,
            peerLabel: "MacBook",
            conflictRole: .satellite
        )
        XCTAssertTrue(iosApply.conflicts.isEmpty)
        XCTAssertTrue(iosApply.awaitingAuthorityMerge.isEmpty)

        let iosAfter = try String(
            contentsOf: try XCTUnwrap(SyncCatalogBuilder.pathIndex(roots: [iosDir])[id]),
            encoding: .utf8
        )
        XCTAssertTrue(iosAfter.contains("- mac line"))
        XCTAssertTrue(iosAfter.contains("- ios line"))
        XCTAssertTrue(iosAfter.contains("- shared"))
        XCTAssertEqual(NoteFrontmatter.syncID(in: iosAfter), id)
        XCTAssertNotNil(NoteFrontmatter.conflictResolvedAt(in: iosAfter))

        // One active note on each side (Mac may have Trash sibling).
        let macActive = try activeMarkdownFiles(in: macDir)
        let iosActive = try activeMarkdownFiles(in: iosDir)
        XCTAssertEqual(macActive.count, 1)
        XCTAssertEqual(iosActive.count, 1)
    }

    func testSameLineEditRequiresManualMarkersThenSave() throws {
        let id = UUID()
        let base = NoteFrontmatter.initialDocument(title: "Note", id: id) + "shared intro\n"

        try base.write(to: macDir.appendingPathComponent("note.md"), atomically: true, encoding: .utf8)
        try base.write(to: iosDir.appendingPathComponent("note.md"), atomically: true, encoding: .utf8)

        try (base + "Mac conclusion\n")
            .write(to: macDir.appendingPathComponent("note.md"), atomically: true, encoding: .utf8)
        try (base + "iOS conclusion\n")
            .write(to: iosDir.appendingPathComponent("note.md"), atomically: true, encoding: .utf8)

        let iosCatalog = SyncCatalogBuilder.catalog(roots: [iosDir])
        let macApply = try SyncCatalogBuilder.applyRemoteCatalog(
            iosCatalog,
            roots: [macDir],
            createDirectory: macDir,
            peerLabel: "iPhone",
            conflictRole: .mergeAuthority
        )
        let conflict = try XCTUnwrap(macApply.conflicts.first)
        let merged = TextMerge.mergeDocuments(
            localMarkdown: conflict.local.body,
            remoteMarkdown: conflict.remote.body,
            keepingID: id,
            remoteLabel: "iPhone"
        )
        XCTAssertTrue(merged.hasConflicts)
        XCTAssertTrue(merged.body.contains("<<<<<<<"))

        // User picks Mac wording by stripping markers / taking local side.
        let cleaned = merged.body
            .replacingOccurrences(of: "<<<<<<< This Mac\n", with: "")
            .replacingOccurrences(of: "=======\niOS conclusion\n>>>>>>> iPhone\n", with: "")
        XCTAssertTrue(cleaned.contains("Mac conclusion"))
        XCTAssertFalse(cleaned.contains("iOS conclusion"))
        XCTAssertFalse(cleaned.contains("<<<<<<<"))
    }

    func testResolveStampRequiredForSatelliteApply() throws {
        let id = UUID()
        let macBody = NoteFrontmatter.initialDocument(title: "N", id: id) + "MERGED\n"
        let iosBody = NoteFrontmatter.initialDocument(title: "N", id: id) + "OLD IOS\n"
        try macBody.write(to: macDir.appendingPathComponent("n.md"), atomically: true, encoding: .utf8)
        try iosBody.write(to: iosDir.appendingPathComponent("n.md"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 500)],
            ofItemAtPath: macDir.appendingPathComponent("n.md").path
        )

        let noStamp = try SyncCatalogBuilder.applyRemoteCatalog(
            SyncCatalogBuilder.catalog(roots: [macDir]),
            roots: [iosDir],
            createDirectory: iosDir,
            peerLabel: "Mac",
            conflictRole: .satellite
        )
        XCTAssertEqual(noStamp.awaitingAuthorityMerge.count, 1)
        XCTAssertTrue(
            try String(contentsOf: iosDir.appendingPathComponent("n.md"), encoding: .utf8)
                .contains("OLD IOS")
        )

        let stamped = NoteFrontmatter.settingConflictResolved(
            Date(timeIntervalSince1970: 900),
            in: macBody
        )
        try stamped.write(to: macDir.appendingPathComponent("n.md"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 900)],
            ofItemAtPath: macDir.appendingPathComponent("n.md").path
        )
        let withStamp = try SyncCatalogBuilder.applyRemoteCatalog(
            SyncCatalogBuilder.catalog(roots: [macDir]),
            roots: [iosDir],
            createDirectory: iosDir,
            peerLabel: "Mac",
            conflictRole: .satellite
        )
        XCTAssertTrue(withStamp.awaitingAuthorityMerge.isEmpty)
        let after = try String(contentsOf: iosDir.appendingPathComponent("n.md"), encoding: .utf8)
        XCTAssertTrue(after.contains("MERGED"))
        XCTAssertNotNil(NoteFrontmatter.conflictResolvedAt(in: after))
    }

    func testSatelliteDoesNotSpawnFromMacSibling() throws {
        let id = UUID()
        let macBody = NoteFrontmatter.initialDocument(title: "Todo", id: id) + "Mac\n"
        let iosBody = NoteFrontmatter.initialDocument(title: "Todo", id: id) + "iOS\n"
        try macBody.write(to: macDir.appendingPathComponent("t.md"), atomically: true, encoding: .utf8)
        try iosBody.write(to: iosDir.appendingPathComponent("t.md"), atomically: true, encoding: .utf8)

        let macCatalog = SyncCatalogBuilder.catalog(roots: [macDir])
        let iosApply = try SyncCatalogBuilder.applyRemoteCatalog(
            macCatalog,
            roots: [iosDir],
            createDirectory: iosDir,
            peerLabel: "MacBook",
            conflictRole: .satellite
        )
        XCTAssertEqual(iosApply.awaitingAuthorityMerge.count, 1)
        XCTAssertEqual(try activeMarkdownFiles(in: iosDir).count, 1)
        let still = try String(contentsOf: iosDir.appendingPathComponent("t.md"), encoding: .utf8)
        XCTAssertEqual(still, iosBody)
    }

    func testRepeatedSyncAfterKeepBothDoesNotMultiply() throws {
        let id = UUID()
        let macBody = NoteFrontmatter.initialDocument(title: "Todo", id: id) + "Mac\n"
        let iosBody = NoteFrontmatter.initialDocument(title: "Todo", id: id) + "iOS\n"
        try macBody.write(to: macDir.appendingPathComponent("t.md"), atomically: true, encoding: .utf8)
        try iosBody.write(to: iosDir.appendingPathComponent("t.md"), atomically: true, encoding: .utf8)

        let iosCatalog = SyncCatalogBuilder.catalog(roots: [iosDir])
        _ = try SyncCatalogBuilder.applyRemoteCatalog(
            iosCatalog, roots: [macDir], createDirectory: macDir,
            peerLabel: "iPhone", conflictRole: .mergeAuthority
        )
        let afterFirst = try activeMarkdownFiles(in: macDir).count
        XCTAssertEqual(afterFirst, 2)

        _ = try SyncCatalogBuilder.applyRemoteCatalog(
            iosCatalog, roots: [macDir], createDirectory: macDir,
            peerLabel: "iPhone", conflictRole: .mergeAuthority
        )
        XCTAssertEqual(try activeMarkdownFiles(in: macDir).count, 2)
    }

    private func activeMarkdownFiles(in dir: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() == "md" }
            .filter { !NoteFrontmatter.isTrashed(file: $0) }
            .filter { !$0.lastPathComponent.hasPrefix(".") }
    }
}
