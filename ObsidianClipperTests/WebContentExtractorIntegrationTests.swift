import XCTest
@testable import ClipperExtension

/// Direct integration tests for `WebContentExtractor.extract(from:)`. Each
/// scenario constructs an `NSExtensionContext` containing a particular
/// attachment shape — modeled on what real iOS sharing apps actually send —
/// and asserts that the extractor produces the right `RawContent`.
///
/// Distinct from `ShareViewControllerHarnessTests`, which drives the full
/// `ClippingPipeline.run` end-to-end. These tests exercise *only* the
/// `NSExtensionContext` → `RawContent` adapter, so a regression in input
/// dispatch (UTI matching, type casting, attachment iteration) shows up here
/// in isolation rather than as a confusing pipeline-level failure.
///
/// Salvaged from `debug/share-input-instrument` (the integration harness used
/// to diagnose the Safari `public.property-list` → `com.apple.property-list`
/// UTI bug). Scenarios 1 and 2 now use the correct UTI and serve as
/// regression tests against any future revert of that fix.
final class WebContentExtractorIntegrationTests: XCTestCase {

    // MARK: - Mock NSExtensionContext

    /// Minimal mock so we can hand a synthetic input-items list to
    /// `WebContentExtractor.extract`. `inputItems` is the only property the
    /// extractor reads from the context.
    private final class MockExtensionContext: NSExtensionContext {
        let mockInputItems: [NSExtensionItem]
        init(items: [NSExtensionItem]) {
            self.mockInputItems = items
            super.init()
        }
        override var inputItems: [Any] { mockInputItems }
    }

    private func runExtract(items: [NSExtensionItem]) async -> WebContentExtractor.RawContent? {
        let context = MockExtensionContext(items: items)
        return await WebContentExtractor.extract(from: context)
    }

    // These scenarios use deliberately tiny HTML payloads and example.com
    // URLs. Disable the thin-live-HTML discard so the payloads survive, and
    // stub the session so any fallback fetch fails fast instead of touching
    // the network.
    override func setUp() {
        super.setUp()
        WebContentExtractor.minimumLiveHTMLBytes = 0
        WebContentExtractor.sessionOverride = MockURLProtocol.makeRefusingSession()
    }

    override func tearDown() {
        WebContentExtractor.minimumLiveHTMLBytes = 1024
        WebContentExtractor.sessionOverride = nil
        MockURLProtocol.handler = nil
        super.tearDown()
    }

    // MARK: - Scenarios

    /// Scenario 1: Safari-style — single item with two providers, one with
    /// `public.url`, one with `com.apple.property-list` carrying the JS
    /// preprocessing results dict. This is what Safari sends when `Action.js`
    /// runs successfully. The correct UTI is `com.apple.property-list`; a
    /// previous `public.property-list` value matched nothing on real iOS,
    /// causing every Safari clip to write a frontmatter-only file.
    func testSafariStyleURLPlusPropertyList() async {
        let item = NSExtensionItem()
        item.attributedContentText = NSAttributedString(string: "Test page title | Example")

        let urlProvider = NSItemProvider(item: URL(string: "https://example.com/article")! as NSURL,
                                         typeIdentifier: "public.url")
        let plistData: [String: Any] = [
            NSExtensionJavaScriptPreprocessingResultsKey: [
                "title": "Test page title",
                "URL": "https://example.com/article",
                "html": "<html><body><p>Body content for the test article.</p></body></html>"
            ]
        ]
        let plistProvider = NSItemProvider(item: plistData as NSDictionary,
                                           typeIdentifier: "com.apple.property-list")

        item.attachments = [urlProvider, plistProvider]

        let result = await runExtract(items: [item])
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.title, "Test page title")
        XCTAssertEqual(result?.url?.absoluteString, "https://example.com/article")
        XCTAssertNotNil(result?.html, "Action.js HTML must be picked up via the property-list provider")
        XCTAssertTrue(result?.html?.contains("Body content for the test article.") ?? false)
    }

    /// Scenario 2: Safari but the property-list comes back FLAT — no
    /// `NSExtensionJavaScriptPreprocessingResultsKey` wrapping, just the
    /// fields at the top level. The extractor should fall back to the URL
    /// provider rather than reading garbage.
    func testSafariStyleFlatPropertyList() async {
        let item = NSExtensionItem()
        item.attributedContentText = NSAttributedString(string: "Test page title | Example")

        let urlProvider = NSItemProvider(item: URL(string: "https://example.com/article")! as NSURL,
                                         typeIdentifier: "public.url")
        let flatPlistData: [String: Any] = [
            "title": "Test page title",
            "URL": "https://example.com/article",
            "html": "<html><body><p>Body content via flat dict.</p></body></html>"
        ]
        let plistProvider = NSItemProvider(item: flatPlistData as NSDictionary,
                                           typeIdentifier: "com.apple.property-list")

        item.attachments = [urlProvider, plistProvider]

        let result = await runExtract(items: [item])
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.url?.absoluteString, "https://example.com/article")
        // Flat dict without the NSExtensionJavaScriptPreprocessingResultsKey
        // wrapper must not be mistakenly read as preprocessing results.
        XCTAssertFalse(
            result?.html?.contains("Body content via flat dict.") ?? false,
            "Flat property-list payload must not be treated as Action.js results"
        )
    }

    /// Scenario 3: URL provider returns an `NSURL` (not a Swift `URL`).
    /// Some apps still bridge through Foundation types. The extractor's
    /// `as? URL` cast must accept this.
    func testURLAsNSURL() async {
        let item = NSExtensionItem()
        let nsurl = NSURL(string: "https://example.com/page")!
        let urlProvider = NSItemProvider(item: nsurl, typeIdentifier: "public.url")
        item.attachments = [urlProvider]

        let result = await runExtract(items: [item])
        XCTAssertEqual(result?.url?.absoluteString, "https://example.com/page")
    }

    /// Scenario 4: empty share — an extension item with no attachments.
    /// The extractor returns a `RawContent` with everything nil (and a
    /// fallback title of "Untitled") rather than nil; the pipeline reads
    /// `html == nil && url == nil && sharedImages.isEmpty` to detect "no
    /// real content" and throw `.noContent`. Pin that contract here so a
    /// future refactor of the empty-input handling doesn't silently change
    /// the pipeline's empty-detection.
    func testEmptyContext() async {
        let item = NSExtensionItem()
        item.attachments = []

        let result = await runExtract(items: [item])
        XCTAssertNotNil(result, "extract returns RawContent (with fallback title) even on empty input")
        XCTAssertNil(result?.url, "no URL provider → url should be nil")
        XCTAssertNil(result?.html, "no HTML provider → html should be nil")
        XCTAssertNil(result?.plainText, "no plain-text provider → plainText should be nil")
        XCTAssertTrue(result?.sharedImages.isEmpty ?? false, "no image provider → sharedImages should be empty")
        XCTAssertEqual(result?.title, "Untitled", "fallback title kicks in when there's no URL host or HTML <title>")
    }
}
