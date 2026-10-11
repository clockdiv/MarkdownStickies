import Foundation
import XCTest
@testable import MarkdownStickiesCore

/// End to end: a real Mac folder and a real iOS vault in temp directories, connected in memory.
final class SyncSessionTests: XCTestCase {
    private var dir: URL!
    private let rootID = UUID(uuidString: "11111111-0000-4000-8000-000000000000")!
    private let macID = UUID()
    private let phoneID = UUID()
    private let now = ISO8601DateFormatter().date(from: "2026-10-11T12:00:00Z")!
    private var iosEditors = EditorRegistry()

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SyncSessionTests-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        for sub in ["mac/Project", "vault", "state", "mac-trash", "backups"] {
            try FileManager.default.createDirectory(at: dir.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
        iosEditors = EditorRegistry()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - Fixture

    private var macRoot: URL { dir.appendingPathComponent("mac/Project") }
    private var vault: URL { dir.appendingPathComponent("vault") }
    private func mac(_ path: String) -> URL { macRoot.appendingPathComponent(path) }
    private func phone(_ path: String) -> URL { vault.appendingPathComponent("Project").appendingPathComponent(path) }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func text(_ url: URL) -> String? {
        (try? Data(contentsOf: url)).map { String(decoding: $0, as: UTF8.self) }
    }

    private func note(_ id: UUID, _ body: String) -> String {
        "---\nstickies-id: \(id.uuidString)\n---\n\n\(body)\n"
    }

    private var macConfiguration: MacSyncSession.Configuration {
        MacSyncSession.Configuration(
            deviceID: macID,
            deviceName: "Mac",
            stateRoot: dir.appendingPathComponent("state"),
            roots: [SyncRoot(id: rootID, url: macRoot, isSynced: true)],
            config: .empty,
            defaultRootID: rootID,
            now: now,
            timeZone: TimeZone(identifier: "UTC")!
        )
    }

    private var macWriter: NoteWriter {
        NoteWriter(
            trash: FolderTrash(vault: dir.appendingPathComponent("mac-trash")),
            backup: BackupFolder(directory: dir.appendingPathComponent("backups")),
            editors: EditorRegistry()
        )
    }

    private var iosWriter: NoteWriter {
        let trash = FolderTrash(vault: vault)
        return NoteWriter(trash: trash, backup: trash, editors: iosEditors)
    }

    private struct Run {
        var mac: SyncOutcome
        var ios: SyncOutcome
        var macSummary: SyncSummary? {
            if case .completed(let summary) = mac { return summary }
            return nil
        }
    }

    private func sync(
        macFilter: (@Sendable (SyncMessage) -> Bool)? = nil,
        iosFilter: (@Sendable (SyncMessage) -> Bool)? = nil,
        confirm: Bool = false,
        idleTimeout: TimeInterval = 2
    ) async -> Run {
        let (macSide, iosSide) = InMemorySyncConnection.pair(idleTimeout: idleTimeout)
        macSide.sendFilter = macFilter
        iosSide.sendFilter = iosFilter
        let hooks = MacSyncSession.Hooks(confirmBulkTrash: { _ in confirm })
        async let macOutcome = MacSyncSession.run(connection: macSide, configuration: macConfiguration, writer: macWriter, hooks: hooks)
        async let iosOutcome = IOSSyncResponder.run(
            connection: iosSide,
            configuration: .init(deviceID: phoneID, deviceName: "iPhone", vault: vault, storage: dir.appendingPathComponent("ios-storage")),
            writer: iosWriter
        )
        return await Run(mac: macOutcome, ios: iosOutcome)
    }

    /// Allows the first `count` messages, then drops the connection.
    private func dropAfter(_ count: Int) -> @Sendable (SyncMessage) -> Bool {
        let counter = Counter()
        return { _ in counter.next() <= count }
    }

    /// Tracked notes by id → content, for one device.
    private func notes(under folder: URL) -> [UUID: String] {
        var result: [UUID: String] = [:]
        let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "md", let data = try? Data(contentsOf: url),
                  let id = StickiesFrontmatter.id(in: data) else { continue }
            result[id] = String(decoding: data, as: UTF8.self)
        }
        return result
    }

    // MARK: - Basic flows

    func testFirstSyncCopiesTrackedNotesAndImagesOnly() async throws {
        let a = UUID()
        try write(note(a, "![x](img/a.png)"), to: mac("docs/idea.md"))
        try write("png", to: mac("docs/img/a.png"))
        try write("# README without frontmatter\n", to: mac("README.md"))
        try write("unreferenced", to: mac("docs/img/other.png"))

        let run = await sync()
        XCTAssertEqual(run.macSummary?.created, 1)
        XCTAssertEqual(run.macSummary?.isFirstSync, true)
        XCTAssertEqual(text(phone("docs/idea.md")), note(a, "![x](img/a.png)"))
        XCTAssertEqual(text(phone("docs/img/a.png")), "png")
        XCTAssertNil(text(phone("README.md")))
        XCTAssertNil(text(phone("docs/img/other.png")))
        XCTAssertEqual(text(mac("README.md")), "# README without frontmatter\n", "untracked files are never touched")

        let again = await sync()
        XCTAssertEqual(again.macSummary?.changedNothing, true)
        XCTAssertEqual(again.macSummary?.isFirstSync, false)
    }

    func testEditOnIOSReachesMacAndKeepsABackup() async throws {
        let a = UUID()
        try write(note(a, "one"), to: mac("idea.md"))
        _ = await sync()
        try write(note(a, "two"), to: phone("idea.md"))

        let run = await sync()
        XCTAssertEqual(run.macSummary?.updated, 1)
        XCTAssertEqual(text(mac("idea.md")), note(a, "two"))
        let backups = notes(under: dir.appendingPathComponent("backups"))
        XCTAssertEqual(backups[a], note(a, "one"))
    }

    func testDeleteOnIOSMovesMacNoteToTrashAndItDoesNotComeBack() async throws {
        let a = UUID()
        try write(note(a, "one"), to: mac("idea.md"))
        _ = await sync()
        try FileManager.default.removeItem(at: phone("idea.md"))

        let run = await sync()
        XCTAssertEqual(run.macSummary?.trashed, 1)
        XCTAssertNil(text(mac("idea.md")))
        XCTAssertEqual(notes(under: dir.appendingPathComponent("mac-trash/Stickies Trash"))[a], note(a, "one"))

        _ = await sync()
        XCTAssertNil(text(mac("idea.md")))
        XCTAssertNil(text(phone("idea.md")))
    }

    func testConflictKeepsBothVersions() async throws {
        let a = UUID()
        try write(note(a, "base"), to: mac("idea.md"))
        _ = await sync()
        try write(note(a, "mac edit"), to: mac("idea.md"))
        try write(note(a, "phone edit"), to: phone("idea.md"))

        let run = await sync()
        XCTAssertEqual(run.macSummary?.conflictCopies, 1)
        let copyName = "idea (conflict iPhone 2026-10-11).md"
        let copyID = ConflictCopy.id(originalID: a, sourceFileHash: NoteHashing.fileHash(Data(note(a, "phone edit").utf8)))

        XCTAssertEqual(text(mac("idea.md")), note(a, "mac edit"))
        XCTAssertEqual(text(phone("idea.md")), note(a, "mac edit"))
        let copy = try XCTUnwrap(text(mac(copyName)))
        XCTAssertTrue(copy.contains("phone edit"))
        XCTAssertEqual(StickiesFrontmatter.id(in: Data(copy.utf8)), copyID)
        XCTAssertEqual(StickiesFrontmatter.conflictOf(in: Data(copy.utf8)), a)
        XCTAssertEqual(text(phone(copyName)), copy)

        let store = SyncStateStore(directory: SyncStateStore.directory(
            in: dir.appendingPathComponent("state"), deviceID: phoneID, vaultID: try VaultScanner.loadOrCreateInfo(vault: vault, storage: dir.appendingPathComponent("ios-storage")).vaultID
        ))
        XCTAssertEqual(store.conflictBase(for: copyID).map { String(decoding: $0, as: UTF8.self) }, note(a, "base"))

        let again = await sync()
        XCTAssertEqual(again.macSummary?.changedNothing, true, "the conflict doesn't come back")
    }

    func testInboxNoteIsPlacedInDefaultRoot() async throws {
        _ = await sync()   // creates the root folder on iOS
        let e = UUID()
        try write(note(e, "from the phone"), to: vault.appendingPathComponent("2026-10-11-new.md"))

        let run = await sync()
        XCTAssertEqual(run.macSummary?.created, 1)
        XCTAssertEqual(text(mac("2026-10-11-new.md")), note(e, "from the phone"))
        XCTAssertEqual(text(phone("2026-10-11-new.md")), note(e, "from the phone"))
        XCTAssertNil(text(vault.appendingPathComponent("2026-10-11-new.md")), "moved out of the Inbox")
    }

    func testMissingRootFolderOnIOSStopsWithoutChanges() async throws {
        let a = UUID()
        try write(note(a, "one"), to: mac("idea.md"))
        _ = await sync()
        try FileManager.default.removeItem(at: vault.appendingPathComponent("Project"))

        let run = await sync()
        guard case .failed(let message) = run.mac else { return XCTFail("expected failure, got \(run.mac)") }
        XCTAssertTrue(message.contains("Folder 'Project' is missing"), message)
        XCTAssertEqual(text(mac("idea.md")), note(a, "one"), "nothing trashed on the Mac")
    }

    func testBulkTrashDeclinedChangesNothing() async throws {
        let ids = (0..<11).map { _ in UUID() }
        for (index, id) in ids.enumerated() { try write(note(id, "n\(index)"), to: mac("n\(index).md")) }
        _ = await sync()
        for index in ids.indices { try FileManager.default.removeItem(at: phone("n\(index).md")) }

        let declined = await sync(confirm: false)
        XCTAssertEqual(declined.mac, .cancelled)
        XCTAssertEqual(declined.ios, .cancelled)
        XCTAssertEqual(notes(under: macRoot).count, 11)

        let confirmed = await sync(confirm: true)
        XCTAssertEqual(confirmed.macSummary?.trashed, 11)
        XCTAssertEqual(notes(under: macRoot).count, 0)
    }

    func testUnsavedEditsOnIOSAreNotOverwritten() async throws {
        let a = UUID()
        try write(note(a, "one"), to: mac("idea.md"))
        _ = await sync()
        try write(note(a, "two"), to: mac("idea.md"))
        iosEditors.setUnsavedEdits(true, for: phone("idea.md"))

        let run = await sync()
        XCTAssertEqual(run.macSummary?.failedSteps.map(\.reason), ["the note has unsaved edits"])
        XCTAssertEqual(text(phone("idea.md")), note(a, "one"))

        iosEditors.setUnsavedEdits(false, for: phone("idea.md"))
        _ = await sync()
        XCTAssertEqual(text(phone("idea.md")), note(a, "two"), "picked up at the next sync")
    }

    func testSilentPeerTimesOut() async throws {
        let (macSide, silentSide) = InMemorySyncConnection.pair(idleTimeout: 0.3)
        let outcome = await MacSyncSession.run(connection: macSide, configuration: macConfiguration, writer: macWriter)
        withExtendedLifetime(silentSide) {}
        guard case .failed(let message) = outcome else { return XCTFail("expected failure") }
        XCTAssertTrue(message.contains("stopped responding"), message)
    }

    // MARK: - Fault injection

    /// Sets up synced notes, changes both sides, then cuts the connection after every possible
    /// message (from either side). After one clean sync, both devices must have converged with
    /// nothing lost and no extra conflict copies; a further sync must change nothing.
    func testInterruptedSyncsAlwaysRecover() async throws {
        let (a, b, c, d, e) = (UUID(), UUID(), UUID(), UUID(), UUID())

        func prepareScenario() async throws {
            try? FileManager.default.removeItem(at: dir)
            try setUpWithError()
            try write(note(a, "a base"), to: mac("a.md"))
            try write(note(b, "b base"), to: mac("sub/b.md"))
            try write(note(c, "c base"), to: mac("c.md"))
            _ = await sync()
            try write(note(a, "a mac"), to: mac("a.md"))
            try write(note(a, "a phone"), to: phone("a.md"))
            try write(note(b, "b phone"), to: phone("sub/b.md"))
            try FileManager.default.removeItem(at: phone("c.md"))
            try write(note(d, "d mac"), to: mac("d.md"))
            try write(note(e, "e phone"), to: vault.appendingPathComponent("e.md"))
        }

        func checkRecovered(_ label: String) async throws {
            let clean = await sync()
            XCTAssertNotNil(clean.macSummary, "\(label): clean sync failed: \(clean.mac)")

            let macNotes = notes(under: macRoot)
            let phoneNotes = notes(under: vault.appendingPathComponent("Project"))
            XCTAssertEqual(macNotes, phoneNotes, "\(label): devices didn't converge")
            XCTAssertEqual(macNotes[a], note(a, "a mac"), label)
            XCTAssertEqual(macNotes[b], note(b, "b phone"), label)
            XCTAssertNil(macNotes[c], label)
            XCTAssertEqual(macNotes[d], note(d, "d mac"), label)
            XCTAssertEqual(macNotes[e], note(e, "e phone"), label)

            let copies = macNotes.filter { StickiesFrontmatter.conflictOf(in: Data($0.value.utf8)) == a }
            XCTAssertEqual(copies.count, 1, "\(label): exactly one conflict copy")
            XCTAssertTrue(copies.first?.value.contains("a phone") == true, "\(label): the phone edit survives")

            let stable = await sync()
            XCTAssertEqual(stable.macSummary?.changedNothing, true, "\(label): not stable: \(String(describing: stable.macSummary))")
        }

        // Count the messages of an uninterrupted run.
        try await prepareScenario()
        let macCount = Counter()
        let iosCount = Counter()
        _ = await sync(
            macFilter: { _ in _ = macCount.next(); return true },
            iosFilter: { _ in _ = iosCount.next(); return true }
        )
        let macMessages = macCount.value
        let iosMessages = iosCount.value
        XCTAssertGreaterThan(macMessages, 5)

        for cut in 0..<macMessages {
            try await prepareScenario()
            _ = await sync(macFilter: dropAfter(cut))
            try await checkRecovered("Mac cut after \(cut)")
        }
        for cut in 0..<iosMessages {
            try await prepareScenario()
            _ = await sync(iosFilter: dropAfter(cut))
            try await checkRecovered("iOS cut after \(cut)")
        }
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var value = 0

    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }
}
