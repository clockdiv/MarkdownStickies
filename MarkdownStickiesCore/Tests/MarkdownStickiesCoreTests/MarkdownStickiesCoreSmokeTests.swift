import XCTest
@testable import MarkdownStickiesCore

final class MarkdownStickiesCoreSmokeTests: XCTestCase {
    func testNoteFilenameMatchesMarkdown() {
        XCTAssertTrue(NoteFilename.matches("hello.md"))
        XCTAssertFalse(NoteFilename.matches("hello.txt"))
    }
}
