import XCTest
@testable import ClipperExtension

/// Feature: Clips drop publisher page chrome.
final class MarkdownCleanupTests: XCTestCase {

    private let paragraph = "This is a real paragraph of the article body."

    // MARK: - Scenario: chrome lines removed

    func testShareListenAndNewsletterLinesAreRemoved() {
        let md = """
        Sign up for the On Tech newsletter. Get our best tech reporting from the week.

        Listen · 4:56 min

        - Share full article

        \(paragraph)
        """
        XCTAssertEqual(MarkdownCleanup.trimBoilerplate(md), paragraph)
    }

    // MARK: - Scenario: trailing recirculation cut

    func testRelatedContentSectionOfEmptyBulletsIsCut() {
        let md = """
        \(paragraph)

        Final real paragraph.

        - Share full article
        -
        -

        ## Related Content

        -
        -
        - [A related headline](https://example.test/a)
        """
        XCTAssertEqual(MarkdownCleanup.trimBoilerplate(md), "\(paragraph)\n\nFinal real paragraph.")
    }

    func testLoadingCommentsAndTheRelatedListAfterItAreCut() {
        let md = """
        \(paragraph)

        [[IMG:3]] Loading comments...

        1.  [[[IMG:4]]](https://example.test/x) 1. Another story
        """
        XCTAssertEqual(MarkdownCleanup.trimBoilerplate(md), paragraph)
    }

    func testRelatedSectionContainingProseIsKept() {
        let prose = String(repeating: "A genuinely long paragraph that belongs to the article. ", count: 6)
        let md = "\(paragraph)\n\n## Related work\n\n\(prose)"
        XCTAssertTrue(MarkdownCleanup.trimBoilerplate(md).contains("## Related work"))
        XCTAssertTrue(MarkdownCleanup.trimBoilerplate(md).contains("genuinely long paragraph"))
    }

    // MARK: - Scenario: duplicated responsive copies

    func testConsecutiveDuplicateParagraphsCollapse() {
        let byline = "[Jane Roe](https://example.test/jane) Senior Editor"
        let md = "\(paragraph)\n\n\(byline)\n\n\(byline)\n\nBio text."
        XCTAssertEqual(MarkdownCleanup.trimBoilerplate(md), "\(paragraph)\n\n\(byline)\n\nBio text.")
    }

    func testNonAdjacentRepeatsAreKept() {
        let line = "Repeated on purpose, but not back to back."
        let md = "\(line)\n\n\(paragraph)\n\n\(line)"
        XCTAssertEqual(MarkdownCleanup.trimBoilerplate(md), md)
    }

    // MARK: - Scenario: code is never touched

    func testCodeFenceContentsAreUntouched() {
        let md = "\(paragraph)\n\n```\nShare full article\nShare full article\n## Related Content\n```"
        XCTAssertEqual(MarkdownCleanup.trimBoilerplate(md), md)
    }

    func testCleanArticleIsUnchanged() {
        let md = "# Title\n\n\(paragraph)\n\n- one\n- two\n\nLast paragraph."
        XCTAssertEqual(MarkdownCleanup.trimBoilerplate(md), md)
    }

    // MARK: - Scenario: related-story card runs and publisher sign-offs

    func testTrailingRunOfRelatedStoryCardsIsCut() {
        let md = """
        \(paragraph)

        Reporter Name covers cybersecurity for the outlet.

        #### First related story headline

         [Budget](https://example.test/budget/) [Read more](https://example.test/a)

        #### Second related story headline

         [Commentary](https://example.test/c/) [Read more](https://example.test/b)
        """
        XCTAssertEqual(MarkdownCleanup.trimBoilerplate(md), "\(paragraph)\n\nReporter Name covers cybersecurity for the outlet.")
    }

    func testTrailingHeadingWithPlainLinkListIsKept() {
        let md = "\(paragraph)\n\n## References\n\n [A source](https://example.test/a) [Another](https://example.test/b)"
        XCTAssertEqual(MarkdownCleanup.trimBoilerplate(md), md)
    }

    func testCardsFollowedByProseAreKept() {
        let prose = String(repeating: "More article text continues after the cards. ", count: 3)
        let md = "\(paragraph)\n\n#### Heading\n\n [Cat](https://example.test/c/) [Read more](https://example.test/a)\n\n\(prose)"
        XCTAssertTrue(MarkdownCleanup.trimBoilerplate(md).contains("More article text continues"))
    }

    func testStayUpToDateSignOffAndEmptyCommentsHeadingAreRemoved() {
        let md = """
        \(paragraph)

        Stay up to date with the latest content by [subscribing to Example on Google News](https://example.test/news). You're reading Example— experts who break news.

        ## Comments
        """
        XCTAssertEqual(MarkdownCleanup.trimBoilerplate(md), paragraph)
    }

    func testCommentsSectionWithProseIsKept() {
        let prose = String(repeating: "A reader wrote a long and thoughtful comment about the piece. ", count: 5)
        let md = "\(paragraph)\n\n## Comments\n\n\(prose)"
        XCTAssertTrue(MarkdownCleanup.trimBoilerplate(md).contains("## Comments"))
    }
}
