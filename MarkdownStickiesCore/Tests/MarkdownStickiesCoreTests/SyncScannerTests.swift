import Foundation
import XCTest
@testable import MarkdownStickiesCore

private func makeTempDir(_ name: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        .resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func put(_ text: String, at url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
}

private func tracked(_ id: UUID, _ body: String = "# Note\n") -> String {
    "---\nstickies-id: \(id.uuidString)\n---\n\n\(body)"
}

final class SyncSetBuilderTests: XCTestCase {
    private var dir: URL!
    private let rootID = UUID()
    private let a = UUID()
    private let b = UUID()

    override func setUpWithError() throws { dir = try makeTempDir("SyncSetBuilderTests") }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private var root: SyncRoot { SyncRoot(id: rootID, url: dir.appendingPathComponent("project"), isSynced: true) }
    private func file(_ path: String) -> URL { root.url.appendingPathComponent(path) }
    private func loc(_ path: String) -> NoteLocation { NoteLocation(rootID: rootID, path: path) }

    func testOnlyTrackedNotesAreInTheSet() throws {
        try put(tracked(a), at: file("docs/idea.md"))
        try put("# README\n", at: file("README.md"))
        try put(tracked(b), at: file("node_modules/pkg/x.md"))
        try put(tracked(UUID()), at: file("Trash/old.md"))
        try put(tracked(UUID()), at: file(".hidden/x.md"))

        let set = SyncSetBuilder.build(roots: [root], config: .empty, base: .empty)
        XCTAssertEqual(set.manifest.notes.map(\.id), [a])
        XCTAssertEqual(set.manifest.notes.first?.location, loc("docs/idea.md"))
    }

    func testUnsyncedRootsAndDeeperUnsyncedRootsAreLeftOut() throws {
        let inner = SyncRoot(id: UUID(), url: file("inner"), isSynced: false)
        try put(tracked(a), at: file("idea.md"))
        try put(tracked(b), at: file("inner/other.md"))

        let set = SyncSetBuilder.build(roots: [root, inner], config: .empty, base: .empty)
        XCTAssertEqual(set.manifest.notes.map(\.id), [a])
    }

    func testScanConfigExcludesAreApplied() throws {
        try put(tracked(a), at: file("keep.md"))
        try put(tracked(b), at: file("private/secret.md"))
        let config = ScanConfig(rules: [ScanRule(kind: .exclude, pattern: file("private").path)])

        let set = SyncSetBuilder.build(roots: [root], config: config, base: .empty)
        XCTAssertEqual(set.manifest.notes.map(\.id), [a])
    }

    func testExcludedBaseNoteIsReportedAsLeft() throws {
        try put(tracked(b), at: file("private/secret.md"))
        let config = ScanConfig(rules: [ScanRule(kind: .exclude, pattern: file("private").path)])
        let base = SyncBase(notes: [b: SyncBase.Note(location: loc("private/secret.md"), fileHash: "h", restHash: "h")])

        let set = SyncSetBuilder.build(roots: [root], config: config, base: base)
        XCTAssertEqual(set.manifest.left, [LeftNote(id: b, location: loc("private/secret.md"))])
    }

    func testRemovedKeyIsLeftAndDeletedFileIsNothing() throws {
        try put("# no key any more\n", at: file("idea.md"))
        let base = SyncBase(notes: [
            a: SyncBase.Note(location: loc("idea.md"), fileHash: "h", restHash: "h"),
            b: SyncBase.Note(location: loc("gone.md"), fileHash: "h", restHash: "h"),
        ])
        let set = SyncSetBuilder.build(roots: [root], config: .empty, base: base)
        XCTAssertEqual(set.manifest.left, [LeftNote(id: a, location: loc("idea.md"))])
        XCTAssertEqual(set.manifest.unreadable, [])
    }

    func testUnreadableFileIsReported() throws {
        try FileManager.default.createDirectory(at: root.url, withIntermediateDirectories: true)
        try Data([0xFF, 0xFE, 0x00, 0x41]).write(to: file("broken.md"))
        let set = SyncSetBuilder.build(roots: [root], config: .empty, base: .empty)
        XCTAssertEqual(set.manifest.unreadable, [loc("broken.md")])
    }

    func testRemovedRootNotesAreLeft() throws {
        try put(tracked(a), at: file("idea.md"))
        let base = SyncBase(notes: [a: SyncBase.Note(location: loc("idea.md"), fileHash: "h", restHash: "h")])
        let set = SyncSetBuilder.build(roots: [], rootPaths: [rootID: root.url], config: .empty, base: base)
        XCTAssertEqual(set.manifest.left, [LeftNote(id: a, location: loc("idea.md"))])
    }

    func testImagesReferencedOrKnownAreReported() throws {
        try put(tracked(a, "![x](img/a.png)\n![y](img/missing.png)\n"), at: file("idea.md"))
        try put("png-a", at: file("img/a.png"))
        try put("png-b", at: file("img/b.png"))
        try put("png-c", at: file("img/c.png"))
        let known = ImageKey(rootID: rootID, path: "img/c.png")

        let set = SyncSetBuilder.build(roots: [root], config: .empty, base: .empty, extraImages: [known])
        XCTAssertEqual(set.manifest.images.map(\.key.path), ["img/a.png", "img/c.png"])
        XCTAssertEqual(set.manifest.notes.first?.imageRefs, ["img/a.png", "img/missing.png"])
    }

    func testAllowsChecksRootPathRulesAndConfig() throws {
        let inner = SyncRoot(id: UUID(), url: file("inner"), isSynced: false)
        let config = ScanConfig(rules: [ScanRule(kind: .exclude, pattern: file("private").path)])
        let set = SyncSetBuilder.build(roots: [root, inner], config: config, base: .empty)

        XCTAssertTrue(set.allows(loc("docs/new.md")))
        XCTAssertFalse(set.allows(loc("private/new.md")), "scan.conf")
        XCTAssertFalse(set.allows(loc("build/new.md")), "built-in skipped folder")
        XCTAssertFalse(set.allows(loc("Trash/new.md")), "legacy trash")
        XCTAssertFalse(set.allows(loc("inner/new.md")), "belongs to a deeper root")
        XCTAssertFalse(set.allows(loc("../escape.md")))
        XCTAssertFalse(set.allows(NoteLocation(rootID: UUID(), path: "x.md")), "unknown root")
        XCTAssertFalse(set.allows(.inbox("x.md")))
    }
}

final class VaultScannerTests: XCTestCase {
    private var vault: URL!
    private let rootID = UUID()
    private let a = UUID()
    private let b = UUID()

    override func setUpWithError() throws { vault = try makeTempDir("VaultScannerTests") }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: vault) }

    private var info: VaultInfo {
        VaultInfo(roots: [VaultInfo.RootFolder(rootID: rootID, folderName: "Project", isSynced: true)])
    }

    private func file(_ path: String) -> URL { vault.appendingPathComponent(path) }
    private func loc(_ path: String) -> NoteLocation { NoteLocation(rootID: rootID, path: path) }

    func testInfoIsCreatedOnceAndPersisted() throws {
        let first = try VaultScanner.loadOrCreateInfo(vault: vault)
        let second = try VaultScanner.loadOrCreateInfo(vault: vault)
        XCTAssertEqual(first, second)
    }

    func testScanRootFoldersAndInbox() throws {
        try put(tracked(a), at: file("Project/docs/idea.md"))
        try put(tracked(b), at: file("2026-10-11-new.md"))
        try put("# untracked\n", at: file("Project/plain.md"))
        try put("# untracked inbox\n", at: file("loose.md"))
        try put(tracked(UUID()), at: file("Elsewhere/x.md"))
        try put(tracked(UUID()), at: file(".stickies-trash/2026-10-01/Project/old.md"))

        let manifest = try VaultScanner.scan(vault: vault, info: info)
        XCTAssertEqual(Set(manifest.notes.map(\.location)), [loc("docs/idea.md"), .inbox("2026-10-11-new.md")])
        XCTAssertEqual(manifest.unreadable, [loc("plain.md")], "untracked files in root folders are reported")
    }

    func testICloudPlaceholderIsUnreadable() throws {
        try put("placeholder", at: file("Project/docs/.idea.md.icloud"))
        let manifest = try VaultScanner.scan(vault: vault, info: info)
        XCTAssertEqual(manifest.unreadable, [loc("docs/idea.md")])
    }

    func testMissingRootFolderStopsTheScan() throws {
        XCTAssertThrowsError(try VaultScanner.scan(vault: vault, info: info)) { error in
            XCTAssertEqual(error as? VaultScanner.Failure, .missingRootFolder("Project"))
        }
    }

    func testApplyingRoots() throws {
        let removed = UUID()
        var current = info
        current.roots.append(VaultInfo.RootFolder(rootID: removed, folderName: "Old", isSynced: true))
        try FileManager.default.createDirectory(at: file("Project"), withIntermediateDirectories: true)

        let newRoot = UUID()
        let mac: [VaultInfo.RootFolder] = [
            VaultInfo.RootFolder(rootID: rootID, folderName: "Project", isSynced: true),
            VaultInfo.RootFolder(rootID: removed, folderName: "Old", isSynced: false),
            VaultInfo.RootFolder(rootID: newRoot, folderName: "Notes", isSynced: true),
        ]
        let next = try VaultScanner.applyingRoots(mac, to: current, vault: vault)
        XCTAssertEqual(next.roots.map(\.rootID), [rootID, newRoot], "removed root without folder is forgotten")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file("Notes").path), "new root folder is created")

        try FileManager.default.removeItem(at: file("Project"))
        XCTAssertThrowsError(try VaultScanner.applyingRoots(mac, to: next, vault: vault)) { error in
            XCTAssertEqual(error as? VaultScanner.Failure, .missingRootFolder("Project"))
        }
    }

    func testKnownImagesAreReported() throws {
        try put(tracked(a, "![x](a.png)\n"), at: file("Project/idea.md"))
        try put("png", at: file("Project/a.png"))
        try put("png", at: file("Project/known.png"))
        let manifest = try VaultScanner.scan(
            vault: vault,
            info: info,
            knownImages: [ImageKey(rootID: rootID, path: "known.png"), ImageKey(rootID: rootID, path: "missing.png")]
        )
        XCTAssertEqual(manifest.images.map(\.key.path), ["a.png", "known.png"])
    }
}
