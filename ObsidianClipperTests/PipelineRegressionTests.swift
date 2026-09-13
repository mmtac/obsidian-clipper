import XCTest
@testable import ClipperExtension

/// Regression suite that drives the full extraction pipeline through
/// `EvalEntryPoint.extract` for every fixture in
/// `Tests/Fixtures/extraction-corpus/` and FAILS on any per-fixture criterion
/// that does not pass.
///
/// Distinct from `ExtractionEvalTests`, which is intentionally non-failing
/// (eval-only). This suite is the regression net: any change that breaks the
/// JSON-LD fast path, Readability, or HTML-to-Markdown converter on the corpus
/// breaks CI.
///
/// Fixtures simulate clipping a representative cross-section of real-world
/// pages: long-form articles, feed-style indexes (Hacker News, Daring
/// Fireball), heavy front pages (The Verge), and the canonical baseline
/// (example.com). Each fixture has a sibling `.expected.json` describing the
/// criteria it must meet.
final class PipelineRegressionTests: XCTestCase {

    // MARK: - Criteria

    private struct ExpectedCriteria: Decodable {
        let title_contains: String?
        let must_contain: [String]
        let must_not_contain: [String]
        let min_body_chars: Int
        let max_total_images: Int?
        let min_total_images: Int?
        /// When set ("paywalled" | "thinContent"), the fixture is a failed
        /// capture (e.g. an anonymous paywall shell): the quality gate must
        /// reject it with the named verdict and no other criteria apply.
        let expect_failure: String?
    }

    // MARK: - Paths

    /// Repo root, derived from `#filePath`. Test file lives at
    /// `<repo>/ObsidianClipperTests/PipelineRegressionTests.swift`.
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private var corpusDir: URL {
        repoRoot.appendingPathComponent("Tests/Fixtures/extraction-corpus", isDirectory: true)
    }

    // MARK: - Tests

    /// One assertion per fixture. Each fixture is wrapped in
    /// `XCTContext.runActivity` so failures in Xcode are grouped under the
    /// fixture slug; assertion failures within a fixture are accumulated, not
    /// fast-failed, so a single broken fixture does not mask others.
    func testCorpusFixturesMeetExtractionCriteria() throws {
        let fixtures = try discoverFixtures()
        XCTAssertFalse(
            fixtures.isEmpty,
            "No fixtures found under \(corpusDir.path). Cannot run regression suite."
        )

        for slug in fixtures {
            XCTContext.runActivity(named: "fixture: \(slug)") { _ in
                do {
                    try assertFixture(slug: slug)
                } catch {
                    XCTFail("[\(slug)] threw error: \(error)")
                }
            }
        }
    }

    // MARK: - Per-fixture assertions

    private func assertFixture(slug: String) throws {
        let htmlURL = corpusDir.appendingPathComponent("\(slug).html")
        let expectedURL = corpusDir.appendingPathComponent("\(slug).expected.json")
        let urlURL = corpusDir.appendingPathComponent("\(slug).url")

        let html = try String(contentsOf: htmlURL, encoding: .utf8)
        let expected = try JSONDecoder().decode(
            ExpectedCriteria.self,
            from: try Data(contentsOf: expectedURL)
        )
        let baseURLString = (try? String(contentsOf: urlURL, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let baseURL = baseURLString.flatMap { URL(string: $0) }

        let result = EvalEntryPoint.extract(html: html, baseURL: baseURL)

        // Expected-failure fixtures (paywall shells) assert only the gate
        // verdict: the pipeline must refuse to save them.
        if let expectedFailure = expected.expect_failure {
            let verdict = ContentQualityGate.evaluate(markdown: result.markdown, html: html)
            switch expectedFailure {
            case "paywalled":
                XCTAssertEqual(verdict, .paywalled, "[\(slug)] expected gate verdict .paywalled, got \(verdict)")
            case "thinContent":
                XCTAssertEqual(verdict, .thinContent, "[\(slug)] expected gate verdict .thinContent, got \(verdict)")
            default:
                XCTFail("[\(slug)] unknown expect_failure value: \(expectedFailure)")
            }
            return
        }

        // Title
        if let needle = expected.title_contains {
            XCTAssertTrue(
                result.title.localizedCaseInsensitiveContains(needle),
                "[\(slug)] title=\"\(result.title)\" does not contain \"\(needle)\""
            )
        }

        // Must-contain needles
        for needle in expected.must_contain {
            XCTAssertTrue(
                result.markdown.contains(needle),
                "[\(slug)] markdown is missing required substring: \"\(needle)\""
            )
        }

        // Must-not-contain needles (typically nav/recirc bleed-through)
        for needle in expected.must_not_contain {
            XCTAssertFalse(
                result.markdown.contains(needle),
                "[\(slug)] markdown contains forbidden substring: \"\(needle)\""
            )
        }

        // Body length
        let bodyChars = result.markdown.filter { !$0.isWhitespace }.count
        XCTAssertGreaterThanOrEqual(
            bodyChars,
            expected.min_body_chars,
            "[\(slug)] body too short: \(bodyChars) < \(expected.min_body_chars) non-whitespace chars"
        )

        // Image-marker cap
        if let cap = expected.max_total_images, let got = result.imageMarkerCount {
            XCTAssertLessThanOrEqual(
                got,
                cap,
                "[\(slug)] image marker count \(got) exceeds cap \(cap)"
            )
        }

        // Image-marker floor — protects against silent regressions like
        // the JSON-LD plain-text-body case where Wired clips dropped to
        // zero inline images.
        if let floor = expected.min_total_images, let got = result.imageMarkerCount {
            XCTAssertGreaterThanOrEqual(
                got,
                floor,
                "[\(slug)] image marker count \(got) below floor \(floor)"
            )
        }

        // Structural sanity — converter regressions leave raw HTML behind.
        // Use a substring set that is unambiguous (`<p>` is never legal in
        // markdown output of this converter; same for `<div>`/`<script`/`<style`).
        let forbiddenSubstrings = ["<p>", "<div>", "<script", "<style"]
        for tag in forbiddenSubstrings {
            XCTAssertFalse(
                result.markdown.contains(tag),
                "[\(slug)] markdown contains leftover HTML: \"\(tag)\""
            )
        }

        // Approach must be a known value. Prevents silent regressions where a
        // future branch forgets to set `approach`.
        XCTAssertFalse(
            result.approach.isEmpty,
            "[\(slug)] approach is empty"
        )
    }

    // MARK: - Discovery

    private func discoverFixtures() throws -> [String] {
        let fm = FileManager.default
        let contents = try fm.contentsOfDirectory(atPath: corpusDir.path)
        return contents
            .filter { $0.hasSuffix(".html") }
            .map { String($0.dropLast(".html".count)) }
            .sorted()
    }
}
