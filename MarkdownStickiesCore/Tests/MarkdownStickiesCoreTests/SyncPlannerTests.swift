import Foundation
import XCTest
@testable import MarkdownStickiesCore

/// One test per cell of the v1 decision tables (spec §3.3, §3.5), plus guards and fallbacks.
final class SyncPlannerTests: XCTestCase {
    private let root = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
    private let otherRoot = UUID(uuidString: "00000000-0000-4000-8000-000000000002")!
    private let a = UUID(uuidString: "AAAAAAAA-0000-4000-8000-000000000000")!
    private let b = UUID(uuidString: "BBBBBBBB-0000-4000-8000-000000000000")!
    private let now = ISO8601DateFormatter().date(from: "2026-10-11T12:00:00Z")!

    // MARK: - Helpers

    private func loc(_ path: String, root: UUID? = nil) -> NoteLocation {
        NoteLocation(rootID: root ?? self.root, path: path)
    }

    private func note(_ id: UUID, _ path: String, _ hash: String, refs: [String] = []) -> ManifestNote {
        ManifestNote(id: id, location: loc(path), fileHash: hash, restHash: hash, imageRefs: refs)
    }

    private func inboxNote(_ id: UUID, _ filename: String, _ hash: String) -> ManifestNote {
        ManifestNote(id: id, location: .inbox(filename), fileHash: hash, restHash: hash)
    }

    private func base(_ entries: [(UUID, String, String)], images: [ImageKey: String] = [:]) -> SyncBase {
        var notes: [UUID: SyncBase.Note] = [:]
        for (id, path, hash) in entries {
            notes[id] = SyncBase.Note(location: loc(path), fileHash: hash, restHash: hash)
        }
        return SyncBase(notes: notes, images: images)
    }

    private func context(
        defaultRoot: UUID? = nil,
        macAllows: @escaping (NoteLocation) -> Bool = { _ in true }
    ) -> SyncPlanner.Context {
        SyncPlanner.Context(
            defaultRootID: defaultRoot ?? root,
            peerDeviceName: "iPhone",
            now: now,
            timeZone: TimeZone(identifier: "UTC")!,
            macAllows: macAllows
        )
    }

    private func plan(
        mac: SyncManifest = SyncManifest(),
        ios: SyncManifest = SyncManifest(),
        base: SyncBase = .empty,
        context: SyncPlanner.Context? = nil
    ) -> SyncPlan {
        SyncPlanner.plan(mac: mac, ios: ios, base: base, context: context ?? self.context())
    }

    private func image(_ path: String, _ hash: String) -> ManifestImage {
        ManifestImage(key: ImageKey(rootID: root, path: path), hash: hash)
    }

    private func key(_ path: String) -> ImageKey { ImageKey(rootID: root, path: path) }

    // MARK: - Content: both present

    func testUnchangedOnBothSidesDoesNothing() {
        let p = plan(
            mac: SyncManifest(notes: [note(a, "idea.md", "h1")]),
            ios: SyncManifest(notes: [note(a, "idea.md", "h1")]),
            base: base([(a, "idea.md", "h1")])
        )
        XCTAssertEqual(p.steps, [])
        XCTAssertEqual(p.skipped, [])
    }

    func testModifiedOnMacIsWrittenToIOS() {
        let p = plan(
            mac: SyncManifest(notes: [note(a, "idea.md", "h2")]),
            ios: SyncManifest(notes: [note(a, "idea.md", "h1")]),
            base: base([(a, "idea.md", "h1")])
        )
        XCTAssertEqual(p.steps.map(\.action), [
            .writeNote(id: a, at: loc("idea.md"), expect: .hash("h1"), source: .macNote(a)),
        ])
        XCTAssertEqual(p.steps.first?.device, .ios)
    }

    func testModifiedOnIOSIsWrittenToMac() {
        let p = plan(
            mac: SyncManifest(notes: [note(a, "idea.md", "h1")]),
            ios: SyncManifest(notes: [note(a, "idea.md", "h2")]),
            base: base([(a, "idea.md", "h1")])
        )
        XCTAssertEqual(p.steps.map(\.action), [
            .writeNote(id: a, at: loc("idea.md"), expect: .hash("h1"), source: .iosNote(a)),
        ])
        XCTAssertEqual(p.steps.first?.device, .mac)
    }

    func testSameChangeOnBothSidesDoesNothing() {
        let p = plan(
            mac: SyncManifest(notes: [note(a, "idea.md", "h2")]),
            ios: SyncManifest(notes: [note(a, "idea.md", "h2")]),
            base: base([(a, "idea.md", "h1")])
        )
        XCTAssertEqual(p.steps, [])
    }

    func testModifiedOnBothSidesMakesConflictCopyBeforeOverwritingIOS() {
        let p = plan(
            mac: SyncManifest(notes: [note(a, "docs/idea.md", "mac")]),
            ios: SyncManifest(notes: [note(a, "docs/idea.md", "ios")]),
            base: base([(a, "docs/idea.md", "h1")])
        )
        let copyID = ConflictCopy.id(originalID: a, sourceFileHash: "ios")
        let copyLocation = loc("docs/idea (conflict iPhone 2026-10-11).md")

        XCTAssertEqual(p.steps.count, 3)
        let copy = p.steps[0]
        XCTAssertEqual(copy.device, .mac)
        XCTAssertEqual(copy.action, .writeConflictCopy(
            id: copyID,
            original: a,
            at: copyLocation,
            source: .iosNoteAsConflictCopy(original: a, copy: copyID)
        ))

        let iosCopy = p.steps[1]
        XCTAssertEqual(iosCopy.device, .ios)
        XCTAssertEqual(iosCopy.action, .writeNote(id: copyID, at: copyLocation, expect: .absent, source: .macNote(copyID)))
        XCTAssertEqual(iosCopy.dependsOn, [copy.id])

        let overwrite = p.steps[2]
        XCTAssertEqual(overwrite.action, .writeNote(id: a, at: loc("docs/idea.md"), expect: .hash("ios"), source: .macNote(a)))
        XCTAssertEqual(overwrite.dependsOn, [copy.id])
    }

    func testExistingConflictCopyIsReusedNotDuplicated() {
        let copyID = ConflictCopy.id(originalID: a, sourceFileHash: "ios")
        let p = plan(
            mac: SyncManifest(notes: [
                note(a, "idea.md", "mac"),
                note(copyID, "idea (conflict iPhone 2026-10-10).md", "copy"),
            ]),
            ios: SyncManifest(notes: [note(a, "idea.md", "ios")]),
            base: base([(a, "idea.md", "h1")])
        )
        XCTAssertFalse(p.steps.contains { if case .writeConflictCopy = $0.action { return true }; return false })
        XCTAssertTrue(p.steps.contains {
            $0.action == .writeNote(id: a, at: loc("idea.md"), expect: .hash("ios"), source: .macNote(a)) && $0.dependsOn.isEmpty
        })
        // The existing copy reaches iOS as a normal "created on the Mac" note.
        XCTAssertTrue(p.steps.contains {
            $0.action == .writeNote(id: copyID, at: loc("idea (conflict iPhone 2026-10-10).md"), expect: .absent, source: .macNote(copyID))
        })
    }

    func testFirstSyncSameContentDoesNothingDifferentContentConflicts() {
        let same = plan(
            mac: SyncManifest(notes: [note(a, "idea.md", "h")]),
            ios: SyncManifest(notes: [note(a, "idea.md", "h")])
        )
        XCTAssertEqual(same.steps, [])

        let different = plan(
            mac: SyncManifest(notes: [note(a, "idea.md", "mac")]),
            ios: SyncManifest(notes: [note(a, "idea.md", "ios")])
        )
        XCTAssertEqual(different.steps.first?.action.isConflictCopy, true)
        XCTAssertFalse(different.steps.contains { if case .trashNote = $0.action { return true }; return false })
    }

    // MARK: - Content: one side only

    func testCreatedOnMacIsWrittenToIOS() {
        let p = plan(mac: SyncManifest(notes: [note(a, "new.md", "h")]))
        XCTAssertEqual(p.steps.map(\.action), [
            .writeNote(id: a, at: loc("new.md"), expect: .absent, source: .macNote(a)),
        ])
    }

    func testCreatedOnIOSInRootFolderIsWrittenToMac() {
        let p = plan(ios: SyncManifest(notes: [note(a, "sub/new.md", "h")]))
        XCTAssertEqual(p.steps.map(\.action), [
            .writeNote(id: a, at: loc("sub/new.md"), expect: .absent, source: .iosNote(a)),
        ])
        XCTAssertEqual(p.steps.first?.device, .mac)
    }

    func testInboxNoteGoesToDefaultRootThenMovesOnIOS() {
        let p = plan(ios: SyncManifest(notes: [inboxNote(a, "2026-10-11-idea.md", "h")]))
        XCTAssertEqual(p.steps.count, 2)
        XCTAssertEqual(p.steps[0].device, .mac)
        XCTAssertEqual(p.steps[0].action, .writeNote(id: a, at: loc("2026-10-11-idea.md"), expect: .absent, source: .iosNote(a)))
        XCTAssertEqual(p.steps[1].device, .ios)
        XCTAssertEqual(p.steps[1].action, .moveNote(id: a, from: .inbox("2026-10-11-idea.md"), to: loc("2026-10-11-idea.md"), expectHash: "h"))
        XCTAssertEqual(p.steps[1].dependsOn, [p.steps[0].id])
    }

    func testInboxNoteWithoutSyncedRootIsSkipped() {
        var ctx = context()
        ctx.defaultRootID = nil
        let p = plan(ios: SyncManifest(notes: [inboxNote(a, "idea.md", "h")]), context: ctx)
        XCTAssertEqual(p.steps, [])
        XCTAssertEqual(p.skipped, [SyncSkip(noteID: a, reason: .noSyncedFolderForNewNote(.inbox("idea.md")))])
        XCTAssertEqual(p.frozenNoteIDs, [a])
    }

    func testDeletedOnIOSUnchangedOnMacIsTrashedOnMac() {
        let p = plan(
            mac: SyncManifest(notes: [note(a, "idea.md", "h1")]),
            base: base([(a, "idea.md", "h1")])
        )
        XCTAssertEqual(p.steps.map(\.action), [.trashNote(id: a, at: loc("idea.md"), expectHash: "h1")])
        XCTAssertEqual(p.steps.first?.device, .mac)
    }

    func testDeletedOnIOSEditedOnMacIsRestoredOnIOS() {
        let p = plan(
            mac: SyncManifest(notes: [note(a, "idea.md", "h2")]),
            base: base([(a, "idea.md", "h1")])
        )
        XCTAssertEqual(p.steps.map(\.action), [
            .writeNote(id: a, at: loc("idea.md"), expect: .absent, source: .macNote(a)),
        ])
        XCTAssertEqual(p.steps.first?.device, .ios)
    }

    func testDeletedOnMacUnchangedOnIOSIsTrashedOnIOS() {
        let p = plan(
            ios: SyncManifest(notes: [note(a, "idea.md", "h1")]),
            base: base([(a, "idea.md", "h1")])
        )
        XCTAssertEqual(p.steps.map(\.action), [.trashNote(id: a, at: loc("idea.md"), expectHash: "h1")])
        XCTAssertEqual(p.steps.first?.device, .ios)
    }

    func testDeletedOnMacEditedOnIOSIsRestoredOnMac() {
        let p = plan(
            ios: SyncManifest(notes: [note(a, "idea.md", "h2")]),
            base: base([(a, "idea.md", "h1")])
        )
        XCTAssertEqual(p.steps.map(\.action), [
            .writeNote(id: a, at: loc("idea.md"), expect: .absent, source: .iosNote(a)),
        ])
        XCTAssertEqual(p.steps.first?.device, .mac)
    }

    func testDeletedOnBothSidesDoesNothing() {
        let p = plan(base: base([(a, "idea.md", "h1")]))
        XCTAssertEqual(p.steps, [])
        XCTAssertEqual(p.skipped, [])
    }

    // MARK: - Unknown, left, duplicates

    func testUnreadableOnMacIsSkippedNotDeleted() {
        let p = plan(
            mac: SyncManifest(unreadable: [loc("idea.md")]),
            ios: SyncManifest(notes: [note(a, "idea.md", "h1")]),
            base: base([(a, "idea.md", "h1")])
        )
        XCTAssertEqual(p.steps, [])
        XCTAssertEqual(p.skipped, [SyncSkip(noteID: a, reason: .unreadable(.mac, loc("idea.md")))])
        XCTAssertEqual(p.frozenNoteIDs, [a])
    }

    func testUnreadableOnIOSIsSkippedNotDeleted() {
        let p = plan(
            mac: SyncManifest(notes: [note(a, "idea.md", "h1")]),
            ios: SyncManifest(unreadable: [loc("idea.md")]),
            base: base([(a, "idea.md", "h1")])
        )
        XCTAssertEqual(p.steps, [])
        XCTAssertEqual(p.skipped, [SyncSkip(noteID: a, reason: .unreadable(.ios, loc("idea.md")))])
    }

    func testLeftNoteUnchangedOnIOSIsTrashedOnIOSOnly() {
        let p = plan(
            mac: SyncManifest(left: [LeftNote(id: a, location: loc("idea.md"))]),
            ios: SyncManifest(notes: [note(a, "idea.md", "h1")]),
            base: base([(a, "idea.md", "h1")])
        )
        XCTAssertEqual(p.steps.map(\.action), [.trashNote(id: a, at: loc("idea.md"), expectHash: "h1")])
        XCTAssertEqual(p.steps.first?.device, .ios)
    }

    func testLeftNoteEditedOnIOSIsSkipped() {
        let p = plan(
            mac: SyncManifest(left: [LeftNote(id: a, location: loc("idea.md"))]),
            ios: SyncManifest(notes: [note(a, "idea.md", "h2")]),
            base: base([(a, "idea.md", "h1")])
        )
        XCTAssertEqual(p.steps, [])
        XCTAssertEqual(p.skipped, [SyncSkip(noteID: a, reason: .editedOnPeerButNoLongerSynced(loc("idea.md")))])
    }

    func testDuplicateIDsAreSkippedOnBothDevices() {
        let p = plan(
            mac: SyncManifest(notes: [note(a, "idea.md", "h1")]),
            ios: SyncManifest(notes: [note(a, "idea.md", "h1"), note(a, "idea 2.md", "h3")]),
            base: base([(a, "idea.md", "h1")])
        )
        XCTAssertEqual(p.steps, [])
        XCTAssertEqual(p.skipped, [SyncSkip(noteID: a, reason: .duplicateID(.ios, [loc("idea 2.md"), loc("idea.md")]))])
        XCTAssertEqual(p.frozenNoteIDs, [a])
    }

    // MARK: - Paths

    func testMovedOnMacIsMovedOnIOS() {
        let p = plan(
            mac: SyncManifest(notes: [note(a, "plan.md", "h1")]),
            ios: SyncManifest(notes: [note(a, "idea.md", "h1")]),
            base: base([(a, "idea.md", "h1")])
        )
        XCTAssertEqual(p.steps.map(\.action), [.moveNote(id: a, from: loc("idea.md"), to: loc("plan.md"), expectHash: "h1")])
        XCTAssertEqual(p.steps.first?.device, .ios)
    }

    func testMovedOnIOSIsMovedOnMac() {
        let p = plan(
            mac: SyncManifest(notes: [note(a, "idea.md", "h1")]),
            ios: SyncManifest(notes: [note(a, "sub/idea.md", "h1")]),
            base: base([(a, "idea.md", "h1")])
        )
        XCTAssertEqual(p.steps.map(\.action), [.moveNote(id: a, from: loc("idea.md"), to: loc("sub/idea.md"), expectHash: "h1")])
        XCTAssertEqual(p.steps.first?.device, .mac)
    }

    func testMovedOnBothSidesTheMacWins() {
        let p = plan(
            mac: SyncManifest(notes: [note(a, "mac.md", "h1")]),
            ios: SyncManifest(notes: [note(a, "ios.md", "h1")]),
            base: base([(a, "idea.md", "h1")])
        )
        XCTAssertEqual(p.steps.map(\.action), [.moveNote(id: a, from: loc("ios.md"), to: loc("mac.md"), expectHash: "h1")])
    }

    func testEditedAndMovedOnMacWritesThenMovesOnIOS() {
        let p = plan(
            mac: SyncManifest(notes: [note(a, "plan.md", "h2")]),
            ios: SyncManifest(notes: [note(a, "idea.md", "h1")]),
            base: base([(a, "idea.md", "h1")])
        )
        XCTAssertEqual(p.steps.count, 2)
        XCTAssertEqual(p.steps[0].action, .writeNote(id: a, at: loc("idea.md"), expect: .hash("h1"), source: .macNote(a)))
        XCTAssertEqual(p.steps[1].action, .moveNote(id: a, from: loc("idea.md"), to: loc("plan.md"), expectHash: "h2"))
        XCTAssertEqual(p.steps[1].dependsOn, [p.steps[0].id])
    }

    func testEditedOnIOSAndMovedOnIOSWritesThenMovesOnMac() {
        let p = plan(
            mac: SyncManifest(notes: [note(a, "idea.md", "h1")]),
            ios: SyncManifest(notes: [note(a, "plan.md", "h2")]),
            base: base([(a, "idea.md", "h1")])
        )
        XCTAssertEqual(p.steps.count, 2)
        XCTAssertEqual(p.steps[0].action, .writeNote(id: a, at: loc("idea.md"), expect: .hash("h1"), source: .iosNote(a)))
        XCTAssertEqual(p.steps[1].action, .moveNote(id: a, from: loc("idea.md"), to: loc("plan.md"), expectHash: "h2"))
        XCTAssertEqual(p.steps[1].dependsOn, [p.steps[0].id])
    }

    func testIOSMoveIntoExcludedFolderIsReportedAndNotApplied() {
        let excluded = loc("build/idea.md")
        let p = plan(
            mac: SyncManifest(notes: [note(a, "idea.md", "h1")]),
            ios: SyncManifest(notes: [note(a, "build/idea.md", "h1")]),
            base: base([(a, "idea.md", "h1")]),
            context: context(macAllows: { $0 != excluded })
        )
        XCTAssertEqual(p.steps, [])
        XCTAssertEqual(p.skipped, [SyncSkip(noteID: a, reason: .excludedOnMac(excluded))])
        XCTAssertEqual(p.frozenNoteIDs, [], "a path notice doesn't freeze the note")
    }

    func testCapitalizationOnlyRenameFromIOSIsReported() {
        let p = plan(
            mac: SyncManifest(notes: [note(a, "Idea.md", "h1")]),
            ios: SyncManifest(notes: [note(a, "idea.md", "h1")]),
            base: base([(a, "Idea.md", "h1")])
        )
        XCTAssertEqual(p.steps, [])
        XCTAssertEqual(p.skipped, [SyncSkip(noteID: a, reason: .capitalizationOnlyRename(from: loc("Idea.md"), to: loc("idea.md")))])
    }

    func testCapitalizationOnlyRenameFromMacIsAPlainMoveOnIOS() {
        let p = plan(
            mac: SyncManifest(notes: [note(a, "idea.md", "h1")]),
            ios: SyncManifest(notes: [note(a, "Idea.md", "h1")]),
            base: base([(a, "Idea.md", "h1")])
        )
        XCTAssertEqual(p.steps.map(\.action), [.moveNote(id: a, from: loc("Idea.md"), to: loc("idea.md"), expectHash: "h1")])
    }

    func testNewIOSNoteInExcludedFolderIsSkipped() {
        let p = plan(
            ios: SyncManifest(notes: [note(a, "vendor/x.md", "h")]),
            context: context(macAllows: { !$0.path.hasPrefix("vendor/") })
        )
        XCTAssertEqual(p.steps, [])
        XCTAssertEqual(p.skipped, [SyncSkip(noteID: a, reason: .excludedOnMac(loc("vendor/x.md")))])
    }

    // MARK: - Collisions

    func testWriteToALocationUsedByAnotherNoteIsSkipped() {
        let p = plan(
            mac: SyncManifest(notes: [note(a, "idea.md", "h")]),
            ios: SyncManifest(notes: [note(b, "IDEA.md", "x")]),
            base: base([(b, "IDEA.md", "x")])
        )
        XCTAssertEqual(p.skipped, [SyncSkip(noteID: a, reason: .targetTaken(.ios, loc("idea.md")))])
        XCTAssertFalse(p.steps.contains { $0.action.noteID == a })
    }

    func testSwapIsSkippedAsCollision() {
        let p = plan(
            mac: SyncManifest(notes: [note(a, "two.md", "ha"), note(b, "one.md", "hb")]),
            ios: SyncManifest(notes: [note(a, "one.md", "ha"), note(b, "two.md", "hb")]),
            base: base([(a, "one.md", "ha"), (b, "two.md", "hb")])
        )
        XCTAssertEqual(p.steps, [])
        XCTAssertEqual(Set(p.skipped.compactMap(\.noteID)), [a, b])
    }

    func testTwoInboxNotesWithTheSameNameOnlyTheFirstIsPlaced() {
        let p = plan(ios: SyncManifest(notes: [inboxNote(a, "idea.md", "ha"), inboxNote(b, "Idea.md", "hb")]))
        XCTAssertEqual(p.steps.filter { $0.device == .mac }.count, 1)
        XCTAssertEqual(p.skipped, [SyncSkip(noteID: b, reason: .targetTaken(.mac, loc("Idea.md")))])
    }

    func testConflictCopyNameTakenSkipsTheWholeConflict() {
        let taken = loc("idea (conflict iPhone 2026-10-11).md")
        let p = plan(
            mac: SyncManifest(notes: [note(a, "idea.md", "mac")], unreadable: [taken]),
            ios: SyncManifest(notes: [note(a, "idea.md", "ios")]),
            base: base([(a, "idea.md", "h1")])
        )
        XCTAssertEqual(p.steps, [], "the iOS original must not be overwritten without its copy")
        XCTAssertEqual(p.skipped, [SyncSkip(noteID: a, reason: .targetTaken(.mac, taken))])
    }

    // MARK: - Bulk guard and ordering

    func testBulkTrashOverLimitNeedsConfirmation() {
        func deletions(_ count: Int) -> SyncPlan {
            let ids = (0..<count).map { _ in UUID() }
            return plan(
                mac: SyncManifest(notes: ids.enumerated().map { note($1, "n\($0).md", "h") }),
                base: base(ids.enumerated().map { ($1, "n\($0).md", "h") })
            )
        }
        XCTAssertFalse(deletions(10).needsConfirmation)
        let eleven = deletions(11)
        XCTAssertTrue(eleven.needsConfirmation)
        XCTAssertEqual(eleven.trashedNoteCount[.mac], 11)
    }

    func testMacStepsComeFirstAndPhasesAreOrdered() {
        let c = UUID(uuidString: "CCCCCCCC-0000-4000-8000-000000000000")!
        let p = plan(
            mac: SyncManifest(notes: [note(a, "trash-me.md", "h"), note(b, "moved.md", "h"), note(c, "new.md", "h")]),
            ios: SyncManifest(notes: [note(b, "old.md", "h")]),
            base: base([(a, "trash-me.md", "h"), (b, "old.md", "h")])
        )
        XCTAssertEqual(p.steps.map(\.device), [.mac, .ios, .ios])
        XCTAssertEqual(p.steps.map(\.action.phase), [3, 1, 2])
        XCTAssertEqual(p.steps.map(\.id), [1, 2, 3])
        for step in p.steps {
            XCTAssertTrue(step.dependsOn.allSatisfy { $0 < step.id })
        }
    }

    // MARK: - Images

    func testReferencedImageMissingOnIOSIsSent() {
        let p = plan(
            mac: SyncManifest(notes: [note(a, "idea.md", "h", refs: ["img/a.png"])], images: [image("img/a.png", "i1")]),
            ios: SyncManifest(notes: [note(a, "idea.md", "h", refs: ["img/a.png"])]),
            base: base([(a, "idea.md", "h")])
        )
        XCTAssertEqual(p.steps.map(\.action), [.writeImage(key: key("img/a.png"), expect: .absent, source: .macImage(key("img/a.png")))])
    }

    func testUnreferencedImageIsTrashedOnIOSOnly() {
        let p = plan(
            mac: SyncManifest(notes: [note(a, "idea.md", "h")], images: [image("img/a.png", "i1")]),
            ios: SyncManifest(notes: [note(a, "idea.md", "h")], images: [image("img/a.png", "i1")]),
            base: base([(a, "idea.md", "h")], images: [key("img/a.png"): "i1"])
        )
        XCTAssertEqual(p.steps.map(\.action), [.trashImage(key: key("img/a.png"), expectHash: "i1")])
        XCTAssertEqual(p.steps.first?.device, .ios)
    }

    func testImageChangedOnIOSOnlyIsWrittenToMac() {
        let p = plan(
            mac: SyncManifest(notes: [note(a, "idea.md", "h", refs: ["a.png"])], images: [image("a.png", "i1")]),
            ios: SyncManifest(notes: [note(a, "idea.md", "h", refs: ["a.png"])], images: [image("a.png", "i2")]),
            base: base([(a, "idea.md", "h")], images: [key("a.png"): "i1"])
        )
        XCTAssertEqual(p.steps.map(\.action), [.writeImage(key: key("a.png"), expect: .hash("i1"), source: .iosImage(key("a.png")))])
        XCTAssertEqual(p.steps.first?.device, .mac)
    }

    func testImageChangedOnBothSidesTheMacWins() {
        let p = plan(
            mac: SyncManifest(notes: [note(a, "idea.md", "h", refs: ["a.png"])], images: [image("a.png", "i2")]),
            ios: SyncManifest(notes: [note(a, "idea.md", "h", refs: ["a.png"])], images: [image("a.png", "i3")]),
            base: base([(a, "idea.md", "h")], images: [key("a.png"): "i1"])
        )
        XCTAssertEqual(p.steps.map(\.action), [.writeImage(key: key("a.png"), expect: .hash("i3"), source: .macImage(key("a.png")))])
        XCTAssertEqual(p.steps.first?.device, .ios)
    }

    func testImageDeletedOnMacIsTrashedOnIOS() {
        let p = plan(
            mac: SyncManifest(notes: [note(a, "idea.md", "h", refs: ["a.png"])]),
            ios: SyncManifest(notes: [note(a, "idea.md", "h", refs: ["a.png"])], images: [image("a.png", "i1")]),
            base: base([(a, "idea.md", "h")], images: [key("a.png"): "i1"])
        )
        XCTAssertEqual(p.steps.map(\.action), [.trashImage(key: key("a.png"), expectHash: "i1")])
    }

    func testImageAddedOnIOSIsSkipped() {
        let p = plan(
            mac: SyncManifest(notes: [note(a, "idea.md", "h")]),
            ios: SyncManifest(notes: [note(a, "idea.md", "h2", refs: ["new.png"])], images: [image("new.png", "i1")]),
            base: base([(a, "idea.md", "h")])
        )
        XCTAssertTrue(p.skipped.contains(SyncSkip(noteID: nil, reason: .imageAddedOnPeer(key("new.png")))))
        XCTAssertEqual(p.frozenImages, [key("new.png")])
        XCTAssertFalse(p.steps.contains { if case .trashImage = $0.action { return true }; return false })
    }

    func testImagesOfASkippedNoteAreNotTrashed() {
        let p = plan(
            mac: SyncManifest(unreadable: [loc("idea.md")], images: [image("a.png", "i1")]),
            ios: SyncManifest(notes: [note(a, "idea.md", "h", refs: ["a.png"])], images: [image("a.png", "i1")]),
            base: base([(a, "idea.md", "h")], images: [key("a.png"): "i1"])
        )
        XCTAssertEqual(p.steps, [])
    }

    func testImageReferencedOnlyByNewIOSVersionIsKeptWhenThatVersionWins() {
        // iOS edited the note to reference an existing image; the iOS version wins, so the image stays.
        let p = plan(
            mac: SyncManifest(notes: [note(a, "idea.md", "h1")], images: [image("a.png", "i1")]),
            ios: SyncManifest(notes: [note(a, "idea.md", "h2", refs: ["a.png"])], images: [image("a.png", "i1")]),
            base: base([(a, "idea.md", "h1")], images: [key("a.png"): "i1"])
        )
        XCTAssertEqual(p.steps.map(\.action), [.writeNote(id: a, at: loc("idea.md"), expect: .hash("h1"), source: .iosNote(a))])
    }
}

private extension SyncAction {
    var isConflictCopy: Bool {
        if case .writeConflictCopy = self { return true }
        return false
    }

    var noteID: UUID? {
        switch self {
        case .writeNote(let id, _, _, _), .writeConflictCopy(let id, _, _, _),
             .moveNote(let id, _, _, _), .trashNote(let id, _, _):
            return id
        case .writeImage, .trashImage:
            return nil
        }
    }
}

final class SyncCommitTests: XCTestCase {
    private let root = UUID()
    private let a = UUID()

    private func note(_ path: String, _ hash: String) -> ManifestNote {
        ManifestNote(id: a, location: NoteLocation(rootID: root, path: path), fileHash: hash, restHash: hash)
    }

    private func commit(
        previous: SyncBase = .empty,
        mac: [ManifestNote],
        ios: [ManifestNote],
        frozen: Set<UUID> = []
    ) -> SyncBase {
        SyncCommit.nextBase(
            previous: previous,
            macNotes: mac,
            iosNotes: ios,
            macImages: [],
            iosImages: [],
            frozenNoteIDs: frozen,
            frozenImages: []
        )
    }

    func testEqualHashAndLocationBecomesBase() {
        let next = commit(mac: [note("idea.md", "h2")], ios: [note("idea.md", "h2")])
        XCTAssertEqual(next.notes[a]?.fileHash, "h2")
        XCTAssertEqual(next.notes[a]?.location.path, "idea.md")
    }

    func testDifferentHashLeavesBaseUnchanged() {
        let previous = commit(mac: [note("idea.md", "h1")], ios: [note("idea.md", "h1")])
        let next = commit(previous: previous, mac: [note("idea.md", "h2")], ios: [note("idea.md", "h1")])
        XCTAssertEqual(next, previous)
    }

    func testDifferentLocationLeavesBaseUnchanged() {
        let previous = commit(mac: [note("idea.md", "h1")], ios: [note("idea.md", "h1")])
        let next = commit(previous: previous, mac: [note("plan.md", "h1")], ios: [note("idea.md", "h1")])
        XCTAssertEqual(next.notes[a]?.location.path, "idea.md")
    }

    func testGoneOnBothSidesRemovesBase() {
        let previous = commit(mac: [note("idea.md", "h1")], ios: [note("idea.md", "h1")])
        XCTAssertNil(commit(previous: previous, mac: [], ios: []).notes[a])
    }

    func testGoneOnOneSideKeepsBase() {
        let previous = commit(mac: [note("idea.md", "h1")], ios: [note("idea.md", "h1")])
        XCTAssertEqual(commit(previous: previous, mac: [], ios: [note("idea.md", "h1")]), previous)
    }

    func testFrozenNotesAreUntouched() {
        let previous = commit(mac: [note("idea.md", "h1")], ios: [note("idea.md", "h1")])
        XCTAssertEqual(commit(previous: previous, mac: [], ios: [], frozen: [a]), previous)
    }

    func testDuplicatesAreUntouched() {
        let previous = commit(mac: [note("idea.md", "h1")], ios: [note("idea.md", "h1")])
        let next = commit(previous: previous, mac: [note("idea.md", "h2")], ios: [note("idea.md", "h2"), note("idea 2.md", "h2")])
        XCTAssertEqual(next, previous)
    }

    func testImages() {
        let key = ImageKey(rootID: root, path: "a.png")
        let next = SyncCommit.nextBase(
            previous: SyncBase(images: [key: "old"]),
            macNotes: [],
            iosNotes: [],
            macImages: [ManifestImage(key: key, hash: "new")],
            iosImages: [ManifestImage(key: key, hash: "new")],
            frozenNoteIDs: [],
            frozenImages: []
        )
        XCTAssertEqual(next.images[key], "new")

        let gone = SyncCommit.nextBase(
            previous: next, macNotes: [], iosNotes: [], macImages: [], iosImages: [],
            frozenNoteIDs: [], frozenImages: []
        )
        XCTAssertNil(gone.images[key])
    }
}

final class ImageReferencesTests: XCTestCase {
    func testMarkdownImages() {
        let text = """
        ![one](img/a.png)
        ![two](img/b.png "A title")
        ![three](<with space.png>)
        ![four](shot%20(2).png)
        ![five](./img/a.png)
        """
        XCTAssertEqual(
            ImageReferences.paths(in: text, noteDirectory: "docs"),
            ["docs/img/a.png", "docs/img/b.png", "docs/with space.png", "docs/shot (2).png"]
        )
    }

    func testHTMLImages() {
        let text = #"<p><IMG class="x" src="a.png"> <img src='b.jpg'/> <img alt=x src=c.gif></p>"#
        XCTAssertEqual(ImageReferences.paths(in: text, noteDirectory: ""), ["a.png", "b.jpg", "c.gif"])
    }

    func testParentDirectoryInsideRootIsAllowed() {
        XCTAssertEqual(ImageReferences.paths(in: "![x](../assets/a.png)", noteDirectory: "docs/sub"), ["docs/assets/a.png"])
    }

    func testIgnored() {
        let text = """
        ![remote](https://example.com/a.png)
        ![data](data:image/png;base64,AAAA)
        ![abs](/Users/me/a.png)
        ![escape](../../a.png)
        ![doc](notes.pdf)
        ![hidden](.cache/a.png)
        [link](a.png)
        ```
        ![in code](code.png)
        ```
        """
        XCTAssertEqual(ImageReferences.paths(in: text, noteDirectory: "docs"), [])
    }

    func testNFCAndDeduplication() {
        let text = "![a](Mu\u{0308}ll.png) ![b](M\u{00FC}ll.png)"
        XCTAssertEqual(ImageReferences.paths(in: text, noteDirectory: ""), ["M\u{00FC}ll.png"])
    }
}
