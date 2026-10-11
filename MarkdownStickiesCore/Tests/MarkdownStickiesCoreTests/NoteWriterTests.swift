import Foundation
import XCTest
@testable import MarkdownStickiesCore

final class NoteWriterTests: XCTestCase {
    private var vault: URL!
    private var trash: FolderTrash!
    private var editors: EditorRegistry!
    private var writer: NoteWriter!
    private let day = ISO8601DateFormatter().date(from: "2026-10-11T12:00:00Z")!

    override func setUpWithError() throws {
        vault = FileManager.default.temporaryDirectory
            .appendingPathComponent("NoteWriterTests-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        let fixed = day
        trash = FolderTrash(vault: vault, now: { fixed })
        editors = EditorRegistry()
        writer = NoteWriter(trash: trash, backup: trash, editors: editors)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: vault)
    }

    private func url(_ path: String) -> URL { vault.appendingPathComponent(path) }

    private func put(_ text: String, _ path: String) throws -> String {
        let data = Data(text.utf8)
        try FileManager.default.createDirectory(at: url(path).deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url(path))
        return NoteHashing.fileHash(data)
    }

    private func read(_ path: String) -> String? {
        (try? Data(contentsOf: url(path))).map { String(decoding: $0, as: UTF8.self) }
    }

    private func trashed(_ path: String) -> String? {
        read(".stickies-trash/2026-10-11/\(path)")
    }

    private func assertFails(
        _ expected: NoteWriter.Failure,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ body: () async throws -> Void
    ) async {
        do {
            try await body()
            XCTFail("expected \(expected)", file: file, line: line)
        } catch let failure as NoteWriter.Failure {
            if case .changedOnDisk = expected, case .changedOnDisk = failure { return }
            XCTAssertEqual(failure, expected, file: file, line: line)
        } catch {
            XCTFail("unexpected \(error)", file: file, line: line)
        }
    }

    // MARK: - write

    func testWriteNewFileCreatesFoldersAndReturnsHash() async throws {
        let hash = try await writer.write(Data("new".utf8), to: url("a/b/new.md"), expect: .absent, origin: .sync)
        XCTAssertEqual(read("a/b/new.md"), "new")
        XCTAssertEqual(hash, NoteHashing.fileHash(Data("new".utf8)))
        XCTAssertTrue(writer.recentWrites.contains(url("a/b/new.md")))
    }

    func testWriteAbsentRefusesExistingFileEvenWithOtherCase() async throws {
        _ = try put("old", "Idea.md")
        await assertFails(.alreadyExists) {
            try await self.writer.write(Data("x".utf8), to: self.url("idea.md"), expect: .absent, origin: .sync)
        }
        XCTAssertEqual(read("Idea.md"), "old")
    }

    func testOverwriteChecksHashAndKeepsACopy() async throws {
        let hash = try put("old", "idea.md")
        try await writer.write(Data("new".utf8), to: url("idea.md"), expect: .hash(hash), origin: .sync)
        XCTAssertEqual(read("idea.md"), "new")
        XCTAssertEqual(trashed("idea.md"), "old", "rule 3: the previous version is kept")
    }

    func testOverwriteRefusesChangedFile() async throws {
        _ = try put("edited meanwhile", "idea.md")
        await assertFails(.changedOnDisk(expected: "", found: "")) {
            try await self.writer.write(Data("new".utf8), to: self.url("idea.md"), expect: .hash("stale"), origin: .sync)
        }
        XCTAssertEqual(read("idea.md"), "edited meanwhile")
    }

    func testOverwriteOfMissingFileFails() async {
        await assertFails(.missing) {
            try await self.writer.write(Data("new".utf8), to: self.url("gone.md"), expect: .hash("h"), origin: .sync)
        }
        XCTAssertNil(read("gone.md"))
    }

    func testSyncRefusesNotesWithUnsavedEditsButTheAppMayWrite() async throws {
        let hash = try put("old", "idea.md")
        editors.setUnsavedEdits(true, for: url("idea.md"))
        await assertFails(.unsavedEdits) {
            try await self.writer.write(Data("sync".utf8), to: self.url("idea.md"), expect: .hash(hash), origin: .sync)
        }
        try await writer.write(Data("editor".utf8), to: url("idea.md"), expect: .hash(hash), origin: .app)
        XCTAssertEqual(read("idea.md"), "editor")

        editors.setUnsavedEdits(false, for: url("idea.md"))
        XCTAssertFalse(editors.hasUnsavedEdits(url("idea.md")))
    }

    func testNoTempFilesAreLeftBehind() async throws {
        let hash = try put("old", "idea.md")
        try await writer.write(Data("new".utf8), to: url("idea.md"), expect: .hash(hash), origin: .sync)
        let names = try FileManager.default.contentsOfDirectory(atPath: vault.path)
        XCTAssertFalse(names.contains { $0.contains("stickies-tmp") })
    }

    // MARK: - move

    func testMoveChecksHashAndCreatesFolders() async throws {
        let hash = try put("text", "idea.md")
        try await writer.move(from: url("idea.md"), to: url("sub/plan.md"), expectHash: hash, origin: .sync)
        XCTAssertNil(read("idea.md"))
        XCTAssertEqual(read("sub/plan.md"), "text")
    }

    func testMoveNeverOverwrites() async throws {
        let hash = try put("mine", "idea.md")
        _ = try put("other", "Plan.md")
        await assertFails(.alreadyExists) {
            try await self.writer.move(from: self.url("idea.md"), to: self.url("plan.md"), expectHash: hash, origin: .sync)
        }
        XCTAssertEqual(read("idea.md"), "mine")
        XCTAssertEqual(read("Plan.md"), "other")
    }

    func testMoveRefusesChangedSource() async throws {
        _ = try put("changed", "idea.md")
        await assertFails(.changedOnDisk(expected: "", found: "")) {
            try await self.writer.move(from: self.url("idea.md"), to: self.url("plan.md"), expectHash: "stale", origin: .sync)
        }
        XCTAssertEqual(read("idea.md"), "changed")
    }

    func testCapitalizationOnlyRename() async throws {
        let hash = try put("text", "Idea.md")
        try await writer.move(from: url("Idea.md"), to: url("idea.md"), expectHash: hash, origin: .sync)
        let names = try FileManager.default.contentsOfDirectory(atPath: vault.path)
        XCTAssertTrue(names.contains("idea.md"))
        XCTAssertFalse(names.contains("Idea.md"))
        XCTAssertFalse(names.contains { $0.contains("stickies-move") })
    }

    // MARK: - trash

    func testTrashChecksHashAndMovesIntoDatedTrash() async throws {
        let hash = try put("bye", "sub/idea.md")
        try await writer.trash(url("sub/idea.md"), expectHash: hash, origin: .sync)
        XCTAssertNil(read("sub/idea.md"))
        XCTAssertEqual(trashed("sub/idea.md"), "bye")
    }

    func testTrashRefusesChangedFile() async throws {
        _ = try put("edited", "idea.md")
        await assertFails(.changedOnDisk(expected: "", found: "")) {
            try await self.writer.trash(self.url("idea.md"), expectHash: "stale", origin: .sync)
        }
        XCTAssertEqual(read("idea.md"), "edited")
    }

    func testTrashingTheSameNameTwiceKeepsBoth() async throws {
        let first = try put("one", "idea.md")
        try await writer.trash(url("idea.md"), expectHash: first, origin: .sync)
        let second = try put("two", "idea.md")
        try await writer.trash(url("idea.md"), expectHash: second, origin: .sync)
        XCTAssertEqual(trashed("idea.md"), "one")
        XCTAssertEqual(trashed("idea (2).md"), "two")
    }

    // MARK: - retention

    func testPurgeRemovesOnlyOldDayFolders() throws {
        let trashDir = trash.directory
        for name in ["2026-09-01", "2026-09-20", "2026-10-11", "not-a-date"] {
            try FileManager.default.createDirectory(at: trashDir.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        trash.purge()
        let left = try FileManager.default.contentsOfDirectory(atPath: trashDir.path).sorted()
        XCTAssertEqual(left, ["2026-09-20", "2026-10-11", "not-a-date"])
    }

    func testBackupFolderMirrorsAbsolutePath() throws {
        let fixed = day
        let backups = BackupFolder(directory: vault.appendingPathComponent("Backups"), now: { fixed })
        _ = try put("old", "project/idea.md")
        try backups.preserveCopy(of: url("project/idea.md"))
        let copy = vault.appendingPathComponent("Backups/2026-10-11")
            .appendingPathComponent(url("project/idea.md").path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
        XCTAssertEqual(try String(contentsOf: copy, encoding: .utf8), "old")
    }
}

final class SyncStateStoreTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("SyncStateStoreTests-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testBaseRoundTripAndEmptyWhenMissing() throws {
        let store = SyncStateStore(directory: dir)
        XCTAssertFalse(store.hasBase)
        XCTAssertEqual(try store.loadBase(), .empty)

        let root = UUID()
        let id = UUID()
        let key = ImageKey(rootID: root, path: "img/a.png")
        let base = SyncBase(
            notes: [id: SyncBase.Note(location: NoteLocation(rootID: root, path: "idea.md"), fileHash: "f", restHash: "r", color: "blue")],
            images: [key: "i"]
        )
        try store.saveBase(base)
        XCTAssertTrue(store.hasBase)
        XCTAssertEqual(try store.loadBase(), base)
    }

    func testBaseTextAndConflictSnapshots() throws {
        let store = SyncStateStore(directory: dir)
        let original = UUID()
        let copy = UUID()
        try store.saveBaseText(Data("base".utf8), for: original)
        try store.snapshotConflictBase(copy: copy, original: original)
        XCTAssertEqual(store.conflictBase(for: copy), Data("base".utf8))

        store.pruneConflictBases(keeping: [])
        XCTAssertNil(store.conflictBase(for: copy))
        XCTAssertEqual(store.baseText(for: original), Data("base".utf8))
    }

    func testRootNamesAreStableAndNeverReused() {
        let a = UUID(), b = UUID(), c = UUID()
        let first = RootRecord.assign(existing: [], synced: [(a, "/Users/me/Notes"), (b, "/Users/me/work/notes")])
        XCTAssertEqual(first.map(\.iosFolderName), ["Notes", "notes (2)"])

        // Root a is removed; a new root named "Notes" must not take its folder name.
        let second = RootRecord.assign(existing: first, synced: [(b, "/Users/me/work/notes"), (c, "/Volumes/X/Notes")])
        XCTAssertEqual(second.first { $0.rootID == a }?.isSynced, false)
        XCTAssertEqual(second.first { $0.rootID == a }?.iosFolderName, "Notes")
        XCTAssertEqual(second.first { $0.rootID == b }?.iosFolderName, "notes (2)")
        XCTAssertEqual(second.first { $0.rootID == c }?.iosFolderName, "Notes (3)")
    }
}
