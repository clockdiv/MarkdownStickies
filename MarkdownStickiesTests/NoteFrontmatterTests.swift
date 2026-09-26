import MarkdownStickiesCore
import XCTest

final class NoteFrontmatterTests: XCTestCase {
    func testSyncIDReadsUUID() {
        let md = """
        ---
        id: 550E8400-E29B-41D4-A716-446655440000
        ---

        # Hello
        """
        XCTAssertEqual(
            NoteFrontmatter.syncID(in: md),
            UUID(uuidString: "550E8400-E29B-41D4-A716-446655440000")
        )
    }

    func testSyncIDAcceptsQuotedValue() {
        let md = """
        ---
        id: "550E8400-E29B-41D4-A716-446655440000"
        ---
        """
        XCTAssertEqual(
            NoteFrontmatter.syncID(in: md)?.uuidString,
            "550E8400-E29B-41D4-A716-446655440000"
        )
    }

    func testEnsuringInsertsWhenMissing() {
        let md = "# Title\n\nbody\n"
        let result = NoteFrontmatter.ensuringSyncID(md)
        XCTAssertTrue(result.didChange)
        XCTAssertEqual(NoteFrontmatter.syncID(in: result.markdown), result.id)
        XCTAssertTrue(result.markdown.contains("# Title"))
        XCTAssertTrue(result.markdown.hasPrefix("---\n"))
    }

    func testEnsuringPreservesExisting() {
        let id = UUID(uuidString: "550E8400-E29B-41D4-A716-446655440000")!
        let md = """
        ---
        color: yellow
        id: \(id.uuidString)
        ---

        body
        """
        let result = NoteFrontmatter.ensuringSyncID(md, id: UUID())
        XCTAssertFalse(result.didChange)
        XCTAssertEqual(result.id, id)
        XCTAssertEqual(result.markdown, md)
    }

    func testEnsuringAddsIdToExistingFrontmatter() {
        let md = """
        ---
        color: yellow
        ---

        # Note
        """
        let result = NoteFrontmatter.ensuringSyncID(md)
        XCTAssertTrue(result.didChange)
        XCTAssertEqual(NoteFrontmatter.syncID(in: result.markdown), result.id)
        XCTAssertTrue(result.markdown.contains("color: yellow"))
        XCTAssertTrue(result.markdown.contains("# Note"))
    }

    func testInitialDocumentContainsIDButNotTitleOrFolder() {
        let id = UUID(uuidString: "550E8400-E29B-41D4-A716-446655440000")!
        let md = NoteFrontmatter.initialDocument(title: "Hello World", id: id)
        XCTAssertEqual(NoteFrontmatter.syncID(in: md), id)
        XCTAssertNil(NoteFrontmatter.displayTitle(in: md))
        XCTAssertNil(NoteFrontmatter.folder(in: md))
        XCTAssertNil(NoteFrontmatter.createdOn(in: md))
        XCTAssertTrue(md.contains("# Hello World"))
        XCTAssertFalse(md.contains("title:"))
        XCTAssertFalse(md.contains("folder:"))
    }

    func testInitialDocumentIncludesCreatedOnOnly() {
        let id = UUID()
        let md = NoteFrontmatter.initialDocument(
            title: "Nested",
            id: id,
            folder: "Notes/projects",
            createdOn: "MacBook Pro"
        )
        XCTAssertNil(NoteFrontmatter.folder(in: md))
        XCTAssertEqual(NoteFrontmatter.createdOn(in: md), "MacBook Pro")
        XCTAssertFalse(md.contains("folder:"))
    }

    func testNormalizeFolderOmitsRootSentinels() {
        XCTAssertNil(NoteFrontmatter.normalizeFolder("/"))
        XCTAssertNil(NoteFrontmatter.normalizeFolder("."))
        XCTAssertNil(NoteFrontmatter.normalizeFolder("  "))
        XCTAssertEqual(NoteFrontmatter.normalizeFolder("/projects/"), "projects")
    }

    func testEnsuringCreatedOnDoesNotOverwrite() {
        let md = NoteFrontmatter.initialDocument(title: "A", createdOn: "MacBook Pro")
        let again = NoteFrontmatter.ensuringCreatedOn("Julian’s iPhone", in: md)
        XCTAssertFalse(again.didChange)
        XCTAssertEqual(NoteFrontmatter.createdOn(in: again.markdown), "MacBook Pro")
    }

    func testEnsuringOpenMetadataOnlyAddsSyncID() {
        let root = URL(fileURLWithPath: "/vault")
        let file = URL(fileURLWithPath: "/vault/projects/hello-world.md")
        let md = "# Hello World\n\nbody\n"
        let result = NoteFrontmatter.ensuringOpenMetadata(
            md,
            file: file,
            roots: [root],
            titleHint: "Hello World"
        )
        XCTAssertTrue(result.didChange)
        XCTAssertNil(NoteFrontmatter.displayTitle(in: result.markdown))
        XCTAssertNil(NoteFrontmatter.folder(in: result.markdown))
        XCTAssertNil(NoteFrontmatter.createdOn(in: result.markdown))
        XCTAssertNotNil(NoteFrontmatter.syncID(in: result.markdown))
    }

    func testEnsuringOpenMetadataDoesNotRewriteFolder() {
        let root = URL(fileURLWithPath: "/vault")
        let file = URL(fileURLWithPath: "/vault/archive/hello-world.md")
        var md = NoteFrontmatter.initialDocument(title: "Hello World")
        md = NoteFrontmatter.settingFolder("vault/projects", in: md)
        let result = NoteFrontmatter.ensuringOpenMetadata(
            md,
            file: file,
            roots: [root],
            titleHint: "Hello World"
        )
        XCTAssertFalse(result.didChange)
        XCTAssertEqual(NoteFrontmatter.folder(in: result.markdown), "vault/projects")
    }

    func testRelativeFolderIncludesRootName() {
        let root = URL(fileURLWithPath: "/Users/me/Notes")
        let nested = URL(fileURLWithPath: "/Users/me/Notes/projects/a.md")
        XCTAssertEqual(NoteFrontmatter.relativeFolder(file: nested, roots: [root]), "Notes/projects")
        let top = URL(fileURLWithPath: "/Users/me/Notes/a.md")
        XCTAssertEqual(NoteFrontmatter.relativeFolder(file: top, roots: [root]), "Notes")
    }

    func testSyncIDNilWithoutFrontmatter() {
        XCTAssertNil(NoteFrontmatter.syncID(in: "# Just a heading\n"))
    }

    func testSplitAndJoinDocumentPreservesFrontmatter() {
        let id = UUID()
        let full = NoteFrontmatter.initialDocument(title: "Hello", id: id)
        let parts = NoteFrontmatter.splitDocument(full)
        XCTAssertTrue(parts.prefix.contains("---"))
        XCTAssertTrue(parts.prefix.contains("id:"))
        XCTAssertFalse(parts.body.hasPrefix("---"))
        XCTAssertTrue(parts.body.contains("# Hello"))
        XCTAssertEqual(NoteFrontmatter.joinDocument(prefix: parts.prefix, body: parts.body), full)
    }
}
