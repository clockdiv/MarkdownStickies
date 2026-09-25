import XCTest
@testable import MarkdownStickies

final class NoteLocationTests: XCTestCase {
    func testLocationLabelUsesScanRoot() {
        let root = URL(fileURLWithPath: "/Users/me/Desktop")
        let note = URL(fileURLWithPath: "/Users/me/Desktop/projects/a.md")
        XCTAssertEqual(Note.locationLabel(for: note, scanRoots: [root]), "Desktop/projects")
        XCTAssertEqual(
            Note.locationParts(for: note, scanRoots: [root]).root,
            "Desktop"
        )
        XCTAssertEqual(
            Note.locationParts(for: note, scanRoots: [root]).subpath,
            "projects"
        )
    }

    func testLocationLabelAtRootOnly() {
        let root = URL(fileURLWithPath: "/Users/me/Notes")
        let note = URL(fileURLWithPath: "/Users/me/Notes/hello.md")
        XCTAssertEqual(Note.locationLabel(for: note, scanRoots: [root]), "Notes")
        XCTAssertNil(Note.locationParts(for: note, scanRoots: [root]).subpath)
    }
}
