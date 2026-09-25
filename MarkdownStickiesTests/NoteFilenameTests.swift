import XCTest
@testable import MarkdownStickies

final class NoteFilenameTests: XCTestCase {
    func testSlugifyLowercasesAndDashes() {
        XCTAssertEqual(NoteFilename.slugify("Vm 1 Play Modes"), "vm-1-play-modes")
        XCTAssertEqual(NoteFilename.slugify("  Hello__World  "), "hello-world")
        XCTAssertEqual(NoteFilename.slugify("???"), "note")
    }

    func testDisplayTitleTitleCasesSlug() {
        XCTAssertEqual(NoteFilename.displayTitle(from: "vm-1-play-modes"), "Vm 1 Play Modes")
        XCTAssertEqual(NoteFilename.displayTitle(from: "medientheorie"), "Medientheorie")
    }

    func testParseDatedFilename() throws {
        let url = URL(fileURLWithPath: "/tmp/2026-09-24-hello-world.md")
        let note = try XCTUnwrap(NoteFilename.parse(url: url, modifiedAt: Date(timeIntervalSince1970: 0)))
        XCTAssertEqual(note.title, "Hello World")
        XCTAssertEqual(NoteFilename.dateFormatter.string(from: note.date), "2026-09-24")
    }

    func testParseUndatedFilename() throws {
        let url = URL(fileURLWithPath: "/tmp/simple-note.md")
        let note = try XCTUnwrap(NoteFilename.parse(url: url, modifiedAt: Date(timeIntervalSince1970: 100)))
        XCTAssertEqual(note.title, "Simple Note")
        XCTAssertEqual(note.date.timeIntervalSince1970, 100)
    }

    func testUniqueRenamedURLPreservesDatePrefix() {
        let current = URL(fileURLWithPath: "/tmp/notes/2026-01-15-old-title.md")
        let renamed = NoteFilename.uniqueRenamedURL(from: current, newTitle: "New Title")
        XCTAssertEqual(renamed.lastPathComponent, "2026-01-15-new-title.md")
        XCTAssertEqual(renamed.deletingLastPathComponent().path, "/tmp/notes")
    }

    func testUniqueRenamedURLSameSlugReturnsSameURL() {
        let current = URL(fileURLWithPath: "/tmp/notes/2026-01-15-same-title.md")
        let renamed = NoteFilename.uniqueRenamedURL(from: current, newTitle: "Same Title")
        XCTAssertEqual(renamed.standardizedFileURL, current.standardizedFileURL)
    }

    func testMakeFilename() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let date = calendar.date(from: DateComponents(year: 2026, month: 3, day: 9))!
        XCTAssertEqual(NoteFilename.makeFilename(date: date, title: "Hello"), "2026-03-09-hello.md")
    }
}
