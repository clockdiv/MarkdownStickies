import XCTest
@testable import MarkdownStickiesCore

final class TextMerge3Tests: XCTestCase {
    private let base = "# Title\none\ntwo\nthree\nfour"

    func testChangesOnDifferentLinesMergeAutomatically() {
        let mine = "# Title\nONE\ntwo\nthree\nfour"
        let theirs = "# Title\none\ntwo\nthree\nFOUR"
        let hunks = TextMerge3.merge(base: base, mine: mine, theirs: theirs)
        XCTAssertFalse(hunks.contains { if case .conflict = $0 { return true }; return false })
        XCTAssertEqual(TextMerge3.automaticResult(hunks), "# Title\nONE\ntwo\nthree\nFOUR")
    }

    func testSameLineChangedDifferentlyIsAConflict() {
        let hunks = TextMerge3.merge(base: base, mine: "# Title\nmac\ntwo\nthree\nfour", theirs: "# Title\nphone\ntwo\nthree\nfour")
        XCTAssertEqual(hunks, [
            .unchanged(["# Title"]),
            .conflict(base: ["one"], mine: ["mac"], theirs: ["phone"]),
            .unchanged(["two", "three", "four"]),
        ])
    }

    func testAdditionsAndDeletions() {
        let mine = "# Title\none\ntwo\nthree\nfour\nadded on mac"
        let theirs = "# Title\none\nthree\nfour"
        let hunks = TextMerge3.merge(base: base, mine: mine, theirs: theirs)
        XCTAssertEqual(TextMerge3.automaticResult(hunks), "# Title\none\nthree\nfour\nadded on mac")
        XCTAssertTrue(hunks.contains(.onlyTheirs(base: ["two"], theirs: [])))
        XCTAssertTrue(hunks.contains(.onlyMine(base: [], mine: ["added on mac"])))
    }

    func testSameChangeOnBothSides() {
        let edited = "# Title\none\n2\nthree\nfour"
        let hunks = TextMerge3.merge(base: base, mine: edited, theirs: edited)
        XCTAssertEqual(TextMerge3.automaticResult(hunks), edited)
        XCTAssertTrue(hunks.contains(.both(base: ["two"], lines: ["2"])))
    }

    func testWithoutBaseEveryDifferenceIsAConflict() {
        let hunks = TextMerge3.merge(base: nil, mine: "a\nb\nc", theirs: "a\nB\nc")
        XCTAssertEqual(hunks, [
            .unchanged(["a"]),
            .conflict(base: [], mine: ["b"], theirs: ["B"]),
            .unchanged(["c"]),
        ])
    }
}
