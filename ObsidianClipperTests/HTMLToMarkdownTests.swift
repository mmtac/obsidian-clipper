import XCTest
@testable import ClipperExtension

final class HTMLToMarkdownTests: XCTestCase {

    // MARK: - Bold

    func testBoldConversion() {
        let html = "<p>This is <b>bold</b> text</p>"
        let md = HTMLToMarkdown.convert(html)
        XCTAssertTrue(md.contains("**bold**"), "Expected bold markers, got: \(md)")
    }

    // MARK: - Italic

    func testItalicConversion() {
        let html = "<p>This is <em>italic</em> text</p>"
        let md = HTMLToMarkdown.convert(html)
        XCTAssertTrue(md.contains("_italic_"), "Expected italic markers, got: \(md)")
    }

    // MARK: - Links

    func testLinkConversion() {
        let html = "<p>Visit <a href=\"https://example.com\">Example</a> site</p>"
        let md = HTMLToMarkdown.convert(html)
        XCTAssertTrue(md.contains("["), "Expected link syntax, got: \(md)")
        XCTAssertTrue(md.contains("](https://example.com"), "Expected link URL, got: \(md)")
    }

    // MARK: - Headings

    func testHeadingH1() {
        let html = "<h1>Main Title</h1>"
        let md = HTMLToMarkdown.convert(html)
        XCTAssertTrue(md.contains("# "), "Expected h1 heading, got: \(md)")
        XCTAssertTrue(md.contains("Main Title"), "Expected heading text, got: \(md)")
    }

    func testHeadingH2() {
        let html = "<h2>Section</h2>"
        let md = HTMLToMarkdown.convert(html)
        XCTAssertTrue(md.contains("## ") || md.contains("# "), "Expected heading, got: \(md)")
        XCTAssertTrue(md.contains("Section"), "Expected heading text, got: \(md)")
    }

    func testHeadingDoesNotContainBoldMarkers() {
        let html = "<h2>Bold Heading</h2>"
        let md = HTMLToMarkdown.convert(html)
        // Headings should not have redundant ** markers
        XCTAssertFalse(md.contains("**Bold Heading**"), "Headings should not have bold markers, got: \(md)")
    }

    // MARK: - Lists

    func testUnorderedList() {
        let html = "<ul><li>Item one</li><li>Item two</li></ul>"
        let md = HTMLToMarkdown.convert(html)
        XCTAssertTrue(md.contains("- ") || md.contains("Item one"), "Expected list items, got: \(md)")
    }

    func testOrderedList() {
        let html = "<ol><li>First</li><li>Second</li></ol>"
        let md = HTMLToMarkdown.convert(html)
        XCTAssertTrue(md.contains("1. ") || md.contains("First"), "Expected ordered list items, got: \(md)")
    }

    // MARK: - Blockquotes

    func testBlockquote() {
        let html = "<blockquote>This is a quote</blockquote>"
        let md = HTMLToMarkdown.convert(html)
        XCTAssertTrue(md.contains("> "), "Expected blockquote prefix, got: \(md)")
        XCTAssertTrue(md.contains("quote"), "Expected blockquote text, got: \(md)")
    }

    // MARK: - Code

    func testInlineCode() {
        let html = "<p>Use <code>print()</code> to output text</p>"
        let md = HTMLToMarkdown.convert(html)
        XCTAssertTrue(md.contains("`print()`"), "Expected inline code, got: \(md)")
    }

    func testCodeBlock() {
        let html = "<pre><code>func hello() {\n    print(\"hi\")\n}</code></pre>"
        let md = HTMLToMarkdown.convert(html)
        XCTAssertTrue(md.contains("hello()") || md.contains("func"), "Expected code block content, got: \(md)")
    }

    // MARK: - Strikethrough

    func testStrikethrough() {
        let html = "<p>This is <s>deleted</s> text</p>"
        let md = HTMLToMarkdown.convert(html)
        XCTAssertTrue(md.contains("~~deleted~~"), "Expected strikethrough, got: \(md)")
    }

    // MARK: - HTML Stripping Fallback

    func testFallbackStripsHTML() {
        // An extremely malformed HTML that NSAttributedString can't parse
        // still produces some output
        let html = "<p>Plain text content</p>"
        let md = HTMLToMarkdown.convert(html)
        XCTAssertTrue(md.contains("Plain text content"), "Expected content preserved, got: \(md)")
    }

    // MARK: - Image URL Extraction

    func testExtractImageURLsBasic() {
        let html = #"<img src="https://example.com/image.png">"#
        let urls = HTMLToMarkdown.extractImageURLs(from: html, baseURL: nil)
        XCTAssertEqual(urls.count, 1)
        XCTAssertEqual(urls.first?.absoluteString, "https://example.com/image.png")
    }

    func testExtractImageURLsRelative() {
        let html = #"<img src="/images/photo.jpg">"#
        let base = URL(string: "https://example.com")!
        let urls = HTMLToMarkdown.extractImageURLs(from: html, baseURL: base)
        XCTAssertEqual(urls.count, 1)
        XCTAssertEqual(urls.first?.absoluteString, "https://example.com/images/photo.jpg")
    }

    func testExtractImageURLsMultiple() {
        let html = """
        <img src="https://example.com/1.png">
        <img src="https://example.com/2.jpg">
        <img src="https://example.com/3.gif">
        """
        let urls = HTMLToMarkdown.extractImageURLs(from: html, baseURL: nil)
        XCTAssertEqual(urls.count, 3)
    }

    func testExtractImageURLsDeduplicates() {
        let html = """
        <img src="https://example.com/same.png">
        <img src="https://example.com/same.png">
        """
        let urls = HTMLToMarkdown.extractImageURLs(from: html, baseURL: nil)
        XCTAssertEqual(urls.count, 1)
    }

    func testExtractImageURLsSrcset() {
        let html = #"<img src="small.jpg" srcset="medium.jpg 640w, large.jpg 1024w">"#
        let base = URL(string: "https://example.com")!
        let urls = HTMLToMarkdown.extractImageURLs(from: html, baseURL: base)
        // Should include src and the largest srcset image
        XCTAssertTrue(urls.count >= 2, "Expected at least 2 URLs (src + srcset), got: \(urls.count)")
        let urlStrings = urls.map { $0.absoluteString }
        XCTAssertTrue(urlStrings.contains { $0.contains("large.jpg") }, "Expected largest srcset image")
    }

    func testExtractImageURLsDataSrc() {
        let html = #"<img data-src="https://example.com/lazy.jpg" src="placeholder.gif">"#
        let urls = HTMLToMarkdown.extractImageURLs(from: html, baseURL: nil)
        let urlStrings = urls.map { $0.absoluteString }
        XCTAssertTrue(urlStrings.contains("https://example.com/lazy.jpg"), "Expected data-src URL")
    }

    func testExtractImageURLsPictureElement() {
        let html = """
        <picture>
            <source srcset="large.webp 1024w, small.webp 320w" type="image/webp">
            <img src="fallback.jpg">
        </picture>
        """
        let base = URL(string: "https://example.com")!
        let urls = HTMLToMarkdown.extractImageURLs(from: html, baseURL: base)
        XCTAssertTrue(urls.count >= 2, "Expected at least 2 URLs from picture element, got: \(urls.count)")
    }

    // MARK: - Image Marker Injection

    func testReplaceImgTagsWithMarkersSingle() {
        let html = #"<p>Before</p><img src="https://example.com/photo.png"><p>After</p>"#
        let result = HTMLToMarkdown.replaceImgTagsWithMarkers(html, baseURL: nil)
        XCTAssertTrue(result.html.contains("[[IMG:0]]"), "Should contain marker, got: \(result.html)")
        XCTAssertFalse(result.html.contains("<img"), "Should not contain <img> tag")
        XCTAssertEqual(result.markerMap.count, 1)
        XCTAssertEqual(result.markerMap[0]?.absoluteString, "https://example.com/photo.png")
    }

    func testReplaceImgTagsWithMarkersMultiple() {
        let html = """
        <p>First</p><img src="https://example.com/1.png">
        <p>Second</p><img src="https://example.com/2.jpg">
        <p>Third</p><img src="https://example.com/3.gif">
        """
        let result = HTMLToMarkdown.replaceImgTagsWithMarkers(html, baseURL: nil)
        XCTAssertTrue(result.html.contains("[[IMG:0]]"), "Should contain marker 0")
        XCTAssertTrue(result.html.contains("[[IMG:1]]"), "Should contain marker 1")
        XCTAssertTrue(result.html.contains("[[IMG:2]]"), "Should contain marker 2")
        XCTAssertEqual(result.markerMap.count, 3)
        // Markers should be in document order
        XCTAssertEqual(result.markerMap[0]?.absoluteString, "https://example.com/1.png")
        XCTAssertEqual(result.markerMap[1]?.absoluteString, "https://example.com/2.jpg")
        XCTAssertEqual(result.markerMap[2]?.absoluteString, "https://example.com/3.gif")
    }

    func testReplaceImgTagsDeduplicates() {
        let html = """
        <img src="https://example.com/same.png">
        <img src="https://example.com/same.png">
        """
        let result = HTMLToMarkdown.replaceImgTagsWithMarkers(html, baseURL: nil)
        XCTAssertEqual(result.markerMap.count, 1, "Should deduplicate same URLs in marker map")
        // Both <img> tags should be replaced with the same marker
        let markerCount = result.html.components(separatedBy: "[[IMG:0]]").count - 1
        XCTAssertEqual(markerCount, 2, "Both duplicate <img> tags should get the same marker")
    }

    func testReplaceImgTagsSkipsTrackingPixels() {
        let html = #"<img src="https://example.com/tracking-pixel.gif">"#
        let result = HTMLToMarkdown.replaceImgTagsWithMarkers(html, baseURL: nil)
        XCTAssertEqual(result.markerMap.count, 0, "Should skip tracking pixels")
    }

    func testReplaceImgTagsSkipsSVG() {
        let html = #"<img src="https://example.com/icon.svg">"#
        let result = HTMLToMarkdown.replaceImgTagsWithMarkers(html, baseURL: nil)
        XCTAssertEqual(result.markerMap.count, 0, "Should skip SVG images")
    }

    func testReplaceImgTagsResolvesRelativeURLs() {
        let html = #"<img src="/images/photo.jpg">"#
        let base = URL(string: "https://example.com")!
        let result = HTMLToMarkdown.replaceImgTagsWithMarkers(html, baseURL: base)
        XCTAssertEqual(result.markerMap.count, 1)
        XCTAssertEqual(result.markerMap[0]?.absoluteString, "https://example.com/images/photo.jpg")
    }

    func testReplaceImgTagsUsesDataSrc() {
        let html = #"<img data-src="https://example.com/lazy.jpg">"#
        let result = HTMLToMarkdown.replaceImgTagsWithMarkers(html, baseURL: nil)
        XCTAssertEqual(result.markerMap.count, 1)
        XCTAssertEqual(result.markerMap[0]?.absoluteString, "https://example.com/lazy.jpg")
    }

    func testReplaceImgTagsPictureSourceImgSameURL() {
        let html = """
        <picture>
            <source srcset="https://example.com/photo.jpg" type="image/jpeg">
            <img src="https://example.com/photo.jpg">
        </picture>
        """
        let result = HTMLToMarkdown.replaceImgTagsWithMarkers(html, baseURL: nil)
        XCTAssertEqual(result.markerMap.count, 1, "Duplicate URL across source+img should collapse to one marker")
        let markerCount = result.html.components(separatedBy: "[[IMG:0]]").count - 1
        XCTAssertEqual(markerCount, 1, "Only the <img> should be replaced; the <source> stays untouched")
    }

    func testReplaceImgTagsPictureSourceOnly() {
        let html = """
        <picture>
            <source srcset="https://example.com/hero-large.webp 1024w, https://example.com/hero-small.webp 320w">
        </picture>
        """
        let result = HTMLToMarkdown.replaceImgTagsWithMarkers(html, baseURL: nil)
        XCTAssertEqual(result.markerMap.count, 1, "Source without sibling img should produce a marker")
        XCTAssertEqual(result.markerMap[0]?.absoluteString, "https://example.com/hero-large.webp")
        XCTAssertTrue(result.html.contains("[[IMG:0]]"), "Marker should be injected at the <source> position")
    }

    func testReplaceImgTagsUsesSrcsetWhenNoSrc() {
        let html = #"<img srcset="https://example.com/a.jpg 1x, https://example.com/b.jpg 2x">"#
        let result = HTMLToMarkdown.replaceImgTagsWithMarkers(html, baseURL: nil)
        XCTAssertEqual(result.markerMap.count, 1)
        XCTAssertEqual(result.markerMap[0]?.absoluteString, "https://example.com/b.jpg",
                       "Should pick the largest (2x) candidate from srcset when no src is present")
    }

    func testReplaceImgTagsRejectsFileScheme() {
        let html = #"<img src="file:///etc/passwd">"#
        let result = HTMLToMarkdown.replaceImgTagsWithMarkers(html, baseURL: nil)
        XCTAssertEqual(result.markerMap.count, 0, "file:// URLs must be rejected")
    }

    func testReplaceImgTagsRejectsJavascriptScheme() {
        let html = #"<img src="javascript:alert(1)">"#
        let result = HTMLToMarkdown.replaceImgTagsWithMarkers(html, baseURL: nil)
        XCTAssertEqual(result.markerMap.count, 0, "javascript: URLs must be rejected")
    }

    // MARK: - Marker Index Discovery

    func testFindMarkerIndicesEmpty() {
        XCTAssertEqual(HTMLToMarkdown.findMarkerIndices(in: ""), [])
        XCTAssertEqual(HTMLToMarkdown.findMarkerIndices(in: "no markers here"), [])
    }

    func testFindMarkerIndicesSingle() {
        let text = "before [[IMG:0]] after"
        XCTAssertEqual(HTMLToMarkdown.findMarkerIndices(in: text), [0])
    }

    func testFindMarkerIndicesMultiple() {
        let text = "[[IMG:0]] then [[IMG:5]] then [[IMG:12]]"
        XCTAssertEqual(HTMLToMarkdown.findMarkerIndices(in: text), [0, 5, 12])
    }

    func testFindMarkerIndicesDeduplicates() {
        let text = "[[IMG:3]] and again [[IMG:3]]"
        XCTAssertEqual(HTMLToMarkdown.findMarkerIndices(in: text), [3])
    }

    func testFindMarkerIndicesIgnoresMalformed() {
        // Letters, negative numbers, missing brackets — none should match.
        let text = "[[IMG:abc]] [[IMG:-1]] [[IMG]] IMG:0 [[IMG:7]]"
        XCTAssertEqual(HTMLToMarkdown.findMarkerIndices(in: text), [7])
    }

    // MARK: - Whitespace-only Line Collapse

    func testWhitespaceOnlyLinesAreCollapsed() {
        // `<p>&nbsp;</p>` and similar empty wrappers produce blank-looking
        // lines (a single space between newlines) that previously escaped
        // the `\n{3,}` collapse. Real input from Electrek / FNN clips.
        let html = "<p>First paragraph.</p><p>&nbsp;</p><p>&nbsp;</p><p>Second paragraph.</p>"
        let md = HTMLToMarkdown.convert(html)

        XCTAssertTrue(md.contains("First paragraph."), "Should keep first paragraph")
        XCTAssertTrue(md.contains("Second paragraph."), "Should keep second paragraph")
        XCTAssertFalse(md.range(of: "\\n[ \\t]+\\n", options: .regularExpression) != nil,
                       "No whitespace-only lines should remain, got: \(md.debugDescription)")
        XCTAssertFalse(md.contains("\n\n\n"),
                       "No runs of 3+ newlines should remain, got: \(md.debugDescription)")
    }

    func testWhitespaceOnlyLinesPreserveLeadingIndentInContent() {
        // Lookahead-only strip means leading whitespace on a content line
        // (e.g. inside a code block context emitted separately) isn't touched.
        // Sanity: a paragraph between two empty wrappers should still produce
        // exactly one blank line above and below.
        let html = "<p>A</p><p>&nbsp;</p><p>B</p><p>&nbsp;</p><p>C</p>"
        let md = HTMLToMarkdown.convert(html)
        // Expect: A\n\nB\n\nC (or same with trailing newline trimmed)
        XCTAssertEqual(md, "A\n\nB\n\nC", "Empty paragraphs should collapse cleanly, got: \(md.debugDescription)")
    }

    // MARK: - Marker Replacement

    func testReplaceMarkersWithImages() {
        let markdown = "Some text\n\n[[IMG:0]]\n\nMore text\n\n[[IMG:1]]"
        let mapping: [Int: String] = [0: "images/abc-1.png", 1: "images/abc-2.jpg"]
        let result = HTMLToMarkdown.replaceMarkersWithImages(markdown, markerToPath: mapping)
        XCTAssertTrue(result.markdown.contains("![abc-1](images/abc-1.png)"), "Should replace marker 0, got: \(result.markdown)")
        XCTAssertTrue(result.markdown.contains("![abc-2](images/abc-2.jpg)"), "Should replace marker 1, got: \(result.markdown)")
        XCTAssertFalse(result.markdown.contains("[[IMG:"), "Should not contain any remaining markers")
        XCTAssertEqual(result.placedIndices, [0, 1], "Should report both indices as placed")
    }

    func testReplaceMarkersPartialMapping() {
        let markdown = "Before [[IMG:0]] middle [[IMG:1]] after"
        let mapping: [Int: String] = [0: "images/abc-1.png"]
        let result = HTMLToMarkdown.replaceMarkersWithImages(markdown, markerToPath: mapping)
        XCTAssertTrue(result.markdown.contains("![abc-1](images/abc-1.png)"), "Should replace mapped marker")
        XCTAssertTrue(result.markdown.contains("[[IMG:1]]"), "Should leave unmapped marker intact")
        XCTAssertEqual(result.placedIndices, [0])
    }

    // MARK: - Table Detection

    func testTableConversion() {
        let html = """
        <table><tr><th>Name</th><th>Value</th></tr>
        <tr><td>A</td><td>1</td></tr>
        <tr><td>B</td><td>2</td></tr></table>
        """
        let md = HTMLToMarkdown.convert(html)
        XCTAssertTrue(md.contains("| Name | Value |"), "Expected table header, got: \(md)")
        XCTAssertTrue(md.contains("| A | 1 |"), "Expected table row, got: \(md)")
    }

    // MARK: - Link Sanitization

    func testJavascriptLinkStripped() {
        let html = #"<p><a href="javascript:alert(1)">Click me</a></p>"#
        let md = HTMLToMarkdown.convert(html)
        XCTAssertTrue(md.contains("Click me"), "Link text should be preserved")
        XCTAssertFalse(md.contains("javascript:"), "javascript: URL should be stripped, got: \(md)")
        XCTAssertFalse(md.contains("]("), "Should not be a Markdown link, got: \(md)")
    }

    func testDataLinkStripped() {
        let html = #"<p><a href="data:text/html,<script>alert(1)</script>">Click</a></p>"#
        let md = HTMLToMarkdown.convert(html)
        XCTAssertTrue(md.contains("Click"), "Link text should be preserved")
        XCTAssertFalse(md.contains("data:"), "data: URL should be stripped")
    }

    func testVbscriptLinkStripped() {
        let html = #"<p><a href="vbscript:MsgBox('hi')">Click</a></p>"#
        let md = HTMLToMarkdown.convert(html)
        XCTAssertFalse(md.contains("vbscript:"), "vbscript: URL should be stripped")
    }

    func testNormalLinkPreserved() {
        let html = #"<p><a href="https://example.com">Example</a></p>"#
        let md = HTMLToMarkdown.convert(html)
        XCTAssertTrue(md.contains("[Example](https://example.com)"), "Normal link should be preserved, got: \(md)")
    }

    func testLinkWithParenthesesEncoded() {
        let html = #"<p><a href="https://example.com/page_(test)">Link</a></p>"#
        let md = HTMLToMarkdown.convert(html)
        XCTAssertTrue(md.contains("%28") && md.contains("%29"), "Parentheses should be encoded, got: \(md)")
        XCTAssertTrue(md.contains("[Link]"), "Link text should be preserved")
    }

    // MARK: - Full Article Body Extraction (regression tests for header-only bug)

    func testConvertPreservesFullArticleBody() {
        let html = """
        <article>
            <h1>Article Title</h1>
            <p>This is the first paragraph of the article with enough content to be meaningful.
            It discusses important topics about technology and its impact on modern society.</p>
            <p>The second paragraph continues with more detailed information about the subject,
            expanding on the themes introduced in the first paragraph with examples and analysis.</p>
            <p>A third paragraph provides additional depth, covering related subtopics and
            offering different perspectives on the main discussion points raised above.</p>
        </article>
        """
        let md = HTMLToMarkdown.convert(html)

        // ALL paragraphs must be present — this is the core regression test
        XCTAssertTrue(md.contains("first paragraph"), "Should contain first paragraph, got: \(md)")
        XCTAssertTrue(md.contains("second paragraph"), "Should contain second paragraph, got: \(md)")
        XCTAssertTrue(md.contains("third paragraph"), "Should contain third paragraph, got: \(md)")
        XCTAssertTrue(md.contains("# Article Title"), "Should contain heading, got: \(md)")
    }

    // MARK: - Node-based convert overload

    func testConvertNodeProducesSameOutputAsStringOverload() {
        let html = """
        <article>
            <h1>Article Title</h1>
            <p>This is the first paragraph of the article with enough content to be meaningful.
            It discusses important topics about technology and its impact on modern society.</p>
            <p>The second paragraph continues with more detailed information about the subject,
            expanding on the themes introduced in the first paragraph with examples and analysis.</p>
        </article>
        """

        // Parse once via HTMLParser and convert the resulting tree directly
        var parser = HTMLParser(html: html)
        guard let document = parser.parse() else {
            XCTFail("Parser should produce a document node")
            return
        }
        let nodeMarkdown = HTMLToMarkdown.convert(node: document)

        // Compare against the string-based overload, which parses internally
        let stringMarkdown = HTMLToMarkdown.convert(html)

        XCTAssertEqual(nodeMarkdown, stringMarkdown,
                       "convert(node:) should produce identical output to convert(_:)")
        XCTAssertTrue(nodeMarkdown.contains("# Article Title"), "Should contain heading")
        XCTAssertTrue(nodeMarkdown.contains("first paragraph"), "Should contain first paragraph")
        XCTAssertTrue(nodeMarkdown.contains("second paragraph"), "Should contain second paragraph")
    }

    func testConvertNodePreservesImageMarkersInTextNodes() {
        // Text nodes containing [[IMG:N]] markers (injected before Readability)
        // must survive DOM-level conversion with their exact text.
        let html = """
        <article>
            <p>Before image.</p>
            [[IMG:0]]
            <p>Between images.</p>
            [[IMG:1]]
            <p>After images.</p>
        </article>
        """

        var parser = HTMLParser(html: html)
        guard let document = parser.parse() else {
            XCTFail("Parser should produce a document node")
            return
        }
        let md = HTMLToMarkdown.convert(node: document)

        XCTAssertTrue(md.contains("[[IMG:0]]"), "Marker 0 should survive, got: \(md)")
        XCTAssertTrue(md.contains("[[IMG:1]]"), "Marker 1 should survive, got: \(md)")
        XCTAssertTrue(md.contains("Before image"), "Text before marker should survive")
        XCTAssertTrue(md.contains("Between images"), "Text between markers should survive")
        XCTAssertTrue(md.contains("After images"), "Text after markers should survive")
    }

    func testConvertPreservesImageMarkers() {
        let html = """
        <p>Text before image.</p>
        [[IMG:0]]
        <p>Text between images.</p>
        [[IMG:1]]
        <p>Text after images.</p>
        """
        let md = HTMLToMarkdown.convert(html)

        XCTAssertTrue(md.contains("[[IMG:0]]"), "Should preserve marker 0, got: \(md)")
        XCTAssertTrue(md.contains("[[IMG:1]]"), "Should preserve marker 1, got: \(md)")
        XCTAssertTrue(md.contains("Text before image"), "Should preserve text before marker")
        XCTAssertTrue(md.contains("Text between images"), "Should preserve text between markers")
        XCTAssertTrue(md.contains("Text after images"), "Should preserve text after markers")
    }

    func testConvertHandlesComplexArticleWithImages() {
        let html = """
        <div class="article-content">
            <h1>Breaking News Story</h1>
            <p>The opening paragraph sets the scene for an important news story that
            has been developing over the past several weeks.</p>
            [[IMG:0]]
            <h2>Background</h2>
            <p>Historical context provides readers with the necessary background to
            understand the significance of recent events and their broader implications.</p>
            [[IMG:1]]
            <p>Additional details emerge as experts weigh in on the developing situation,
            offering their professional analysis and predictions.</p>
            <blockquote>This is a direct quote from an expert source providing key insight.</blockquote>
            <h2>Impact</h2>
            <p>The final section discusses the expected impact on various stakeholders and
            what steps are being taken to address the situation going forward.</p>
        </div>
        """
        let md = HTMLToMarkdown.convert(html)

        // Verify full structure is preserved
        XCTAssertTrue(md.contains("# Breaking News Story"), "Should contain h1")
        XCTAssertTrue(md.contains("## Background"), "Should contain h2")
        XCTAssertTrue(md.contains("## Impact"), "Should contain second h2")
        XCTAssertTrue(md.contains("opening paragraph"), "Should contain first paragraph")
        XCTAssertTrue(md.contains("Historical context"), "Should contain second paragraph")
        XCTAssertTrue(md.contains("Additional details"), "Should contain third paragraph")
        XCTAssertTrue(md.contains("final section"), "Should contain fourth paragraph")
        XCTAssertTrue(md.contains("[[IMG:0]]"), "Should contain first image marker")
        XCTAssertTrue(md.contains("[[IMG:1]]"), "Should contain second image marker")
        XCTAssertTrue(md.contains("> "), "Should contain blockquote")

        // Verify order: IMG:0 should appear before IMG:1
        let idx0 = md.range(of: "[[IMG:0]]")!.lowerBound
        let idx1 = md.range(of: "[[IMG:1]]")!.lowerBound
        XCTAssertTrue(idx0 < idx1, "IMG:0 should appear before IMG:1 in document order")
    }

    func testConvertPreservesNestedFormatting() {
        let html = "<p>This has <strong>bold and <em>bold italic</em></strong> text</p>"
        let md = HTMLToMarkdown.convert(html)
        XCTAssertTrue(md.contains("**bold and"), "Should contain bold, got: \(md)")
    }

    func testConvertHandlesHorizontalRule() {
        let html = "<p>Before</p><hr><p>After</p>"
        let md = HTMLToMarkdown.convert(html)
        XCTAssertTrue(md.contains("---"), "Should contain hr, got: \(md)")
        XCTAssertTrue(md.contains("Before"), "Should contain text before hr")
        XCTAssertTrue(md.contains("After"), "Should contain text after hr")
    }

    // MARK: - End-to-End Pipeline: Markers Through Readability to Markdown

    func testMarkersPreservedThroughReadabilityAndMarkdown() {
        // Simulate the full pipeline: HTML → marker injection → Readability → Markdown
        let html = """
        <html><body>
        <nav><a href="/">Home</a><a href="/about">About</a></nav>
        <article class="post-content">
            <h1>Test Article</h1>
            <p>First paragraph with enough text to score well in Readability. It contains
            commas, natural prose, and sufficient length to pass all content thresholds easily.
            This is the main body content that should be fully extracted.</p>
            <img src="https://example.com/photo1.jpg" alt="Photo 1">
            <p>Second paragraph continues with more detail. The content is rich with natural
            language patterns, multiple sentences, and enough depth to clearly identify this
            as an article worth extracting rather than navigation or sidebar content.</p>
            <img src="https://example.com/photo2.jpg" alt="Photo 2">
            <p>Third paragraph wraps up the article with concluding remarks about the topic,
            providing a satisfying conclusion that rounds out the piece nicely.</p>
        </article>
        <footer><p>Copyright 2024</p></footer>
        </body></html>
        """

        // Step 1: Inject markers
        let markerResult = HTMLToMarkdown.replaceImgTagsWithMarkers(html, baseURL: nil)
        XCTAssertEqual(markerResult.markerMap.count, 2)

        // Step 2: Run Readability
        let readability = ReadabilityExtractor.extract(html: markerResult.html, url: nil)
        XCTAssertNotNil(readability, "Readability should extract content")

        guard let readability = readability else { return }

        // Step 3: Convert to Markdown
        let md = HTMLToMarkdown.convert(node: readability.articleNode)

        // Verify all content survived the full pipeline
        XCTAssertTrue(md.contains("First paragraph"), "First paragraph should survive pipeline")
        XCTAssertTrue(md.contains("Second paragraph"), "Second paragraph should survive pipeline")
        XCTAssertTrue(md.contains("Third paragraph"), "Third paragraph should survive pipeline")
        XCTAssertTrue(md.contains("[[IMG:0]]"), "First image marker should survive pipeline, got: \(md)")
        XCTAssertTrue(md.contains("[[IMG:1]]"), "Second image marker should survive pipeline, got: \(md)")

        // Verify markers are in document order
        if let idx0 = md.range(of: "[[IMG:0]]"), let idx1 = md.range(of: "[[IMG:1]]") {
            XCTAssertTrue(idx0.lowerBound < idx1.lowerBound, "Markers should be in document order")
        }

        // Step 4: Replace markers with image paths
        let markerToPath: [Int: String] = [
            0: "images/photo1.jpg",
            1: "images/photo2.jpg"
        ]
        let finalResult = HTMLToMarkdown.replaceMarkersWithImages(md, markerToPath: markerToPath)
        XCTAssertTrue(finalResult.markdown.contains("![photo1](images/photo1.jpg)"), "Should have inline image 1")
        XCTAssertTrue(finalResult.markdown.contains("![photo2](images/photo2.jpg)"), "Should have inline image 2")
        XCTAssertFalse(finalResult.markdown.contains("[[IMG:"), "No markers should remain")
    }

    // MARK: - Regression: inline links inside paragraphs must not be stripped

    /// Regression test for the bug where `ReadabilityExtractor.postProcess` removed
    /// inline `<a>` tags inside paragraphs because they had link density 1.0 and
    /// short text. This chewed holes in sentences mid-paragraph.
    func testInlineLinksInsideParagraphsArePreserved() {
        let html = """
        <html><body>
        <article>
            <p>The first paragraph mentions <a href="https://a.example">Topic A</a> and also
            talks about <a href="https://b.example">Topic B</a> in the context of ongoing
            research. This paragraph has enough length to score well and pass all content
            thresholds while still containing multiple inline links.</p>
            <p>A second paragraph <a href="https://c.example">adds more</a> context with
            another <a href="https://d.example">relevant reference</a>. Natural prose with
            commas and punctuation to signal this is article content.</p>
        </article>
        </body></html>
        """
        let marked = HTMLToMarkdown.replaceImgTagsWithMarkers(html, baseURL: nil).html
        let r = ReadabilityExtractor.extract(html: marked, url: nil)
        XCTAssertNotNil(r)
        guard let r = r else { return }
        let md = HTMLToMarkdown.convert(node: r.articleNode)

        XCTAssertTrue(md.contains("Topic A"), "Inline link 'Topic A' was stripped: \(md)")
        XCTAssertTrue(md.contains("Topic B"), "Inline link 'Topic B' was stripped: \(md)")
        XCTAssertTrue(md.contains("adds more"), "Inline link 'adds more' was stripped: \(md)")
        XCTAssertTrue(md.contains("relevant reference"), "Inline link 'relevant reference' was stripped: \(md)")
    }

    /// Regression test for the substring false-positive: `"lead-in-text-callout"`
    /// must not be removed just because it contains the letters of the negative
    /// pattern `"ad"`.
    func testInlineSpanWithAdSubstringIsPreserved() {
        let html = """
        <html><body>
        <article>
            <p><span class="lead-in-text-callout">Opening callout</span> continues with
            regular prose that establishes the article's main topic. The paragraph has
            enough length and commas to score well in the Readability algorithm.</p>
            <p>Follow-up paragraph adds more detail with natural language patterns and
            sufficient content for the scorer to identify this as article body.</p>
            <p>Final paragraph wraps up the piece with concluding thoughts and a forward
            looking statement about the subject matter.</p>
        </article>
        </body></html>
        """
        let r = ReadabilityExtractor.extract(html: html, url: nil)
        XCTAssertNotNil(r)
        guard let r = r else { return }
        let md = HTMLToMarkdown.convert(node: r.articleNode)

        XCTAssertTrue(md.contains("Opening callout"),
                      "`lead-in-text-callout` span should not be removed by 'ad' false match: \(md)")
    }

    /// Regression test for the Wired "ArticlePageChunks" shape, where the
    /// article body is split into multiple BodyWrapper chunks (interleaved
    /// with ad slots) and a "More from WIRED" recirculation widget sits at
    /// the bottom with many summary cards. The recirc container used to
    /// accumulate enough propagated score from its link-card children to
    /// beat the actual article body, yielding a clip of just the related
    /// articles list.
    ///
    /// Fix: re-apply the link-density penalty against the aggregated score
    /// at winner-selection time.
    func testChunkedArticleBeatsRelatedArticlesGrid() {
        let html = """
        <html><body>
        <main>
            <article class="article main-content story">
                <header><h1>The Article Title</h1></header>
                <div class="BodyWrapper body__container article__body">
                    <p>First chunk of the body has enough length and natural prose to score
                    well in Readability, with commas and punctuation to flag it as content.</p>
                    <p>More content in the first chunk that keeps the article feeling real —
                    paragraphs, inline details, and the occasional reference.</p>
                </div>
                <div class="advertisement"><p>Sponsored promo inserted between body chunks.</p></div>
                <div class="BodyWrapper body__container article__body">
                    <p>Second chunk picks up where the first left off, continuing the
                    narrative with more substantive paragraphs and detail.</p>
                    <p>The split across multiple BodyWrapper containers mirrors how some
                    publishers interleave ads with prose, which fragments the score.</p>
                </div>
                <div class="advertisement"><p>Another inserted promo.</p></div>
                <div class="BodyWrapper body__container article__body">
                    <p>Third chunk wraps the article with concluding remarks and
                    a call-back to the opening theme, tying the piece together.</p>
                </div>
            </article>
            <aside class="ContentFooterRelated">
                <h2>More from Example</h2>
                <div class="SummaryCollectionGridItems">
                    <div class="SummaryItemWrapper summary-item summary-item--ARTICLE"><a href="/a1">Related article one with a moderately long headline goes here.</a></div>
                    <div class="SummaryItemWrapper summary-item summary-item--ARTICLE"><a href="/a2">Related article two with a moderately long headline goes here.</a></div>
                    <div class="SummaryItemWrapper summary-item summary-item--ARTICLE"><a href="/a3">Related article three with a moderately long headline goes here.</a></div>
                    <div class="SummaryItemWrapper summary-item summary-item--ARTICLE"><a href="/a4">Related article four with a moderately long headline goes here.</a></div>
                    <div class="SummaryItemWrapper summary-item summary-item--ARTICLE"><a href="/a5">Related article five with a moderately long headline goes here.</a></div>
                    <div class="SummaryItemWrapper summary-item summary-item--ARTICLE"><a href="/a6">Related article six with a moderately long headline goes here.</a></div>
                    <div class="SummaryItemWrapper summary-item summary-item--ARTICLE"><a href="/a7">Related article seven with a moderately long headline goes here.</a></div>
                    <div class="SummaryItemWrapper summary-item summary-item--ARTICLE"><a href="/a8">Related article eight with a moderately long headline goes here.</a></div>
                    <div class="SummaryItemWrapper summary-item summary-item--ARTICLE"><a href="/a9">Related article nine with a moderately long headline goes here.</a></div>
                </div>
            </aside>
        </main>
        </body></html>
        """

        let r = ReadabilityExtractor.extract(html: html, url: nil)
        XCTAssertNotNil(r)
        guard let r = r else { return }
        let md = HTMLToMarkdown.convert(node: r.articleNode)

        XCTAssertTrue(md.contains("First chunk"), "Article chunk 1 missing: \(md)")
        XCTAssertTrue(md.contains("Second chunk"), "Article chunk 2 missing: \(md)")
        XCTAssertTrue(md.contains("Third chunk"), "Article chunk 3 missing: \(md)")
        XCTAssertFalse(md.contains("Related article one"),
                       "Related-articles grid should not win over the article body: \(md)")
    }

    // MARK: - truncateUTF8

    private func assertValidTruncation(_ input: String, maxBytes: Int, file: StaticString = #filePath, line: UInt = #line) {
        let out = HTMLToMarkdown.truncateUTF8(input, maxBytes: maxBytes)
        XCTAssertLessThanOrEqual(out.utf8.count, maxBytes, file: file, line: line)
        XCTAssertTrue(input.utf8.starts(with: out.utf8), "Result must be a byte prefix of the input", file: file, line: line)
        XCTAssertFalse(out.unicodeScalars.contains("\u{FFFD}"), file: file, line: line)
    }

    func testTruncateUTF8ShortStringUnchanged() {
        XCTAssertEqual(HTMLToMarkdown.truncateUTF8("hello", maxBytes: 10), "hello")
        XCTAssertEqual(HTMLToMarkdown.truncateUTF8("hello", maxBytes: 5), "hello")
        XCTAssertEqual(HTMLToMarkdown.truncateUTF8("hello", maxBytes: 0), "")
    }

    func testTruncateUTF8CJKCutMidCharacter() {
        let cjk = "日本語テキスト" // 3 bytes per character
        for max in 1...cjk.utf8.count {
            assertValidTruncation(cjk, maxBytes: max)
        }
        // 4 bytes lands one byte into the second character -> keep only the first.
        XCTAssertEqual(HTMLToMarkdown.truncateUTF8(cjk, maxBytes: 4), "日")
        XCTAssertEqual(HTMLToMarkdown.truncateUTF8(cjk, maxBytes: 2), "")
    }

    func testTruncateUTF8EmojiCutMidCharacter() {
        let emoji = "a😀b👨‍👩‍👧c" // 4-byte scalars and ZWJ sequences
        for max in 1...emoji.utf8.count {
            assertValidTruncation(emoji, maxBytes: max)
        }
        XCTAssertEqual(HTMLToMarkdown.truncateUTF8(emoji, maxBytes: 3), "a")
        XCTAssertEqual(HTMLToMarkdown.truncateUTF8(emoji, maxBytes: 5), "a😀")
    }

    func testConvertLargeCJKDocumentStaysBounded() {
        // > 2 MB of 3-byte characters with a byte cut that lands mid-character
        // (the old code fell back to the *untruncated* HTML in that case).
        let para = "<p>" + String(repeating: "東京は日本の首都です。", count: 200) + "</p>\n"
        var html = "<html><body>x"   // 1-byte offset shifts the 2 MB cut mid-character
        while html.utf8.count < HTMLToMarkdown.maxHTMLSize + 512 * 1024 { html += para }
        XCTAssertGreaterThan(html.utf8.count, HTMLToMarkdown.maxHTMLSize)

        let md = HTMLToMarkdown.convert(html)
        XCTAssertFalse(md.isEmpty)
        XCTAssertLessThanOrEqual(md.utf8.count, HTMLToMarkdown.maxHTMLSize)
        XCTAssertTrue(md.contains("東京"))
    }

    // MARK: - Deep nesting

    func testConvertDeeplyNestedDivsDoesNotCrash() {
        let depth = 5_000
        let html = String(repeating: "<div>", count: depth) + "deep text"
            + String(repeating: "</div>", count: depth) + "<p>after</p>"
        let md = HTMLToMarkdown.convert(html)
        XCTAssertTrue(md.contains("after"))
    }

    func testConvertNodeDeepTreeDoesNotCrash() {
        let depth = 5_000
        let html = "<html><body>" + String(repeating: "<div>", count: depth) + "deep text"
            + String(repeating: "</div>", count: depth) + "</body></html>"
        guard let root = SwiftSoupAdapter.parse(html: html) else {
            return XCTFail("SwiftSoup parse failed")
        }
        _ = HTMLToMarkdown.convert(node: root)
        _ = root.textContent
        _ = root.serialize()
    }

    // MARK: - Overlapping marker replacements

    func testOverlappingImgAndSourceMatchesDoNotCrash() {
        // The <img> regex stops at the first '>' (inside alt), and the
        // <source> regex matches inside that same span -> overlapping ranges.
        let html = #"<p>Intro</p><img src="https://example.com/a.png" alt="<source src='https://example.com/b.png'>"><p>Tail</p>"#
        let result = HTMLToMarkdown.replaceImgTagsWithMarkers(html, baseURL: URL(string: "https://example.com/"))
        XCTAssertTrue(result.html.contains("[[IMG:0]]"))
        XCTAssertFalse(result.html.contains("<img"))
        XCTAssertTrue(result.html.hasPrefix("<p>Intro</p>"))
        XCTAssertTrue(result.html.contains("<p>Tail</p>"))
        XCTAssertEqual(result.markerMap[0]?.absoluteString, "https://example.com/a.png")
    }

    func testOverlappingSourceInsideImgSrcsetDoesNotCrash() {
        let html = #"<picture><img data-x="<source srcset='https://example.com/b.webp 2x'>" src="https://example.com/a.png"><source srcset="https://example.com/c.webp"></picture>"#
        let result = HTMLToMarkdown.replaceImgTagsWithMarkers(html, baseURL: nil)
        XCTAssertFalse(result.html.contains("<img"))
        XCTAssertTrue(result.html.contains("[[IMG:0]]"))
    }
}
