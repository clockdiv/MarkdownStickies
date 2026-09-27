#if os(macOS)
import XCTest
@testable import MarkdownStickiesCore

final class HTMLToMarkdownTests: XCTestCase {
    func testLooksLikeHTML() {
        XCTAssertTrue(HTMLToMarkdown.looksLikeHTML("<p>Hi</p>"))
        XCTAssertFalse(HTMLToMarkdown.looksLikeHTML("# Just markdown"))
    }

    func testConvertsHeadingsAndEmphasis() {
        let html = "<h1>Title</h1><p>Hello <strong>bold</strong> and <em>italic</em>.</p>"
        let result = HTMLToMarkdown.convert(html)
        XCTAssertTrue(result.didChange)
        XCTAssertTrue(result.markdown.contains("# Title"))
        XCTAssertTrue(result.markdown.contains("**bold**"))
        XCTAssertTrue(result.markdown.contains("*italic*"))
    }

    func testConvertsListLinkAndImage() {
        let html = """
        <ul><li>One</li><li><a href="https://example.com">Two</a></li></ul>
        <p><img src="pic.png" alt="Pic"></p>
        """
        let result = HTMLToMarkdown.convert(html)
        XCTAssertTrue(result.markdown.contains("- One"))
        XCTAssertTrue(result.markdown.contains("[Two](https://example.com)"))
        XCTAssertTrue(result.markdown.contains("![Pic](pic.png)"))
    }

    func testAnchorWithDistinctLabelKeepsMarkdownLink() {
        let html = #"<a href="http://productpage.com/2908423"> olive oil </a>"#
        let result = HTMLToMarkdown.convert(html)
        XCTAssertTrue(result.markdown.contains("[olive oil](http://productpage.com/2908423)"))
    }

    func testAnchorWithURLAsLabelBecomesBareURL() {
        let html = #"<a href="http://productpage.com/2908423"> http://productpage.com/2908423 </a>"#
        let result = HTMLToMarkdown.convert(html)
        XCTAssertTrue(result.markdown.contains("http://productpage.com/2908423"))
        XCTAssertFalse(result.markdown.contains("[http://productpage.com/2908423]("))
    }

    func testAnchorWithNearIdenticalURLLabelBecomesBareURL() {
        // Trailing slash / case should still count as redundant.
        let html = #"<a href="https://Example.com/path/">HTTPS://example.com/path</a>"#
        let result = HTMLToMarkdown.convert(html)
        XCTAssertEqual(
            result.markdown.trimmingCharacters(in: .whitespacesAndNewlines),
            "https://Example.com/path/"
        )
        XCTAssertFalse(result.markdown.contains("]("))
    }

    func testUnwrapsDivKeepsContent() {
        let html = "<div><div><p>Nested</p></div></div>"
        let result = HTMLToMarkdown.convert(html)
        XCTAssertTrue(result.markdown.contains("Nested"))
        XCTAssertFalse(result.markdown.contains("<div"))
    }

    func testStripsScriptAndStyle() {
        let html = "<p>Hi</p><script>alert(1)</script><style>body{}</style>"
        let result = HTMLToMarkdown.convert(html)
        XCTAssertTrue(result.markdown.contains("Hi"))
        XCTAssertFalse(result.markdown.contains("alert"))
        XCTAssertFalse(result.markdown.contains("body{}"))
        XCTAssertGreaterThan(result.strippedTags, 0)
    }

    func testLeavesUnknownAsResidualHTML() {
        let html = #"<p>Before</p><iframe src="https://example.com"></iframe>"#
        let result = HTMLToMarkdown.convert(html)
        XCTAssertTrue(result.markdown.contains("Before"))
        XCTAssertGreaterThanOrEqual(result.residualHTMLBlocks, 1)
        XCTAssertTrue(result.markdown.localizedCaseInsensitiveContains("iframe"))
    }

    func testConvertsSimpleTable() {
        let html = """
        <table>
          <tr><th>A</th><th>B</th></tr>
          <tr><td>1</td><td>2</td></tr>
        </table>
        """
        let result = HTMLToMarkdown.convert(html)
        XCTAssertTrue(result.markdown.contains("| A | B |"))
        XCTAssertTrue(result.markdown.contains("| --- | --- |"))
        XCTAssertTrue(result.markdown.contains("| 1 | 2 |"))
    }

    func testPreservesAuthorNewlinesInMixedHTML() {
        let html = """
        Links für Memory-Poster:

        https://one.example/
        https://two.example/

        <a href="https://stackoverflow.com/q/1">https://stackoverflow.com/q/1</a>

        Teensy Schematic:
        https://three.example/
        """
        let result = HTMLToMarkdown.convert(html)
        XCTAssertTrue(result.markdown.contains("https://stackoverflow.com/q/1"))
        XCTAssertFalse(result.markdown.contains("[https://stackoverflow.com/q/1]("))
        // Blank line after heading text preserved.
        XCTAssertTrue(result.markdown.contains("Links für Memory-Poster:\n\nhttps://one.example/"))
        // URLs stay on their own lines.
        XCTAssertTrue(result.markdown.contains("https://one.example/\nhttps://two.example/"))
        // Section break before Teensy kept.
        XCTAssertTrue(result.markdown.contains("\n\nTeensy Schematic:\nhttps://three.example/"))
        // Must not squash into one wrapped paragraph.
        XCTAssertFalse(result.markdown.contains("Memory-Poster: https://one.example/ https://two.example/"))
    }

    func testDivLinesStaySeparate() {
        let html = "<div>alpha</div><div>beta</div><div>gamma</div>"
        let result = HTMLToMarkdown.convert(html)
        XCTAssertTrue(result.markdown.contains("alpha\nbeta\ngamma"))
    }

    func testUnwrapsUnderline() {
        let html = "<p>Hello <u>underlined</u> world</p>"
        let result = HTMLToMarkdown.convert(html)
        XCTAssertTrue(result.markdown.contains("Hello underlined world"))
        XCTAssertFalse(result.markdown.contains("<u>"))
    }

    func testInventoryDefaultsAndSelectiveLeave() {
        let html = #"<p>Hi</p><u>x</u><iframe src="https://example.com"></iframe>"#
        let tags = HTMLToMarkdown.inventory(in: html)
        let byName = Dictionary(uniqueKeysWithValues: tags.map { ($0.name, $0) })
        XCTAssertEqual(byName["p"]?.defaultEnabled, true)
        XCTAssertEqual(byName["u"]?.defaultEnabled, true)
        XCTAssertEqual(byName["u"]?.kind, .unwrap)
        XCTAssertEqual(byName["iframe"]?.defaultEnabled, false)

        let leaveU = HTMLToMarkdown.convert(html, enabledTags: ["p"])
        XCTAssertTrue(leaveU.markdown.contains("<u>"))
        XCTAssertTrue(leaveU.markdown.contains("Hi"))
        XCTAssertTrue(leaveU.markdown.localizedCaseInsensitiveContains("iframe"))
    }
}

#endif
