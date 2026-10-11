import Foundation
import XCTest
@testable import MarkdownStickiesCore

final class StickiesFrontmatterTests: XCTestCase {
    private let id = UUID(uuidString: "3F2A9C1E-7B4D-4E0A-9C55-1D2E3F4A5B6C")!

    private func data(_ text: String) -> Data { Data(text.utf8) }
    private func text(_ data: Data) -> String { String(decoding: data, as: UTF8.self) }

    // MARK: - Block detection

    func testDetectsBlockOnLineOne() {
        let doc = data("---\ntitle: Hello\n---\n\n# Body\n")
        XCTAssertTrue(StickiesFrontmatter.hasBlock(doc))
        XCTAssertEqual(StickiesFrontmatter.value(for: "title", in: doc), "Hello")
    }

    func testLeadingBlankLineMeansNoBlock() {
        XCTAssertFalse(StickiesFrontmatter.hasBlock(data("\n---\ntitle: Hello\n---\n")))
    }

    func testHorizontalRulesAreNotABlock() {
        XCTAssertFalse(StickiesFrontmatter.hasBlock(data("---\nJust some text\n---\nMore\n")))
        XCTAssertFalse(StickiesFrontmatter.hasBlock(data("---\n# Heading\n---\n")))
    }

    func testUnclosedBlockIsNotABlock() {
        XCTAssertFalse(StickiesFrontmatter.hasBlock(data("---\ntitle: Hello\n\n# Body\n")))
    }

    func testBlockAfterBOM() {
        let doc = Data([0xEF, 0xBB, 0xBF]) + data("---\nstickies-id: \(id.uuidString)\n---\n")
        XCTAssertEqual(StickiesFrontmatter.id(in: doc), id)
    }

    func testCRLFBlock() {
        let doc = data("---\r\nstickies-id: \(id.uuidString)\r\n---\r\nBody\r\n")
        XCTAssertEqual(StickiesFrontmatter.id(in: doc), id)
    }

    func testKeysAreCaseSensitiveAndQuotesStripped() {
        let doc = data("---\nStickies-Id: nope\nstickies-color: \"blue\"\n---\n")
        XCTAssertNil(StickiesFrontmatter.value(for: "stickies-id", in: doc))
        XCTAssertEqual(StickiesFrontmatter.color(in: doc), .preset(.blue))
    }

    func testIndentedLinesAreNotFields() {
        let doc = data("---\ntags:\n  stickies-id: \(id.uuidString)\n---\n")
        XCTAssertNil(StickiesFrontmatter.id(in: doc))
    }

    func testOldIdKeyIsIgnored() {
        let doc = data("---\nid: \(id.uuidString)\n---\n")
        XCTAssertNil(StickiesFrontmatter.id(in: doc))
    }

    // MARK: - Writing into an existing block

    func testAddsKeyAtEndAndKeepsOtherKeysAndOrder() {
        let doc = data("---\ntitle: Hello\ntags: [a, b]\nid: old\n---\n\n# Body\n")
        let result = StickiesFrontmatter.setting(StickiesFrontmatter.idKey, to: id.uuidString, in: doc)
        XCTAssertEqual(
            text(result),
            "---\ntitle: Hello\ntags: [a, b]\nid: old\nstickies-id: \(id.uuidString)\n---\n\n# Body\n"
        )
    }

    func testReplacesExistingValueInPlace() {
        let doc = data("---\na: 1\nstickies-color: blue\nb: 2\n---\n")
        let result = StickiesFrontmatter.setting(StickiesFrontmatter.colorKey, to: "green", in: doc)
        XCTAssertEqual(text(result), "---\na: 1\nstickies-color: green\nb: 2\n---\n")
    }

    func testSameValueReturnsIdenticalBytes() {
        let doc = data("---\nstickies-color:   blue  \n---\n")
        let result = StickiesFrontmatter.setting(StickiesFrontmatter.colorKey, to: "blue", in: doc)
        XCTAssertEqual(result, doc)
    }

    func testKeepsCRLFWhenInserting() {
        let doc = data("---\r\ntitle: Hello\r\n---\r\nBody\r\n")
        let result = StickiesFrontmatter.setting("stickies-color", to: "pink", in: doc)
        XCTAssertEqual(text(result), "---\r\ntitle: Hello\r\nstickies-color: pink\r\n---\r\nBody\r\n")
    }

    func testClosingFenceAtEndOfFileWithoutNewline() {
        let doc = data("---\ntitle: Hello\n---")
        let result = StickiesFrontmatter.setting("stickies-color", to: "gray", in: doc)
        XCTAssertEqual(text(result), "---\ntitle: Hello\nstickies-color: gray\n---")
    }

    // MARK: - Creating a block

    func testCreatesBlockAtTopWithBlankLineBeforeBody() {
        let result = StickiesFrontmatter.setting(StickiesFrontmatter.idKey, to: id.uuidString, in: data("# Note\n"))
        XCTAssertEqual(text(result), "---\nstickies-id: \(id.uuidString)\n---\n\n# Note\n")
    }

    func testHorizontalRuleNoteGetsNewBlockNotAKeyInItsText() {
        let doc = data("---\nJust text\n---\n")
        let result = StickiesFrontmatter.setting(StickiesFrontmatter.idKey, to: id.uuidString, in: doc)
        XCTAssertEqual(
            text(result),
            "---\nstickies-id: \(id.uuidString)\n---\n\n---\nJust text\n---\n"
        )
        XCTAssertEqual(StickiesFrontmatter.id(in: result), id)
    }

    func testCreatesBlockAfterBOMWithCRLF() {
        let doc = Data([0xEF, 0xBB, 0xBF]) + data("Body\r\n")
        let result = StickiesFrontmatter.setting("stickies-color", to: "blue", in: doc)
        XCTAssertEqual(
            result,
            Data([0xEF, 0xBB, 0xBF]) + data("---\r\nstickies-color: blue\r\n---\r\n\r\nBody\r\n")
        )
    }

    func testCreatesBlockInEmptyFile() {
        let result = StickiesFrontmatter.setting(StickiesFrontmatter.idKey, to: id.uuidString, in: Data())
        XCTAssertEqual(text(result), "---\nstickies-id: \(id.uuidString)\n---\n")
    }

    // MARK: - ensuringID / color / removing

    func testEnsuringIDWritesOnceOnly() {
        let first = StickiesFrontmatter.ensuringID(in: data("# Note\n"), newID: id)
        XCTAssertTrue(first.didChange)
        XCTAssertEqual(first.id, id)

        let second = StickiesFrontmatter.ensuringID(in: first.data, newID: UUID())
        XCTAssertFalse(second.didChange)
        XCTAssertEqual(second.id, id)
        XCTAssertEqual(second.data, first.data)
    }

    func testDefaultColorIsWrittenExplicitly() {
        let doc = data("---\nstickies-id: \(id.uuidString)\nstickies-color: blue\n---\n# Note\n")
        let result = StickiesFrontmatter.settingColor(.default, in: doc)
        XCTAssertEqual(text(result), "---\nstickies-id: \(id.uuidString)\nstickies-color: yellow\n---\n# Note\n")
    }

    func testRemovingLastFieldRemovesWholeBlock() {
        let doc = data("---\nstickies-color: blue\n---\n# Note\n")
        XCTAssertEqual(text(StickiesFrontmatter.removing(StickiesFrontmatter.colorKey, in: doc)), "# Note\n")
    }

    func testRemovingKeepsBlockWithOtherContent() {
        let doc = data("---\nstickies-color: blue\n# a comment\n---\n# Note\n")
        XCTAssertEqual(
            text(StickiesFrontmatter.removing(StickiesFrontmatter.colorKey, in: doc)),
            "---\n# a comment\n---\n# Note\n"
        )
    }

    func testRemovingMissingKeyChangesNothing() {
        let doc = data("---\ntitle: Hello\n---\n")
        XCTAssertEqual(StickiesFrontmatter.removing(StickiesFrontmatter.colorKey, in: doc), doc)
    }
}

final class NoteColorTests: XCTestCase {
    func testPresetsAndCustomHex() {
        XCTAssertEqual(NoteColor(frontmatterValue: "Blue"), .preset(.blue))
        XCTAssertEqual(NoteColor(frontmatterValue: "#A1B2C3"), .custom("#a1b2c3"))
        XCTAssertEqual(NoteColor(frontmatterValue: "a1b2c3"), .custom("#a1b2c3"))
        XCTAssertEqual(NoteColor.custom("#a1b2c3").frontmatterValue, "#a1b2c3")
        XCTAssertEqual(NoteColor.preset(.gray).frontmatterValue, "gray")
    }

    func testUnknownValuesAreNil() {
        XCTAssertNil(NoteColor(frontmatterValue: "teal"))
        XCTAssertNil(NoteColor(frontmatterValue: "#12345"))
        XCTAssertNil(NoteColor(frontmatterValue: "#12345g"))
    }
}

final class NoteHashingTests: XCTestCase {
    func testFileHashIsSHA256Hex() {
        XCTAssertEqual(
            NoteHashing.fileHash(Data("abc".utf8)),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
    }

    func testRestHashIgnoresOnlyTheColorLine() {
        let blue = Data("---\nstickies-id: X\nstickies-color: blue\n---\nBody\n".utf8)
        let green = Data("---\nstickies-id: X\nstickies-color: green\n---\nBody\n".utf8)
        let none = Data("---\nstickies-id: X\n---\nBody\n".utf8)
        let edited = Data("---\nstickies-id: X\nstickies-color: blue\n---\nBody!\n".utf8)

        XCTAssertNotEqual(NoteHashing.fileHash(blue), NoteHashing.fileHash(green))
        XCTAssertEqual(NoteHashing.restHash(blue), NoteHashing.restHash(green))
        XCTAssertEqual(NoteHashing.restHash(blue), NoteHashing.fileHash(none))
        XCTAssertNotEqual(NoteHashing.restHash(blue), NoteHashing.restHash(edited))
    }

    func testRestHashWithoutColorEqualsFileHash() {
        let doc = Data("---\nstickies-id: X\n---\nBody\n".utf8)
        XCTAssertEqual(NoteHashing.restHash(doc), NoteHashing.fileHash(doc))
    }

    func testColorLineInBodyIsNotRemoved() {
        let doc = Data("# Note\nstickies-color: blue\n".utf8)
        XCTAssertEqual(NoteHashing.restHash(doc), NoteHashing.fileHash(doc))
    }

    func testLineEndingsChangeTheHash() {
        let lf = Data("Body\n".utf8)
        let crlf = Data("Body\r\n".utf8)
        XCTAssertNotEqual(NoteHashing.fileHash(lf), NoteHashing.fileHash(crlf))
    }
}

final class PathRulesTests: XCTestCase {
    func testAcceptsNormalPaths() {
        XCTAssertEqual(try PathRules.validate("docs/idea.md", as: .note).get(), "docs/idea.md")
        XCTAssertEqual(try PathRules.validate("a b/Idee (2).MD", as: .note).get(), "a b/Idee (2).MD")
        XCTAssertEqual(try PathRules.validate("img/shot.PNG", as: .image).get(), "img/shot.PNG")
    }

    func testRejectsUnsafePaths() {
        let cases: [(String, PathRules.Violation)] = [
            ("", .empty),
            ("/etc/passwd.md", .absolute),
            ("a//b.md", .emptyComponent),
            ("./a.md", .dotComponent),
            ("../a.md", .parentReference),
            ("a/../../b.md", .parentReference),
            (".stickies-trash/a.md", .hiddenComponent),
            ("a/.hidden.md", .hiddenComponent),
            ("a\0b.md", .invalidCharacter),
            (String(repeating: "x", count: 256) + ".md", .componentTooLong),
            ("a.txt", .wrongExtension),
            ("a.md/", .emptyComponent),
        ]
        for (path, expected) in cases {
            XCTAssertEqual(PathRules.validate(path, as: .note), .failure(expected), path)
        }
        XCTAssertEqual(PathRules.validate("a.md", as: .image), .failure(.wrongExtension))
    }

    func testNormalizesToNFC() {
        let decomposed = "Mu\u{0308}ll.md"   // u + combining diaeresis
        let composed = "M\u{00FC}ll.md"
        XCTAssertEqual(try PathRules.validate(decomposed, as: .note).get(), composed)
        XCTAssertEqual(PathRules.normalized(decomposed), composed)
    }

    func testCollisionKeyIgnoresCaseButIdentityDoesNot() {
        XCTAssertEqual(PathRules.collisionKey("Docs/Idea.md"), PathRules.collisionKey("docs/idea.md"))
        XCTAssertEqual(PathRules.collisionKey("Mu\u{0308}ll.md"), PathRules.collisionKey("M\u{00DC}LL.md"))
        XCTAssertNotEqual(PathRules.normalized("Docs/Idea.md"), PathRules.normalized("docs/idea.md"))
    }

    func testResolveStaysInsideRoot() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let resolved = try PathRules.resolve("sub/new.md", as: .note, in: root).get()
        XCTAssertEqual(
            resolved.path,
            root.resolvingSymlinksInPath().appendingPathComponent("sub/new.md").path
        )
    }

    func testResolveRejectsSymlinkEscapingRoot() throws {
        let root = try makeTempDir()
        let outside = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("link"),
            withDestinationURL: outside
        )
        XCTAssertEqual(
            PathRules.resolve("link/escape.md", as: .note, in: root),
            .failure(.escapesRoot)
        )
    }

    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PathRulesTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

final class ConflictCopyTests: XCTestCase {
    private let original = UUID(uuidString: "9A8B7C6D-1111-4222-8333-444455556666")!

    func testIdIsDeterministicAndVersion5() {
        let a = ConflictCopy.id(originalID: original, sourceFileHash: "ABC")
        let b = ConflictCopy.id(originalID: original, sourceFileHash: "abc")
        let c = ConflictCopy.id(originalID: original, sourceFileHash: "abd")
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
        XCTAssertNotEqual(a, original)

        let version = a.uuid.6 >> 4
        let variant = a.uuid.8 >> 6
        XCTAssertEqual(version, 5)
        XCTAssertEqual(variant, 0b10)
    }

    func testFilename() {
        let date = ISO8601DateFormatter().date(from: "2026-10-11T23:30:00Z")!
        let utc = TimeZone(identifier: "UTC")!
        let berlin = TimeZone(identifier: "Europe/Berlin")!

        XCTAssertEqual(
            ConflictCopy.filename(forOriginal: "idea.md", deviceName: "Julian's iPhone", date: date, timeZone: utc),
            "idea (conflict Julian's iPhone 2026-10-11).md"
        )
        XCTAssertEqual(
            ConflictCopy.filename(forOriginal: "idea.md", deviceName: "iPhone", date: date, timeZone: berlin),
            "idea (conflict iPhone 2026-10-12).md"
        )
    }

    func testFilenameSanitizesDeviceName() {
        let date = Date(timeIntervalSince1970: 0)
        let utc = TimeZone(identifier: "UTC")!
        XCTAssertEqual(
            ConflictCopy.filename(forOriginal: "a.md", deviceName: "..My/Pad:\n 2", date: date, timeZone: utc),
            "a (conflict My-Pad- 2 1970-01-01).md"
        )
        XCTAssertEqual(
            ConflictCopy.filename(forOriginal: "a.md", deviceName: "  ", date: date, timeZone: utc),
            "a (conflict device 1970-01-01).md"
        )
    }
}

final class NoteFrontmatterTests: XCTestCase {
    func testSplitUsesStrictBlockRule() {
        let doc = "---\nstickies-id: X\n---\n\n# Note\n"
        XCTAssertEqual(NoteFrontmatter.splitDocument(doc).prefix, "---\nstickies-id: X\n---\n")
        XCTAssertEqual(NoteFrontmatter.splitDocument(doc).body, "\n# Note\n")

        let rule = "---\nJust text\n---\n"
        XCTAssertEqual(NoteFrontmatter.splitDocument(rule).prefix, "")
        XCTAssertEqual(NoteFrontmatter.splitDocument("\n---\na: 1\n---\n").prefix, "")
    }

    func testInitialDocumentCarriesStickiesID() {
        let id = UUID()
        let doc = NoteFrontmatter.initialDocument(title: "Idea", id: id, createdOn: "Mac")
        XCTAssertEqual(StickiesFrontmatter.id(in: Data(doc.utf8)), id)
        XCTAssertEqual(doc, "---\nstickies-id: \(id.uuidString)\ncreated_on: Mac\n---\n\n# Idea\n")
    }

    func testLegacyTrashOnlyDirectlyUnderARoot() {
        let root = URL(fileURLWithPath: "/notes/project")
        XCTAssertTrue(NoteFrontmatter.isLegacyTrash(file: URL(fileURLWithPath: "/notes/project/Trash/a.md"), roots: [root]))
        XCTAssertFalse(NoteFrontmatter.isLegacyTrash(file: URL(fileURLWithPath: "/notes/project/docs/Trash/a.md"), roots: [root]))
        XCTAssertFalse(NoteFrontmatter.isLegacyTrash(file: URL(fileURLWithPath: "/notes/project/Trashcan.md"), roots: [root]))
    }
}

final class ImageReferencesFileURLTests: XCTestCase {
    func testEditorResolving() {
        let dir = URL(fileURLWithPath: "/notes/docs")
        XCTAssertEqual(ImageReferences.fileURL(forDestination: "img/a%20b.png", noteDirectory: dir)?.path, "/notes/docs/img/a b.png")
        XCTAssertEqual(ImageReferences.fileURL(forDestination: "../a.png", noteDirectory: dir)?.path, "/notes/a.png")
        XCTAssertEqual(ImageReferences.fileURL(forDestination: "https://x.org/a.png", noteDirectory: dir)?.absoluteString, "https://x.org/a.png")
        XCTAssertNil(ImageReferences.fileURL(forDestination: "notes.md", noteDirectory: dir))
        XCTAssertNil(ImageReferences.fileURL(forDestination: "/abs/a.png", noteDirectory: dir))
    }
}
