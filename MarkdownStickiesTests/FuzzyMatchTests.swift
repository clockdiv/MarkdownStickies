import MarkdownStickiesCore
import XCTest

final class FuzzyMatchTests: XCTestCase {
    func testSubstringMatchRanksAboveNoise() {
        let hit = FuzzyMatch.bestScore(
            query: "play",
            in: [("Vm 1 Play Modes", 3)],
            minimumScore: 40
        )
        XCTAssertNotNil(hit)
        XCTAssertGreaterThan(hit!, 40)
    }

    func testMultiTokenQuery() {
        let score = FuzzyMatch.bestScore(
            query: "vm play",
            in: [("Vm 1 Play Modes", 3)],
            minimumScore: 40
        )
        XCTAssertNotNil(score)
    }

    func testFuzzySubsequence() {
        let score = FuzzyMatch.bestScore(
            query: "mdt",
            in: [("Medientheorie Folien", 3)],
            minimumScore: 40
        )
        XCTAssertNotNil(score)
    }

    func testShortTokenRequiresBoundary() {
        let standalone = FuzzyMatch.bestScore(
            query: "C",
            in: [("Learning C Basics", 3)],
            minimumScore: 40
        )
        XCTAssertNotNil(standalone)

        let buried = FuzzyMatch.bestScore(
            query: "C",
            in: [("Medientheorie", 3)],
            minimumScore: 40
        )
        XCTAssertNil(buried)
    }

    func testMinimumScoreFiltersWeakHits() {
        let weak = FuzzyMatch.bestScore(
            query: "xyz",
            in: [("completely unrelated", 1)],
            minimumScore: 40
        )
        XCTAssertNil(weak)

        let filtered = FuzzyMatch.bestScore(
            query: "play",
            in: [("Vm 1 Play Modes", 3)],
            minimumScore: 50_000
        )
        XCTAssertNil(filtered)
    }

    func testTitleWeightBeatsPath() {
        let breakdown = FuzzyMatch.bestBreakdown(
            query: "notes",
            in: [
                ("title", "Shopping", 3),
                ("path", "/Users/me/notes/shopping.md", 1),
            ],
            minimumScore: 40
        )
        XCTAssertEqual(breakdown?.field, "path")
    }

    func testDiacriticInsensitive() {
        let score = FuzzyMatch.bestScore(
            query: "uberblick",
            in: [("Überblick", 3)],
            minimumScore: 40
        )
        XCTAssertNotNil(score)
    }
}
