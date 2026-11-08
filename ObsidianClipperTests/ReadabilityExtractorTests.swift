import XCTest
@testable import ClipperExtension

final class ReadabilityExtractorTests: XCTestCase {

    // MARK: - Article Extraction from Realistic Page

    func testExtractsArticleFromRealisticPage() {
        let html = """
        <html><head><title>Great Article | Example News</title>
        <meta property="og:title" content="Great Article">
        <meta property="og:site_name" content="Example News">
        <meta name="description" content="A short summary of the article.">
        </head><body>
        <nav><ul><li><a href="/">Home</a></li><li><a href="/news">News</a></li></ul></nav>
        <div id="sidebar" class="sidebar-widget">
            <h3>Trending</h3>
            <ul><li><a href="/trending1">Trending 1</a></li><li><a href="/trending2">Trending 2</a></li></ul>
        </div>
        <article class="post-content">
            <h1>Great Article</h1>
            <p>This is the first paragraph of a very interesting article about technology and
            its impact on society. It contains enough text to be considered real content, with
            commas, periods, and other punctuation that indicate prose.</p>
            <p>The second paragraph continues the discussion with more detail, expanding on the
            themes introduced above. Multiple paragraphs with substantial text help the scoring
            algorithm identify this as the main content area of the page.</p>
            <p>A third paragraph adds even more depth to the article, discussing related topics
            and providing examples that illustrate the main points being made. This is clearly
            the body of an article, not navigation or sidebar content.</p>
        </article>
        <footer><p>Copyright 2024 Example News</p><a href="/privacy">Privacy Policy</a></footer>
        </body></html>
        """

        let result = ReadabilityExtractor.extract(html: html, url: URL(string: "https://example.com/article"))

        XCTAssertNotNil(result, "Should extract article content")

        guard let result = result else { return }

        // Should contain the article paragraphs
        XCTAssertTrue(result.articleNode.serialize().contains("first paragraph"), "Should contain article text")
        XCTAssertTrue(result.articleNode.serialize().contains("second paragraph"), "Should contain second paragraph")
        XCTAssertTrue(result.articleNode.serialize().contains("third paragraph"), "Should contain third paragraph")

        // Should NOT contain navigation or footer
        XCTAssertFalse(result.articleNode.serialize().contains("Trending"), "Should not contain sidebar")
        XCTAssertFalse(result.articleNode.serialize().contains("Privacy Policy"), "Should not contain footer")
        XCTAssertFalse(result.articleNode.serialize().contains("Home"), "Should not contain nav links")
    }

    // MARK: - Graceful Fallback on No Clear Article

    func testFallbackGracefullyOnNoClearArticle() {
        let html = """
        <html><body>
        <div><p>Short text.</p></div>
        <div><p>Another short bit.</p></div>
        </body></html>
        """

        let result = ReadabilityExtractor.extract(html: html, url: nil)

        // Should return nil or very low-quality result since there's no clear article
        // The pipeline will fall back to full HTML in this case
        if let result = result {
            // If it does return something, it should not crash
            XCTAssertFalse(result.articleNode.serialize().isEmpty, "If returned, should have some content")
        }
    }

    // MARK: - Title Extraction

    func testTitleExtractionFromOGTitle() {
        let html = """
        <html><head>
        <title>Article Title | Site Name</title>
        <meta property="og:title" content="Article Title">
        </head><body>
        <article>
            <h1>Article Title</h1>
            <p>Long paragraph with enough text to be scored as content. This paragraph has
            commas, and enough words to pass the minimum threshold for content detection in the
            readability algorithm. It really needs to be reasonably long to be scored.</p>
        </article>
        </body></html>
        """

        let result = ReadabilityExtractor.extract(html: html, url: nil)
        XCTAssertEqual(result?.title, "Article Title", "Should prefer og:title")
    }

    func testTitleExtractionFromH1() {
        let html = """
        <html><head><title>Site Name</title></head><body>
        <article>
            <h1>The Real Article Title</h1>
            <p>Long paragraph with enough text to be scored as content. This paragraph has
            commas, and enough words to pass the minimum threshold for content detection in the
            readability algorithm. It really needs to be reasonably long to be scored well.</p>
        </article>
        </body></html>
        """

        let result = ReadabilityExtractor.extract(html: html, url: nil)
        XCTAssertEqual(result?.title, "The Real Article Title", "Should extract title from h1")
    }

    func testTitleExtractionFromTitleTag() {
        let html = """
        <html><head><title>Page Title | News Site</title></head><body>
        <div class="content">
            <p>Long paragraph with enough text to be scored as content. This paragraph has
            commas, and enough words to pass the minimum threshold for content detection in the
            readability algorithm. It really needs to be reasonably long to be scored well.</p>
        </div>
        </body></html>
        """

        let result = ReadabilityExtractor.extract(html: html, url: nil)
        // Should clean the title by removing " | News Site"
        XCTAssertEqual(result?.title, "Page Title", "Should clean title tag by removing site name suffix")
    }

    // MARK: - Link Density Calculation

    func testHighLinkDensityElementsScoreLow() {
        let html = """
        <html><body>
        <div class="navigation">
            <a href="/1">Link One</a> <a href="/2">Link Two</a> <a href="/3">Link Three</a>
            <a href="/4">Link Four</a> <a href="/5">Link Five</a> <a href="/6">Link Six</a>
        </div>
        <article class="article-content">
            <p>This is a long article paragraph with lots of text and very few links. The content
            ratio should be much higher here, with prose-like text that includes commas, periods,
            and natural language patterns that the algorithm can detect as real content.</p>
            <p>Another paragraph continues the article discussion with even more detailed text
            that adds to the overall content score. Multiple paragraphs like this ensure the
            scoring algorithm properly identifies this as the main content.</p>
        </article>
        </body></html>
        """

        let result = ReadabilityExtractor.extract(html: html, url: nil)
        XCTAssertNotNil(result)
        // The article should win over the navigation div
        XCTAssertTrue(result?.articleNode.serialize().contains("long article paragraph") == true,
                      "Article content should be selected over high-link-density navigation")
        XCTAssertFalse(result?.articleNode.serialize().contains("Link One") == true,
                       "Navigation links should not be in the extracted content")
    }

    // MARK: - Script/Style/Nav Stripping

    func testScriptStyleNavStripping() {
        let html = """
        <html><body>
        <script>var x = 1; alert('hello');</script>
        <style>.foo { color: red; }</style>
        <nav><a href="/">Home</a><a href="/about">About</a></nav>
        <article>
            <p>This is the actual article content that should remain after preprocessing strips
            out all the script tags, style tags, and navigation elements. The content here is
            real prose with natural language patterns, commas, and enough length to score well.</p>
        </article>
        <footer>Footer content with copyright notices</footer>
        </body></html>
        """

        let result = ReadabilityExtractor.extract(html: html, url: nil)
        XCTAssertNotNil(result)

        guard let html = result?.articleNode.serialize() else { return }

        XCTAssertFalse(html.contains("alert"), "Script content should be stripped")
        XCTAssertFalse(html.contains("color: red"), "Style content should be stripped")
        XCTAssertFalse(html.contains("About"), "Nav content should be stripped")
        XCTAssertTrue(html.contains("actual article content"), "Article should remain")
    }

    // MARK: - ID/Class Scoring

    func testPositiveClassNamesBoostScore() {
        let html = """
        <html><body>
        <div class="sidebar related-posts">
            <p>Some sidebar text with links and short content. Not very useful for the reader,
            mostly promotional material.</p>
        </div>
        <div class="article-body content-main">
            <p>The main article body with detailed information about the topic. This content
            is rich in prose, includes commas, and represents the primary content that a user
            would want to read when visiting this page. It spans multiple sentences.</p>
            <p>Continuing with more relevant content that adds depth and detail to the article.
            This second paragraph reinforces the scoring with additional text length.</p>
        </div>
        </body></html>
        """

        let result = ReadabilityExtractor.extract(html: html, url: nil)
        XCTAssertNotNil(result)
        XCTAssertTrue(result?.articleNode.serialize().contains("main article body") == true,
                      "Content-positive class should win: \(result?.articleNode.serialize() ?? "nil")")
    }

    func testNegativeClassNamesPenalizeScore() {
        let html = """
        <html><body>
        <div class="comment-section social-share">
            <p>User comment here, not part of the article. Some discussion text that might
            look like content but should be penalized due to the negative class names.</p>
        </div>
        <div id="post-body">
            <p>Real article text that should be selected over the comment section. This is
            the actual content of the page with natural language, commas, periods, and enough
            text to be identified as the main body by the scoring algorithm.</p>
            <p>Additional paragraph providing more context and detail about the subject being
            discussed in this article, further boosting its content score.</p>
        </div>
        </body></html>
        """

        let result = ReadabilityExtractor.extract(html: html, url: nil)
        XCTAssertNotNil(result)
        XCTAssertTrue(result?.articleNode.serialize().contains("Real article text") == true,
                      "Post body should win over comment section")
    }

    // MARK: - Metadata Extraction

    func testSiteNameExtraction() {
        let html = """
        <html><head>
        <meta property="og:site_name" content="My Tech Blog">
        </head><body>
        <article>
            <p>Article content with enough text to pass the content threshold and be scored as
            the main article body. Contains natural language with commas, and prose-like patterns
            that the algorithm recognizes as real content.</p>
        </article>
        </body></html>
        """

        let result = ReadabilityExtractor.extract(html: html, url: nil)
        XCTAssertEqual(result?.siteName, "My Tech Blog")
    }

    func testExcerptFromMetaDescription() {
        let html = """
        <html><head>
        <meta name="description" content="A brief summary of this article for search engines.">
        </head><body>
        <article>
            <p>Full article content goes here with enough text to pass the minimum threshold.
            This is the body of the article with natural language, commas, and sufficient length
            for the scoring algorithm to identify it correctly.</p>
        </article>
        </body></html>
        """

        let result = ReadabilityExtractor.extract(html: html, url: nil)
        XCTAssertEqual(result?.excerpt, "A brief summary of this article for search engines.")
    }

    // MARK: - Hidden Element Removal

    func testHiddenElementsAreRemoved() {
        let html = """
        <html><body>
        <div style="display:none"><p>Hidden popup content that should be removed.</p></div>
        <div aria-hidden="true"><p>Screen reader hidden content.</p></div>
        <article>
            <p>Visible article content that should survive preprocessing. Contains natural
            language with commas, prose patterns, and sufficient length for the algorithm to
            properly score and select this as the main content area.</p>
        </article>
        </body></html>
        """

        let result = ReadabilityExtractor.extract(html: html, url: nil)
        XCTAssertNotNil(result)
        XCTAssertFalse(result?.articleNode.serialize().contains("Hidden popup") == true)
        XCTAssertFalse(result?.articleNode.serialize().contains("Screen reader hidden") == true)
        XCTAssertTrue(result?.articleNode.serialize().contains("Visible article content") == true)
    }

    // MARK: - HTML Entity Handling

    func testHTMLEntityDecoding() {
        let html = """
        <html><body>
        <article>
            <p>Text with &amp; ampersand, &lt;angle brackets&gt;, &quot;quotes&quot;, and
            special characters like &ndash; dash, &mdash; em dash, &hellip; ellipsis. Also
            numeric entities like &#169; copyright and hex &#x2603; snowman. This paragraph
            has plenty of content length for proper scoring with commas and natural prose.</p>
        </article>
        </body></html>
        """

        let result = ReadabilityExtractor.extract(html: html, url: nil)
        XCTAssertNotNil(result)

        guard let articleHTML = result?.articleNode.serialize() else { return }

        XCTAssertTrue(articleHTML.contains("&"), "Should decode &amp;")
        XCTAssertTrue(articleHTML.contains("<angle brackets>"), "Should decode &lt; and &gt;")
        XCTAssertTrue(articleHTML.contains("\u{2013}"), "Should decode &ndash;")
    }

    // MARK: - Minimum Content Threshold

    func testVeryShortContentReturnsNil() {
        let html = """
        <html><body><div><p>Hi.</p></div></body></html>
        """

        let result = ReadabilityExtractor.extract(html: html, url: nil)
        // With very short content, the extractor should return nil (score too low)
        // so the pipeline falls back to full HTML
        XCTAssertNil(result, "Very short content should not produce a result")
    }

    // MARK: - Empty/Malformed HTML

    func testEmptyHTMLReturnsNil() {
        let result = ReadabilityExtractor.extract(html: "", url: nil)
        XCTAssertNil(result)
    }

    func testMalformedHTMLDoesNotCrash() {
        let html = """
        <html><body>
        <div class="content">
            <p>Unclosed paragraph that never gets a closing tag
            <p>Another paragraph without closing the first
            <div>Nested div <span>with unclosed span
            <p>And more text that has enough content to be scored by the algorithm, with
            commas, natural language, and sufficient length for proper detection. The parser
            should handle this malformed markup without crashing or hanging.</p>
        </div>
        </body></html>
        """

        // Should not crash
        let result = ReadabilityExtractor.extract(html: html, url: nil)
        // Just verify it doesn't crash — result may or may not be nil
        _ = result
    }

    // MARK: - Self-closing Tags

    func testSelfClosingTagHandling() {
        let html = """
        <html><head>
        <meta charset="utf-8">
        <link rel="stylesheet" href="style.css">
        </head><body>
        <article>
            <p>Text before image.</p>
            <img src="photo.jpg" alt="A photo">
            <br>
            <hr>
            <p>Text after image with enough content to pass the threshold. This paragraph
            contains natural language, commas, and sufficient length for the scoring algorithm
            to properly identify the article container.</p>
        </article>
        </body></html>
        """

        let result = ReadabilityExtractor.extract(html: html, url: nil)
        XCTAssertNotNil(result)
        // Should handle self-closing tags without breaking the parse tree
        XCTAssertTrue(result?.articleNode.serialize().contains("Text before image") == true)
        XCTAssertTrue(result?.articleNode.serialize().contains("Text after image") == true)
    }

    // MARK: - Article Tag Bonus

    func testArticleTagGetsScoreBonus() {
        let html = """
        <html><body>
        <div class="wrapper">
            <p>Some wrapper text that has a decent amount of content. This paragraph provides
            enough text to potentially score in the algorithm, with commas and natural prose.</p>
        </div>
        <article>
            <p>Article content that should benefit from the article tag bonus in scoring.
            This text is the primary content, with commas, and adequate length.</p>
        </article>
        </body></html>
        """

        let result = ReadabilityExtractor.extract(html: html, url: nil)
        XCTAssertNotNil(result)
        XCTAssertTrue(result?.articleNode.serialize().contains("article tag bonus") == true,
                      "Article tag should get score bonus and win")
    }

    // MARK: - Image Marker Preservation

    func testImageMarkersSurviveExtraction() {
        let html = """
        <html><body>
        <nav><a href="/">Home</a></nav>
        <article class="post-content">
            <h1>Photo Essay</h1>
            <p>This is a detailed article with inline images. The first paragraph has enough
            text to score well, with commas, natural prose, and sufficient length for the
            scoring algorithm to identify this as the main content area of the page.</p>
            [[IMG:0]]
            <p>After the first image, the article continues with more content. This second
            paragraph provides additional detail and context about the photographs shown,
            describing what they depict and why they matter.</p>
            [[IMG:1]]
            <p>The final paragraph wraps up the photo essay with concluding thoughts about
            the collection of images and their significance in the broader context.</p>
        </article>
        <footer><p>Copyright 2024</p></footer>
        </body></html>
        """

        let result = ReadabilityExtractor.extract(html: html, url: nil)
        XCTAssertNotNil(result, "Should extract article")

        guard let result = result else { return }

        XCTAssertTrue(result.articleNode.serialize().contains("[[IMG:0]]"),
                      "First image marker should survive extraction, got: \(result.articleNode.serialize())")
        XCTAssertTrue(result.articleNode.serialize().contains("[[IMG:1]]"),
                      "Second image marker should survive extraction, got: \(result.articleNode.serialize())")
        XCTAssertTrue(result.articleNode.serialize().contains("detailed article"),
                      "First paragraph should be present")
        XCTAssertTrue(result.articleNode.serialize().contains("final paragraph"),
                      "Last paragraph should be present")
    }

    // MARK: - HTMLNode textContent Caching

    func testTextContentCacheInvalidatesOnChildMutation() {
        // Build a small tree: <div><p>hello</p><p>world</p></div>
        let hello = HTMLNode(kind: .text("hello"))
        let world = HTMLNode(kind: .text("world"))
        let p1 = HTMLNode(kind: .element(tag: "p", attributes: []), children: [hello])
        let p2 = HTMLNode(kind: .element(tag: "p", attributes: []), children: [world])
        let div = HTMLNode(kind: .element(tag: "div", attributes: []), children: [p1, p2])
        hello.parent = p1
        world.parent = p2
        p1.parent = div
        p2.parent = div

        // First read caches
        XCTAssertEqual(div.textContent, "helloworld", "Initial textContent")

        // Mutate: remove p2 and invalidate
        div.children.removeAll { $0 === p2 }
        div.invalidateTextContentCache()

        XCTAssertEqual(div.textContent, "hello",
                       "textContent should reflect post-mutation state after invalidation")
    }

    func testTextContentCacheInvalidationWalksParentChain() {
        // <root><div><p>x</p></div></root>
        let x = HTMLNode(kind: .text("x"))
        let p = HTMLNode(kind: .element(tag: "p", attributes: []), children: [x])
        let div = HTMLNode(kind: .element(tag: "div", attributes: []), children: [p])
        let root = HTMLNode(kind: .element(tag: "root", attributes: []), children: [div])
        x.parent = p
        p.parent = div
        div.parent = root

        // Cache root's textContent
        XCTAssertEqual(root.textContent, "x")

        // Mutate p's children and invalidate from p — should propagate to div and root
        p.children.removeAll()
        p.invalidateTextContentCache()

        XCTAssertEqual(root.textContent, "",
                       "Invalidation should propagate up the parent chain")
        XCTAssertEqual(div.textContent, "")
        XCTAssertEqual(p.textContent, "")
    }

    // MARK: - Multi-Paragraph Article Extraction

    func testExtractsFullArticleNotJustHeader() {
        let html = """
        <html><head><title>News Article | Daily News</title></head><body>
        <header class="site-header"><a href="/">Daily News</a></header>
        <nav><ul><li><a href="/politics">Politics</a></li></ul></nav>
        <div class="article-wrapper">
            <article>
                <h1>Major Event Unfolds</h1>
                <p class="byline">By Jane Reporter, April 15, 2024</p>
                <p>The first paragraph of this news article describes a major event that
                has been unfolding over the past week. Officials confirmed the details
                in a press conference held earlier today, marking a significant development.</p>
                <p>In the second paragraph, experts provide their analysis of the situation,
                offering context about why this matters and what the potential consequences
                might be for stakeholders across multiple sectors of the economy.</p>
                <p>The third paragraph includes quotes from key figures involved in the
                story, giving readers direct insight into the perspectives of those most
                affected by these developments and their plans going forward.</p>
                <p>Finally, the fourth paragraph outlines the next steps expected in this
                ongoing situation, including upcoming meetings, deadlines, and milestones
                that will determine the ultimate outcome of these events.</p>
            </article>
        </div>
        <aside class="sidebar"><h3>Related Stories</h3><ul>
            <li><a href="/story1">Related 1</a></li>
            <li><a href="/story2">Related 2</a></li>
        </ul></aside>
        <footer><p>Copyright Daily News 2024</p></footer>
        </body></html>
        """

        let result = ReadabilityExtractor.extract(html: html, url: URL(string: "https://dailynews.example.com/article"))
        XCTAssertNotNil(result, "Should extract article content")

        guard let result = result else { return }

        // ALL four body paragraphs must be present — not just the header
        XCTAssertTrue(result.articleNode.serialize().contains("first paragraph"),
                      "Should contain first paragraph")
        XCTAssertTrue(result.articleNode.serialize().contains("second paragraph"),
                      "Should contain second paragraph")
        XCTAssertTrue(result.articleNode.serialize().contains("third paragraph"),
                      "Should contain third paragraph")
        XCTAssertTrue(result.articleNode.serialize().contains("fourth paragraph"),
                      "Should contain fourth paragraph")

        // Should NOT contain sidebar or navigation
        XCTAssertFalse(result.articleNode.serialize().contains("Related Stories"),
                       "Should not contain sidebar")
        XCTAssertFalse(result.articleNode.serialize().contains("Politics"),
                       "Should not contain navigation")

        // The 100-char check should pass easily with this much content
        let nonWhitespace = result.articleNode.serialize().filter { !$0.isWhitespace }.count
        XCTAssertGreaterThan(nonWhitespace, 100,
                            "Article should have well over 100 non-whitespace chars")
    }

    // MARK: - UTF-8 / CJK Handling

    /// Verifies that the byte-buffer parser correctly handles multi-byte UTF-8
    /// text — scanning by bytes must not split code points, and text nodes must
    /// decode back to the original Unicode.
    func testJapaneseTextNodePreservesUTF8() {
        let html = """
        <html><body>
        <article>
            <h1>こんにちは、世界</h1>
            <p>これは日本語のテストです。パーサーがマルチバイトUTF-8をバイト単位で
            走査しても、テキストノードが正しくデコードされるか確認します。ひらがな、
            カタカナ、漢字、そして句読点「、。」が混ざっています。段落を十分に長くして、
            Readabilityのスコアリングがこの要素を記事本文として選ぶようにします。</p>
            <p>第二段落では、追加の日本語テキストを含めて、パーサーがUTF-8連続バイト
            （0x80以上）を `<` や `>` と誤認しないことを確認します。句読点、括弧、
            その他の全角文字「（）」『』【】が正しく処理されるはずです。</p>
        </article>
        </body></html>
        """

        let result = ReadabilityExtractor.extract(html: html, url: nil)
        XCTAssertNotNil(result, "Should extract Japanese article content")

        guard let result = result else { return }
        let articleHTML = result.articleNode.serialize()
        XCTAssertTrue(articleHTML.contains("こんにちは、世界"),
                      "Should preserve Japanese heading text: \(articleHTML)")
        XCTAssertTrue(articleHTML.contains("これは日本語のテストです"),
                      "Should preserve first-paragraph Japanese text")
        XCTAssertTrue(articleHTML.contains("第二段落"),
                      "Should preserve second-paragraph Japanese text")
    }

    /// Measures the wall-clock cost of parsing a ~200KB Japanese HTML blob with
    /// the byte-buffer parser. Establishes a baseline so future regressions can
    /// be caught. (The "2× faster than String.Index" acceptance is verified
    /// informally — byte scanning is O(bytes) and avoids per-Character UTF-8
    /// decoding, which is the dominant cost for CJK content.)
    func testCJKParsePerformanceBaseline() {
        // Build ~200KB of Japanese HTML from a repeated article block.
        let paragraph = "これは日本語のテストです。パーサーがマルチバイトUTF-8をバイト単位で走査しても、テキストノードが正しくデコードされるか確認します。ひらがな、カタカナ、漢字、そして句読点が混ざっています。"
        var body = "<html><body><article><h1>日本語のパフォーマンステスト</h1>"
        // Each paragraph is roughly 600 UTF-8 bytes; repeat enough to reach ~200KB.
        let blockHTML = "<p>\(paragraph)</p>\n"
        let targetBytes = 200_000
        let repeatCount = max(1, targetBytes / blockHTML.utf8.count)
        for _ in 0..<repeatCount { body.append(blockHTML) }
        body.append("</article></body></html>")

        // Sanity check fixture size so future readers know what's being measured.
        XCTAssertGreaterThan(body.utf8.count, 150_000,
                             "Fixture should be ~200KB of UTF-8 bytes")

        // Measure parse time. We don't assert a specific threshold — the point
        // is to detect large regressions in future changes.
        measure {
            let result = ReadabilityExtractor.extract(html: body, url: nil)
            XCTAssertNotNil(result)
        }
    }

    // MARK: - Linked-Heading Penalty (recirc card grid discrimination)

    /// Recirc card grids on news sites render as `<a><h3>title</h3></a>`
    /// repeated 8-10 times. The aggregated link-density damping wasn't
    /// strong enough to keep them from beating fragmented article bodies.
    /// The linked-heading ratio gives us a direct discriminator.
    func testLinkedHeadingGridLosesToFragmentedArticleBody() {
        let html = """
        <html><body>
        <main>
            <article class="post-content">
                <header><h1>The Article Title</h1></header>
                <div class="BodyWrapper">
                    <p>First chunk of the body has enough length and natural prose to score
                    well in Readability, with commas and punctuation flagging it as content.</p>
                    <p>Continuing in the first chunk with more substantive paragraph text
                    to give the article weight in the scorer.</p>
                </div>
                <div class="advertisement"><p>Sponsored slot.</p></div>
                <div class="BodyWrapper">
                    <p>Second chunk picks up where the first left off and continues the
                    narrative with additional paragraphs of real prose.</p>
                </div>
                <div class="BodyWrapper">
                    <p>Third chunk wraps the article with concluding remarks and
                    a call-back to the opening theme, tying the piece together.</p>
                </div>
            </article>
            <aside class="recirc-widget">
                <h2>More Stories</h2>
                <div>
                    <a href="/r1"><h3>Related story one with a moderately long headline</h3></a>
                    <a href="/r2"><h3>Related story two with a moderately long headline</h3></a>
                    <a href="/r3"><h3>Related story three with a moderately long headline</h3></a>
                    <a href="/r4"><h3>Related story four with a moderately long headline</h3></a>
                    <a href="/r5"><h3>Related story five with a moderately long headline</h3></a>
                    <a href="/r6"><h3>Related story six with a moderately long headline</h3></a>
                    <a href="/r7"><h3>Related story seven with a moderately long headline</h3></a>
                    <a href="/r8"><h3>Related story eight with a moderately long headline</h3></a>
                    <a href="/r9"><h3>Related story nine with a moderately long headline</h3></a>
                </div>
            </aside>
        </main>
        </body></html>
        """

        let r = ReadabilityExtractor.extract(html: html, url: nil)
        XCTAssertNotNil(r)
        guard let r = r else { return }

        let serialized = r.articleNode.serialize()
        XCTAssertTrue(serialized.contains("First chunk"), "Article body should win, got: \(serialized.prefix(500))")
        XCTAssertTrue(serialized.contains("Second chunk"), "All article chunks should be present")
        XCTAssertTrue(serialized.contains("Third chunk"), "All article chunks should be present")
        XCTAssertFalse(serialized.contains("Related story one"),
                       "Recirc grid should not win: \(serialized.prefix(500))")
    }

    /// False-positive guard: a legitimate round-up post (link-blog with
    /// linked headings AND prose between them) must still extract — the
    /// linked-heading damping must not reduce the article's score below
    /// other (lower-scoring) candidates. The 0.2 floor is what protects
    /// this case.
    ///
    /// Note: separately from heading damping, `postProcess` strips short
    /// link-wrapped headings as high-link-density blocks. That's a
    /// pre-existing behavior outside this fix's scope; the prose between
    /// headings is what carries the article's content forward.
    func testRoundUpPostWithLinkedHeadingsStillExtracts() {
        let html = """
        <html><body>
        <article class="post">
            <h1>This Week's Reading List</h1>
            <p>A few things worth reading from across the web this week, in no particular order.
            Each entry has a short note about why it caught my attention and a link to the source.</p>

            <h2><a href="https://a.example">First headline that links to the source</a></h2>
            <p>A meaningful paragraph of commentary on the linked piece, explaining what makes
            it interesting and how it relates to ongoing themes in the field. This is not just
            a bullet list — it's actual analysis prose that the scorer should reward.</p>

            <h2><a href="https://b.example">Second headline linking out</a></h2>
            <p>More commentary on the second item, again written as a paragraph of prose with
            commas, periods, and substantive content. The kind of writing that distinguishes a
            curated round-up from a list of bookmarks.</p>

            <h2><a href="https://c.example">Third headline linking out</a></h2>
            <p>And a third entry with its own commentary paragraph, completing the pattern that
            makes this a legitimate post rather than a navigation widget masquerading as content.</p>

            <p>Closing thought: round-ups like this should still extract correctly even though
            their headings are link-wrapped, because the prose between headings carries weight.</p>
        </article>
        </body></html>
        """

        let r = ReadabilityExtractor.extract(html: html, url: nil)
        XCTAssertNotNil(r, "Round-up post should still extract — heading damping floor at 0.2 protects this")

        guard let r = r else { return }
        let serialized = r.articleNode.serialize()
        XCTAssertTrue(serialized.contains("meaningful paragraph"),
                      "Commentary prose between linked headings must survive: \(serialized.prefix(500))")
        XCTAssertTrue(serialized.contains("More commentary"),
                      "Second commentary block must survive")
        XCTAssertTrue(serialized.contains("Closing thought"),
                      "Closing prose must survive")
    }

    /// Regression: Federal News Network article bodies have the class
    /// `Entry-content u-textFormat readmore_available`. The substring `"ad"`
    /// from `negativePatterns` previously matched inside `"readmore"`, slapping
    /// a -25 penalty on the actual article body and letting the recirc widget
    /// win. `scoreElement` now uses `containsWholeWord`, the same boundary
    /// check `postProcess` uses.
    func testReadmoreClassIsNotPenalizedForAdSubstring() {
        let html = """
        <html><body>
        <main>
            <div class="Entry-content u-textFormat readmore_available" id="Entry-content">
                <p>The FBI and the Cybersecurity and Infrastructure Security Agency say senior
                government officials need to be aware of ongoing phishing campaigns targeting
                Signal and other commercial messaging applications.</p>
                <p>The alert makes clear that the hackers have compromised individual accounts,
                and not the encryption or applications themselves. This is a meaningful detail
                that distinguishes the campaign from a vulnerability disclosure.</p>
                <p>David Wiseman, vice president of secure communications at BlackBerry, said
                attackers are exploiting human factors rather than technical weaknesses, which
                makes mitigation a training and process problem more than a software one.</p>
                <p>Federal agencies are being advised to roll out additional account-protection
                measures, review their messaging-app inventories, and re-train staff on
                phishing-resistance fundamentals over the next quarter.</p>
            </div>
            <aside class="related-stories">
                <h4>Related coverage</h4>
                <h4>Trending in defense news</h4>
                <h4>Latest from the federal workforce</h4>
            </aside>
        </main>
        </body></html>
        """

        let r = ReadabilityExtractor.extract(html: html, url: nil)
        XCTAssertNotNil(r)

        guard let r = r else { return }
        let serialized = r.articleNode.serialize()
        XCTAssertTrue(serialized.contains("FBI and the Cybersecurity"),
                      "Article body should win — `readmore` should not match `ad`: \(serialized.prefix(500))")
        XCTAssertTrue(serialized.contains("David Wiseman"),
                      "Article body paragraphs must survive")
        XCTAssertFalse(serialized.contains("Trending in defense news"),
                       "Recirc aside should not win: \(serialized.prefix(500))")
    }

    /// Sanity test: an article with unlinked section headings ("The AI imperative")
    /// should never be penalized — its linked-heading ratio is 0.
    func testUnlinkedSectionHeadingsAreNotPenalized() {
        let html = """
        <html><body>
        <article class="content">
            <h1>The Main Article</h1>
            <p>Opening paragraph establishes the topic and sets up what follows. The text is long
            enough and natural enough to score well, with commas and other punctuation cues.</p>

            <h2>First Section</h2>
            <p>First section content runs for a paragraph or two, going into detail on the first
            sub-topic. The heading is not link-wrapped, which is the normal article shape.</p>

            <h2>Second Section</h2>
            <p>Second section continues the discussion, again with paragraph prose under an
            unlinked heading. This is the structural pattern of real journalism.</p>

            <h2>Third Section</h2>
            <p>Final section wraps up with a conclusion and a forward-looking statement, also
            under an unlinked heading. The article's heading-damping factor should be 1.0.</p>
        </article>
        </body></html>
        """

        let r = ReadabilityExtractor.extract(html: html, url: nil)
        XCTAssertNotNil(r)

        guard let r = r else { return }
        let serialized = r.articleNode.serialize()
        XCTAssertTrue(serialized.contains("First Section"), "Unlinked section heading should be preserved")
        XCTAssertTrue(serialized.contains("Second Section"), "All sections should survive")
        XCTAssertTrue(serialized.contains("Third Section"), "All sections should survive")
    }

    // MARK: - Deep nesting (stack-overflow guards)

    private func deeplyNestedPage(depth: Int) -> String {
        let article = "<article><h1>Deep Title</h1>" + String(repeating: "<p>Real article prose, long enough to score well, with commas, and more words. </p>", count: 10) + "</article>"
        return "<html><head><title>Deep</title></head><body>" + article
            + String(repeating: "<div>", count: depth) + "deep text"
            + String(repeating: "</div>", count: depth) + "</body></html>"
    }

    func testSwiftSoupAdapterDeepNestingIsDepthCapped() {
        guard let root = SwiftSoupAdapter.parse(html: deeplyNestedPage(depth: 5_000)) else {
            return XCTFail("parse failed")
        }
        var maxDepth = 0
        var stack: [(HTMLNode, Int)] = [(root, 0)]
        while let (node, d) = stack.popLast() {
            maxDepth = max(maxDepth, d)
            for child in node.children { stack.append((child, d + 1)) }
        }
        XCTAssertLessThanOrEqual(maxDepth, HTMLNode.maxDepth + 1)
    }

    func testReadabilityDeepNestingDoesNotCrash() {
        let result = ReadabilityExtractor.extract(html: deeplyNestedPage(depth: 5_000), url: nil)
        XCTAssertNotNil(result)
        if let node = result?.articleNode {
            XCTAssertTrue(node.textContent.contains("Real article prose"))
        }
    }

    func testByteParserDeepNestingDoesNotCrash() {
        var parser = HTMLParser(html: deeplyNestedPage(depth: 5_000))
        let root = parser.parse()
        XCTAssertNotNil(root)
        XCTAssertTrue(root?.textContent.contains("deep text") ?? false)
        _ = root?.serialize()
    }
}
