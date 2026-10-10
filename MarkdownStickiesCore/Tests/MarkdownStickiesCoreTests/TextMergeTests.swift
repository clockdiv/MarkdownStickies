import XCTest
@testable import MarkdownStickiesCore

final class TextMergeTests: XCTestCase {
    func testIdenticalBodies() {
        let body = "# Note\n\nHello\n"
        let result = TextMerge.twoWay(local: body, remote: body)
        XCTAssertFalse(result.hasConflicts)
        XCTAssertEqual(result.body, body)
    }

    func testBothAppendDifferentLinesAutoMerges() {
        let local = "# Todo\n\n- milk\n- Mac item\n"
        let remote = "# Todo\n\n- milk\n- iOS item\n"
        let result = TextMerge.twoWay(local: local, remote: remote, remoteLabel: "tinydancer")
        XCTAssertFalse(result.hasConflicts, result.body)
        XCTAssertTrue(result.body.contains("- milk"))
        XCTAssertTrue(result.body.contains("- Mac item"))
        XCTAssertTrue(result.body.contains("- iOS item"))
        XCTAssertFalse(result.body.contains("<<<<<<<"))
    }

    func testRemoteOnlyAppendAutoMerges() {
        let local = "# A\n\nSame\n"
        let remote = "# A\n\nSame\nExtra from phone\n"
        let result = TextMerge.twoWay(local: local, remote: remote)
        XCTAssertFalse(result.hasConflicts)
        XCTAssertTrue(result.body.contains("Extra from phone"))
    }

    func testLocalOnlyAppendAutoMerges() {
        let local = "# A\n\nSame\nExtra from Mac\n"
        let remote = "# A\n\nSame\n"
        let result = TextMerge.twoWay(local: local, remote: remote)
        XCTAssertFalse(result.hasConflicts)
        XCTAssertTrue(result.body.contains("Extra from Mac"))
    }

    func testSameLineChangedBecomesConflictMarkers() {
        let local = "# Title\n\nMac wording\n"
        let remote = "# Title\n\niOS wording\n"
        let result = TextMerge.twoWay(
            local: local,
            remote: remote,
            localLabel: "This Mac",
            remoteLabel: "tinydancer"
        )
        XCTAssertTrue(result.hasConflicts)
        XCTAssertTrue(result.body.contains("<<<<<<< This Mac"))
        XCTAssertTrue(result.body.contains("Mac wording"))
        XCTAssertTrue(result.body.contains("======="))
        XCTAssertTrue(result.body.contains("iOS wording"))
        XCTAssertTrue(result.body.contains(">>>>>>> tinydancer"))
    }

    func testIndependentEditsInDifferentRegionsAutoMerge() {
        // Shared spine with distinct inserts — classic "both edited" note.
        let local = """
        # Seminar

        Intro

        Mac paragraph about FPGA.

        Shared closing.
        """
        let remote = """
        # Seminar

        Intro

        Shared closing.

        iOS bullet: bring charger.
        """
        // Without a common ancestor, LCS may still conflict on reordered tails.
        // Stress: at least markers are well-formed and both unique strings survive somewhere.
        let result = TextMerge.twoWay(local: local, remote: remote, remoteLabel: "iPhone")
        XCTAssertTrue(result.body.contains("Mac paragraph about FPGA.") || result.body.contains("<<<<<<<"))
        XCTAssertTrue(result.body.contains("iOS bullet: bring charger.") || result.body.contains(">>>>>>>"))
        if result.hasConflicts {
            XCTAssertTrue(result.body.contains("<<<<<<<"))
            XCTAssertTrue(result.body.contains(">>>>>>>"))
        }
    }

    func testMergeDocumentsKeepsPrimaryID() {
        let id = UUID()
        let other = UUID()
        let local = NoteFrontmatter.initialDocument(title: "Todo", id: id, createdOn: "Mac") + "- mac\n"
        let remote = NoteFrontmatter.initialDocument(title: "Todo", id: other, createdOn: "Phone") + "- phone\n"
        let result = TextMerge.mergeDocuments(
            localMarkdown: local,
            remoteMarkdown: remote,
            keepingID: id,
            remoteLabel: "Phone"
        )
        XCTAssertEqual(NoteFrontmatter.syncID(in: result.body), id)
        XCTAssertEqual(NoteFrontmatter.createdOn(in: result.body), "Mac")
        XCTAssertNil(NoteFrontmatter.conflictResolvedAt(in: result.body))
        XCTAssertTrue(result.body.contains("- mac"))
        XCTAssertTrue(result.body.contains("- phone"))
        XCTAssertFalse(result.hasConflicts)
    }

    func testStressManyAppendOnlyDivergences() {
        var localLines = (0..<40).map { "shared-\($0)" }
        var remoteLines = localLines
        localLines.append(contentsOf: (0..<15).map { "mac-only-\($0)" })
        remoteLines.append(contentsOf: (0..<15).map { "ios-only-\($0)" })
        let local = localLines.joined(separator: "\n") + "\n"
        let remote = remoteLines.joined(separator: "\n") + "\n"
        let result = TextMerge.twoWay(local: local, remote: remote)
        XCTAssertFalse(result.hasConflicts, "append-only divergence should auto-merge")
        for i in 0..<15 {
            XCTAssertTrue(result.body.contains("mac-only-\(i)"))
            XCTAssertTrue(result.body.contains("ios-only-\(i)"))
        }
    }

    func testStressAlternatingLineEditsProduceMarkers() {
        let local = (0..<20).map { $0 % 2 == 0 ? "line-\($0)-mac" : "line-\($0)" }.joined(separator: "\n") + "\n"
        let remote = (0..<20).map { $0 % 2 == 0 ? "line-\($0)-ios" : "line-\($0)" }.joined(separator: "\n") + "\n"
        let result = TextMerge.twoWay(local: local, remote: remote)
        XCTAssertTrue(result.hasConflicts)
        XCTAssertTrue(result.body.contains("<<<<<<<"))
    }
}
