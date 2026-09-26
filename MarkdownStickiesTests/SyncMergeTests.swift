import MarkdownStickiesCore
import XCTest

final class SyncMergeTests: XCTestCase {
    func testRemoteNewerWins() {
        let id = UUID()
        let local = SyncNotePayload(id: id, title: "A", modifiedAt: Date(timeIntervalSince1970: 100), body: "local")
        let remote = SyncNotePayload(id: id, title: "A", modifiedAt: Date(timeIntervalSince1970: 200), body: "remote")
        XCTAssertEqual(SyncMerge.decide(local: local, remote: remote), .applyRemote(remote))
    }

    func testLocalNewerKept() {
        let id = UUID()
        let local = SyncNotePayload(id: id, title: "A", modifiedAt: Date(timeIntervalSince1970: 300), body: "local")
        let remote = SyncNotePayload(id: id, title: "A", modifiedAt: Date(timeIntervalSince1970: 200), body: "remote")
        XCTAssertEqual(SyncMerge.decide(local: local, remote: remote), .keepLocal)
    }

    func testMissingLocalTakesRemote() {
        let remote = SyncNotePayload(id: UUID(), title: "New", modifiedAt: Date(), body: "x")
        XCTAssertEqual(SyncMerge.decide(local: nil, remote: remote), .applyRemote(remote))
    }

    func testIdenticalBodyNeverTransfers() {
        let id = UUID()
        let local = SyncNotePayload(id: id, title: "A", modifiedAt: Date(timeIntervalSince1970: 100.9), body: "same")
        let remote = SyncNotePayload(id: id, title: "A", modifiedAt: Date(timeIntervalSince1970: 500), body: "same")
        XCTAssertEqual(SyncMerge.decide(local: local, remote: remote), .keepLocal)
        XCTAssertTrue(SyncMerge.outboundIDs(ours: [local], theirs: [remote]).isEmpty)
    }

    func testEqualMtimeDifferentBodiesConvergeDeterministically() {
        let id = UUID()
        let t = Date(timeIntervalSince1970: 100)
        let a = SyncNotePayload(id: id, title: "Note", modifiedAt: t, body: "created_on: A\n")
        let b = SyncNotePayload(id: id, title: "Note", modifiedAt: t, body: "created_on: B\n")
        XCTAssertEqual(SyncMerge.decide(local: a, remote: b), .applyRemote(b))
        XCTAssertEqual(SyncMerge.decide(local: b, remote: a), .keepLocal)
    }

    func testIdenticalBodyDifferentTitleConvergesDeterministically() {
        let id = UUID()
        let older = Date(timeIntervalSince1970: 100)
        let newer = Date(timeIntervalSince1970: 200)
        let local = SyncNotePayload(id: id, title: "Alpha", modifiedAt: older, body: "same")
        let remoteNewer = SyncNotePayload(id: id, title: "Beta", modifiedAt: newer, body: "same")
        XCTAssertEqual(SyncMerge.decide(local: local, remote: remoteNewer), .applyRemote(remoteNewer))

        let remoteOlder = SyncNotePayload(id: id, title: "Beta", modifiedAt: older, body: "same")
        let localNewer = SyncNotePayload(id: id, title: "Alpha", modifiedAt: newer, body: "same")
        XCTAssertEqual(SyncMerge.decide(local: localNewer, remote: remoteOlder), .keepLocal)

        // Equal mtime: higher slug wins on both peers (Beta > Alpha).
        let a = SyncNotePayload(id: id, title: "Alpha", modifiedAt: older, body: "same")
        let b = SyncNotePayload(id: id, title: "Beta", modifiedAt: older, body: "same")
        XCTAssertEqual(SyncMerge.decide(local: a, remote: b), .applyRemote(b))
        XCTAssertEqual(SyncMerge.decide(local: b, remote: a), .keepLocal)
    }

    func testOutboundIDsWhenWeAreNewer() {
        let id = UUID()
        let ours = SyncNotePayload(id: id, title: "A", modifiedAt: Date(timeIntervalSince1970: 300), body: "us")
        let theirs = SyncNotePayload(id: id, title: "A", modifiedAt: Date(timeIntervalSince1970: 100), body: "them")
        XCTAssertEqual(SyncMerge.outboundIDs(ours: [ours], theirs: [theirs]), [id])
    }

    func testOutboundIDsEmptyWhenTheyAreNewer() {
        let id = UUID()
        let ours = SyncNotePayload(id: id, title: "A", modifiedAt: Date(timeIntervalSince1970: 100), body: "us")
        let theirs = SyncNotePayload(id: id, title: "A", modifiedAt: Date(timeIntervalSince1970: 300), body: "them")
        XCTAssertTrue(SyncMerge.outboundIDs(ours: [ours], theirs: [theirs]).isEmpty)
    }
}
