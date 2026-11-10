import XCTest
@testable import ClipperExtension

/// Feature: Clips preserve the whole article and its structure.
///
/// JSON-LD `articleBody` decides which paragraphs are the article; the page DOM
/// supplies links, subheads and any opening paragraph the structured data
/// leaves out.
final class JSONLDRendererTests: XCTestCase {

    // MARK: - Fixtures (self-authored, no third-party content)

    private let lede = "Marlowe Quill is a prolific novelist with an impressive résumé, and the lede paragraph is long enough to count."
    private let body: [String] = [
        "She also has a legal claim to fame, because the second paragraph of this made-up story is padded to a realistic length.",
        "Subhead Of The Story",
        "The third paragraph links to a source, so the reader can follow where the claim came from in the original reporting.",
        "The fourth paragraph carries on with enough filler words that the whole body clears the five hundred character floor easily.",
        "The fifth and final paragraph wraps up the made-up story with one last sentence of reasonable length to finish it off cleanly.",
    ]

    /// A page whose JSON-LD body is `jsonLDParagraphs` and whose DOM article is `articleHTML`.
    private func page(jsonLDParagraphs: [String], articleHTML: String, aside: String = "") -> String {
        let json = try! JSONSerialization.data(withJSONObject: [
            "@context": "https://schema.org",
            "@type": "NewsArticle",
            "headline": "A Made-Up Story",
            "articleBody": jsonLDParagraphs.joined(separator: "\n"),
        ])
        return """
        <html><head><script type="application/ld+json">\(String(data: json, encoding: .utf8)!)</script></head>
        <body><main><article>\(articleHTML)</article>\(aside)</main></body></html>
        """
    }

    private func render(_ html: String) throws -> String {
        let ld = try XCTUnwrap(JSONLDExtractor.tryFastPath(html: html), "fast path should hit")
        return JSONLDRenderer.render(ld, pageHTML: html, baseURL: nil, maxBytes: 1_500_000).markdown
    }

    private var fullArticleHTML: String {
        """
        <p>\(lede)</p>
        <p>\(body[0])</p>
        <h2>\(body[1])</h2>
        <p>The third paragraph links to <a href="https://example.test/source">a source</a>, so the reader can follow where the claim came from in the original reporting.</p>
        <p>\(body[3])</p>
        <p>\(body[4])</p>
        """
    }

    // MARK: - Scenario: lede preserved

    func testOpeningParagraphMissingFromJSONLDIsRecoveredFromThePage() throws {
        let md = try render(page(jsonLDParagraphs: body, articleHTML: fullArticleHTML))
        XCTAssertTrue(md.hasPrefix(lede), "Expected the page's opening paragraph first, got: \(md.prefix(160))")
        XCTAssertTrue(md.contains("She also has a legal claim"))
    }

    // MARK: - Scenario: structure preserved

    func testLinksAndHeadingsAreRestoredFromThePage() throws {
        let md = try render(page(jsonLDParagraphs: body, articleHTML: fullArticleHTML))
        XCTAssertTrue(md.contains("[a source](https://example.test/source)"), "Expected the link, got: \(md)")
        XCTAssertTrue(md.contains("## Subhead Of The Story"), "Expected the heading, got: \(md)")
    }

    func testRelatedStoryCardsAreNotIncluded() throws {
        let aside = "<aside><p>Related card teaser that is deliberately long enough to look like a paragraph but is not in the article body.</p></aside>"
        let md = try render(page(jsonLDParagraphs: body, articleHTML: fullArticleHTML, aside: aside))
        XCTAssertFalse(md.contains("Related card teaser"), "Page chrome leaked into the clip: \(md)")
    }

    func testParagraphOrderFollowsJSONLD() throws {
        let md = try render(page(jsonLDParagraphs: body, articleHTML: fullArticleHTML))
        let positions = body.compactMap { md.range(of: String($0.prefix(20)))?.lowerBound }
        XCTAssertEqual(positions.count, body.count)
        XCTAssertEqual(positions, positions.sorted())
    }

    // MARK: - Scenario: shell stays plain

    func testFallsBackToPlainParagraphsWhenThePageLacksTheBody() throws {
        // Anonymous paywall shell: the DOM holds the lede-looking teaser and only one
        // body paragraph, far below the match threshold.
        let shell = "<p>\(lede)</p><p>\(body[0])</p>"
        let md = try render(page(jsonLDParagraphs: body, articleHTML: shell))
        XCTAssertFalse(md.contains(lede), "Should not borrow from a DOM that can't be trusted: \(md)")
        for paragraph in body {
            XCTAssertTrue(md.contains(paragraph), "Missing JSON-LD paragraph: \(paragraph)")
        }
        XCTAssertFalse(md.contains("]("), "Plain fallback should carry no links")
    }

    // MARK: - Scenario: entities

    func testEntitiesInPlainTextBodyDoNotLeak() throws {
        var paragraphs = body
        paragraphs[0] = "Fish&nbsp;and chips &amp; mushy peas, in a paragraph padded to a realistic length for the made-up story, with extra words so the whole body stays above the fast-path floor of five hundred characters."
        let html = page(jsonLDParagraphs: paragraphs, articleHTML: "<p>unrelated page text</p>")
        let md = try render(html)
        XCTAssertFalse(md.contains("&nbsp;"), md)
        XCTAssertFalse(md.contains("&amp;"), md)
        XCTAssertTrue(md.contains("Fish and chips & mushy peas") || md.contains("Fish\u{00A0}and chips & mushy peas"), md)
    }

    // MARK: - Matching helper

    func testNormalizeIgnoresQuoteStyleAndNonBreakingSpaces() {
        XCTAssertEqual(
            JSONLDRenderer.normalize("It\u{2019}s \u{201C}fine\u{201D}\u{00A0} \n really"),
            "It's \"fine\" really"
        )
    }
}
