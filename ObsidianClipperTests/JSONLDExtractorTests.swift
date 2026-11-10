import XCTest
@testable import ClipperExtension

final class JSONLDExtractorTests: XCTestCase {

    // MARK: - Single-object Article block

    func testSingleArticleBlockIsExtracted() throws {
        let body = String(repeating: "This is the article body. ", count: 30)
        let html = """
        <html><head>
        <script type="application/ld+json">
        {
          "@context": "https://schema.org",
          "@type": "NewsArticle",
          "headline": "A Headline",
          "articleBody": "\(body)"
        }
        </script>
        </head><body>page</body></html>
        """

        let result = try XCTUnwrap(JSONLDExtractor.tryFastPath(html: html))
        XCTAssertEqual(result.title, "A Headline")
        XCTAssertTrue(result.articleBody.hasPrefix("This is the article body."))
        XCTAssertFalse(result.articleBodyIsHTML)
    }

    // MARK: - Top-level array of objects

    func testArrayOfObjectsPicksLongestArticle() throws {
        let shortBody = String(repeating: "short ", count: 100)   // ~600 chars
        let longBody = String(repeating: "long body content. ", count: 80) // ~1500 chars
        let html = """
        <script type="application/ld+json">
        [
          {"@type": "Article", "headline": "Short", "articleBody": "\(shortBody)"},
          {"@type": "BlogPosting", "headline": "Long", "articleBody": "\(longBody)"}
        ]
        </script>
        """

        let result = try XCTUnwrap(JSONLDExtractor.tryFastPath(html: html))
        XCTAssertEqual(result.title, "Long")
        XCTAssertGreaterThan(result.articleBody.count, 1000)
    }

    // MARK: - @graph wrapper

    func testGraphWrapperIsTraversed() throws {
        let body = String(repeating: "graph article body chunk. ", count: 30)
        let html = """
        <script type="application/ld+json">
        {
          "@context": "https://schema.org",
          "@graph": [
            {"@type": "WebPage", "name": "Page"},
            {"@type": "BreadcrumbList"},
            {"@type": "NewsArticle", "headline": "Graphed", "articleBody": "\(body)"}
          ]
        }
        </script>
        """

        let result = try XCTUnwrap(JSONLDExtractor.tryFastPath(html: html))
        XCTAssertEqual(result.title, "Graphed")
        XCTAssertGreaterThanOrEqual(result.articleBody.count, 500)
    }

    // MARK: - HTML vs plain text body detection

    func testHTMLBodyIsDetected() throws {
        let body = "<p>" + String(repeating: "Real HTML content here. ", count: 30) + "</p>"
        let html = """
        <script type="application/ld+json">
        {"@type": "Article", "headline": "HTML Body", "articleBody": \(jsonString(body))}
        </script>
        """

        let result = try XCTUnwrap(JSONLDExtractor.tryFastPath(html: html))
        XCTAssertTrue(result.articleBodyIsHTML, "Expected HTML body to be detected")
    }

    func testPlainTextBodyIsNotMarkedAsHTML() throws {
        let body = String(repeating: "Just prose, no tags here. ", count: 30)
        let html = """
        <script type="application/ld+json">
        {"@type": "Article", "headline": "Plain", "articleBody": \(jsonString(body))}
        </script>
        """

        let result = try XCTUnwrap(JSONLDExtractor.tryFastPath(html: html))
        XCTAssertFalse(result.articleBodyIsHTML)
    }

    // MARK: - Below-threshold body returns nil

    func testShortBodyReturnsNil() {
        let body = "Too short."
        let html = """
        <script type="application/ld+json">
        {"@type": "Article", "headline": "Tiny", "articleBody": "\(body)"}
        </script>
        """
        XCTAssertNil(JSONLDExtractor.tryFastPath(html: html, minBodyChars: 500))
    }

    // MARK: - No JSON-LD returns nil

    func testNoJSONLDReturnsNil() {
        let html = "<html><body><p>No structured data here.</p></body></html>"
        XCTAssertNil(JSONLDExtractor.tryFastPath(html: html))
    }

    // MARK: - imageURLs extraction (Schema.org `image` field)

    func testImageURLsAbsentYieldsEmptyArray() throws {
        let body = String(repeating: "Plain prose without image. ", count: 30)
        let html = """
        <script type="application/ld+json">
        {"@type": "Article", "headline": "NoImage", "articleBody": \(jsonString(body))}
        </script>
        """
        let result = try XCTUnwrap(JSONLDExtractor.tryFastPath(html: html))
        XCTAssertTrue(result.imageURLs.isEmpty)
    }

    func testImageURLsFromBareString() throws {
        let body = String(repeating: "Lead image is a string. ", count: 30)
        let html = """
        <script type="application/ld+json">
        {"@type": "Article", "headline": "StringImage",
         "articleBody": \(jsonString(body)),
         "image": "https://example.com/hero.jpg"}
        </script>
        """
        let result = try XCTUnwrap(JSONLDExtractor.tryFastPath(html: html))
        XCTAssertEqual(result.imageURLs.map(\.absoluteString), ["https://example.com/hero.jpg"])
    }

    func testImageURLsFromImageObject() throws {
        let body = String(repeating: "Lead image is an ImageObject. ", count: 30)
        let html = """
        <script type="application/ld+json">
        {"@type": "Article", "headline": "ObjectImage",
         "articleBody": \(jsonString(body)),
         "image": {"@type": "ImageObject", "url": "https://example.com/hero2.jpg"}}
        </script>
        """
        let result = try XCTUnwrap(JSONLDExtractor.tryFastPath(html: html))
        XCTAssertEqual(result.imageURLs.map(\.absoluteString), ["https://example.com/hero2.jpg"])
    }

    func testImageURLsFromArrayOfMixedShapes() throws {
        let body = String(repeating: "Multiple image shapes. ", count: 30)
        let html = """
        <script type="application/ld+json">
        {"@type": "Article", "headline": "ArrayImage",
         "articleBody": \(jsonString(body)),
         "image": [
           "https://example.com/a.jpg",
           {"@type": "ImageObject", "url": "https://example.com/b.jpg"},
           "https://example.com/a.jpg"
         ]}
        </script>
        """
        let result = try XCTUnwrap(JSONLDExtractor.tryFastPath(html: html))
        // Order preserved; duplicate dropped.
        XCTAssertEqual(
            result.imageURLs.map(\.absoluteString),
            ["https://example.com/a.jpg", "https://example.com/b.jpg"]
        )
    }

    // MARK: - Array @type matches

    func testArrayTypeMatches() throws {
        let body = String(repeating: "multi-typed article body. ", count: 30)
        let html = """
        <script type="application/ld+json">
        {"@type": ["Article", "NewsArticle"], "headline": "Multi", "articleBody": \(jsonString(body))}
        </script>
        """

        let result = try XCTUnwrap(JSONLDExtractor.tryFastPath(html: html))
        XCTAssertEqual(result.title, "Multi")
    }

    // MARK: - helpers

    /// Encode a Swift string as a JSON string literal so we can drop it
    /// into the script blob without manual escaping.
    private func jsonString(_ s: String) -> String {
        let data = try! JSONSerialization.data(
            withJSONObject: [s], options: [.fragmentsAllowed]
        )
        var json = String(data: data, encoding: .utf8) ?? "[\"\"]"
        // Strip the array brackets to get just the encoded string.
        json.removeFirst()
        json.removeLast()
        return json
    }

    // MARK: - Entities in plain-text bodies

    func testPlainTextBodyEntitiesAreDecoded() throws {
        let filler = String(repeating: "Padding sentence for length. ", count: 20)
        let html = """
        <script type="application/ld+json">
        {"@type": "NewsArticle", "headline": "H", "articleBody": "Fish&nbsp;and chips &amp; peas. \(filler)"}
        </script>
        """
        let result = try XCTUnwrap(JSONLDExtractor.tryFastPath(html: html))
        XCTAssertFalse(result.articleBodyIsHTML)
        XCTAssertFalse(result.articleBody.contains("&nbsp;"))
        XCTAssertFalse(result.articleBody.contains("&amp;"))
        XCTAssertTrue(result.articleBody.hasPrefix("Fish and chips & peas."))
    }

    func testHTMLBodyEntitiesAreLeftForTheParser() throws {
        let filler = String(repeating: "Padding sentence for length. ", count: 20)
        let html = """
        <script type="application/ld+json">
        {"@type": "NewsArticle", "headline": "H", "articleBody": "<p>Fish &amp; chips. \(filler)</p>"}
        </script>
        """
        let result = try XCTUnwrap(JSONLDExtractor.tryFastPath(html: html))
        XCTAssertTrue(result.articleBodyIsHTML)
        XCTAssertTrue(result.articleBody.contains("&amp;"))
    }
}
