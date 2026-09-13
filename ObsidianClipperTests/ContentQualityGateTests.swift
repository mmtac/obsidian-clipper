import XCTest
@testable import ClipperExtension

/// Table-driven tests for the capture quality gate, plus a corpus sweep that
/// guards against false positives: every committed fixture that is expected
/// to save must pass the gate, and every fixture marked `expect_failure`
/// must fail it with the right verdict.
final class ContentQualityGateTests: XCTestCase {

    // MARK: - Synthetic cases

    private let longBody = String(repeating: "All work and no play makes a thin note. ", count: 60)
    private let shortBody = "Just a title."
    private let mediumBody = String(repeating: "A modest but real link-blog post body. ", count: 8)

    func testThinBodyWithNYTGatewayMarkerIsPaywalled() {
        let html = "<html><body><div id=\"gateway-content\"><p>Subscribe for full access.</p></div></body></html>"
        XCTAssertEqual(ContentQualityGate.evaluate(markdown: shortBody, html: html), .paywalled)
    }

    func testThinBodyWithJSONLDNotFreeMarkerIsPaywalled() {
        let html = #"<script type="application/ld+json">{"isAccessibleForFree": false}</script>"#
        XCTAssertEqual(ContentQualityGate.evaluate(markdown: shortBody, html: html), .paywalled)
    }

    func testThinBodyWithQuotedFalseVariantIsPaywalled() {
        let html = #"<script type="application/ld+json">{"isAccessibleForFree":"False"}</script>"#
        XCTAssertEqual(ContentQualityGate.evaluate(markdown: shortBody, html: html), .paywalled)
    }

    func testThinBodyWithoutMarkersIsThinContent() {
        let html = "<html><body><p>Just a title.</p></body></html>"
        XCTAssertEqual(ContentQualityGate.evaluate(markdown: shortBody, html: html), .thinContent)
    }

    func testLongBodyWithPaywallMarkersPasses() {
        // Authenticated NYT/Wired pages legitimately carry
        // isAccessibleForFree:false while serving the full article.
        let html = #"<div id="gateway-content"></div><script type="application/ld+json">{"isAccessibleForFree": false}</script>"#
        XCTAssertEqual(ContentQualityGate.evaluate(markdown: longBody, html: html), .pass)
    }

    func testMediumBodyWithoutMarkersPasses() {
        let html = "<html><body><p>post</p></body></html>"
        XCTAssertEqual(ContentQualityGate.evaluate(markdown: mediumBody, html: html), .pass)
    }

    // MARK: - Corpus sweep

    private struct Criteria: Decodable {
        let expect_failure: String?
    }

    private var corpusDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Tests/Fixtures/extraction-corpus", isDirectory: true)
    }

    /// Every fixture flows through the shipped extraction and then the gate.
    /// Fixtures without `expect_failure` must pass (false-positive guard for
    /// legitimate short pages like example.com); fixtures with it must fail
    /// with the named verdict.
    func testCorpusFixturesGateAsExpected() throws {
        let fm = FileManager.default
        let slugs = try fm.contentsOfDirectory(atPath: corpusDir.path)
            .filter { $0.hasSuffix(".html") }
            .map { String($0.dropLast(".html".count)) }
            .sorted()
        XCTAssertFalse(slugs.isEmpty, "No fixtures found under \(corpusDir.path)")

        for slug in slugs {
            try XCTContext.runActivity(named: "fixture: \(slug)") { _ in
                let html = try String(
                    contentsOf: corpusDir.appendingPathComponent("\(slug).html"),
                    encoding: .utf8
                )
                let criteria = try JSONDecoder().decode(
                    Criteria.self,
                    from: try Data(contentsOf: corpusDir.appendingPathComponent("\(slug).expected.json"))
                )
                let baseURL = (try? String(
                    contentsOf: corpusDir.appendingPathComponent("\(slug).url"),
                    encoding: .utf8
                )).flatMap { URL(string: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }

                let result = EvalEntryPoint.extract(html: html, baseURL: baseURL)
                let verdict = ContentQualityGate.evaluate(markdown: result.markdown, html: html)

                switch criteria.expect_failure {
                case nil:
                    XCTAssertEqual(verdict, .pass, "[\(slug)] expected to pass the gate, got \(verdict)")
                case "paywalled":
                    XCTAssertEqual(verdict, .paywalled, "[\(slug)] expected .paywalled, got \(verdict)")
                case "thinContent":
                    XCTAssertEqual(verdict, .thinContent, "[\(slug)] expected .thinContent, got \(verdict)")
                case let other?:
                    XCTFail("[\(slug)] unknown expect_failure value: \(other)")
                }
            }
        }
    }
}
