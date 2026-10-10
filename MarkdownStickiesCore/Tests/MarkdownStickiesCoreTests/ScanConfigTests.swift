import Foundation
import XCTest
@testable import MarkdownStickiesCore

final class ScanConfigTests: XCTestCase {
    func testParseIncludeExcludeOrder() {
        let text = """
        # comment
        EXCLUDE
        **/README.md
        ~/projects/vendor

        INCLUDE
        ~/projects/vendor/keep.md
        """
        let config = ScanConfig.parse(text)
        XCTAssertEqual(config.rules.count, 3)
        XCTAssertEqual(config.rules[0].kind, .exclude)
        XCTAssertEqual(config.rules[0].pattern, "**/README.md")
        XCTAssertEqual(config.rules[1].kind, .exclude)
        XCTAssertEqual(config.rules[2].kind, .include)
    }

    func testLastMatchWinsReincludeUnderExcludedDir() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let config = ScanConfig(rules: [
            ScanRule(kind: .exclude, pattern: "\(home)/proj/git"),
            ScanRule(kind: .include, pattern: "README.md"),
        ])
        let readme = URL(fileURLWithPath: "\(home)/proj/git/sub/README.md")
        let other = URL(fileURLWithPath: "\(home)/proj/git/sub/notes.md")
        XCTAssertTrue(config.allows(fileURL: readme))
        XCTAssertFalse(config.allows(fileURL: other))
    }

    func testTildeAndGlobExcludeReadmeAnywhere() {
        let config = ScanConfig(rules: [
            ScanRule(kind: .exclude, pattern: "**/README.md"),
        ])
        XCTAssertFalse(config.allows(fileURL: URL(fileURLWithPath: "/a/b/README.md")))
        XCTAssertTrue(config.allows(fileURL: URL(fileURLWithPath: "/a/b/ideas.md")))
    }

    func testSerializeRoundTrip() {
        let original = ScanConfig(rules: [
            ScanRule(kind: .exclude, pattern: "**/Vendor/**"),
            ScanRule(kind: .include, pattern: "~/projects/notes"),
        ])
        let again = ScanConfig.parse(original.serialize())
        XCTAssertEqual(again.rules.map(\.kind), original.rules.map(\.kind))
        XCTAssertEqual(again.rules.map(\.pattern), original.rules.map(\.pattern))
    }

    func testGlobStarStarDirectory() {
        XCTAssertTrue(ScanGlob.matchGlob("/Users/x/proj/Vendor/lib/a.md", pattern: "**/Vendor/**"))
        XCTAssertFalse(ScanGlob.matchGlob("/Users/x/proj/Other/a.md", pattern: "**/Vendor/**"))
    }

    func testEmptyConfigAllowsAll() {
        XCTAssertTrue(ScanConfig.empty.allows(fileURL: URL(fileURLWithPath: "/tmp/README.md")))
    }
}
