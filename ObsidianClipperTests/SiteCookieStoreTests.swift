import XCTest
@testable import ClipperExtension

/// Unit tests for the cookie-store helpers: serialization round-trips,
/// RFC 6265 domain matching, expiry pruning, and merge semantics. Uses the
/// in-memory fake — the Keychain implementation shares all this logic via
/// the `CookieStoring` protocol extension.
final class SiteCookieStoreTests: XCTestCase {

    private func cookie(
        name: String = "NYT-S",
        value: String = "session-token",
        domain: String = ".nytimes.com",
        path: String = "/",
        secure: Bool = false,
        expires: Date? = nil
    ) -> HTTPCookie {
        var properties: [HTTPCookiePropertyKey: Any] = [
            .name: name,
            .value: value,
            .domain: domain,
            .path: path,
        ]
        if secure {
            properties[.secure] = "TRUE"
        }
        if let expires {
            properties[.expires] = expires
        }
        return HTTPCookie(properties: properties)!
    }

    // MARK: - Domain matching

    func testBareDomainCookieMatchesSubdomain() {
        XCTAssertTrue(SiteCookies.domainMatches(cookieDomain: ".nytimes.com", host: "www.nytimes.com"))
        XCTAssertTrue(SiteCookies.domainMatches(cookieDomain: "nytimes.com", host: "www.nytimes.com"))
        XCTAssertTrue(SiteCookies.domainMatches(cookieDomain: ".nytimes.com", host: "nytimes.com"))
    }

    func testUnrelatedDomainDoesNotMatch() {
        XCTAssertFalse(SiteCookies.domainMatches(cookieDomain: ".nytimes.com", host: "notnytimes.com"))
        XCTAssertFalse(SiteCookies.domainMatches(cookieDomain: ".nytimes.com", host: "example.com"))
    }

    // MARK: - Applicability

    func testCookiesForURLFiltersByDomain() {
        let store = InMemoryCookieStore([
            cookie(domain: ".nytimes.com"),
            cookie(name: "other", domain: ".wired.com"),
        ])
        let matches = store.cookies(for: URL(string: "https://www.nytimes.com/2026/01/01/article.html")!)
        XCTAssertEqual(matches.map(\.name), ["NYT-S"])
    }

    func testSecureCookieExcludedFromHTTPFetch() {
        let store = InMemoryCookieStore([cookie(secure: true)])
        XCTAssertTrue(store.cookies(for: URL(string: "http://www.nytimes.com/")!).isEmpty)
        XCTAssertEqual(store.cookies(for: URL(string: "https://www.nytimes.com/")!).count, 1)
    }

    func testExpiredCookiePruned() {
        let store = InMemoryCookieStore([
            cookie(expires: Date(timeIntervalSinceNow: -3600)),
            cookie(name: "fresh", expires: Date(timeIntervalSinceNow: 3600)),
        ])
        let matches = store.cookies(for: URL(string: "https://www.nytimes.com/")!)
        XCTAssertEqual(matches.map(\.name), ["fresh"])
    }

    func testSessionCookieWithoutExpiryIsKept() {
        let store = InMemoryCookieStore([cookie()])
        XCTAssertEqual(store.cookies(for: URL(string: "https://www.nytimes.com/")!).count, 1)
    }

    // MARK: - Merge

    func testMergeReplacesSameDomainNamePath() {
        let store = InMemoryCookieStore([cookie(value: "old")])
        store.merge([cookie(value: "new")])
        let all = store.loadAll()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.value, "new")
    }

    func testMergeKeepsDistinctCookies() {
        let store = InMemoryCookieStore([cookie()])
        store.merge([cookie(name: "nyt-a", value: "x")])
        XCTAssertEqual(store.loadAll().count, 2)
    }

    // MARK: - Removal + summary

    func testRemoveCookiesByDomainSuffix() {
        let store = InMemoryCookieStore([
            cookie(),
            cookie(name: "other", domain: ".wired.com"),
        ])
        store.removeCookies(domainSuffix: "nytimes.com")
        XCTAssertEqual(store.loadAll().map(\.name), ["other"])
    }

    func testSummaryCountsAndEarliestExpiry() {
        let sooner = Date(timeIntervalSinceNow: 3600)
        let later = Date(timeIntervalSinceNow: 7200)
        let store = InMemoryCookieStore([
            cookie(expires: later),
            cookie(name: "nyt-a", expires: sooner),
            cookie(name: "other", domain: ".wired.com"),
        ])
        let summary = store.summary(forDomainSuffix: "nytimes.com")
        XCTAssertEqual(summary.count, 2)
        // HTTPCookie truncates expiry sub-second precision; compare loosely.
        XCTAssertEqual(
            try XCTUnwrap(summary.earliestExpiry).timeIntervalSince1970,
            sooner.timeIntervalSince1970,
            accuracy: 1.0
        )
    }

    // MARK: - Serialization round-trip

    func testSerializeDeserializeRoundTrip() throws {
        let expires = Date(timeIntervalSinceNow: 86_400)
        let original = [
            cookie(expires: expires),
            cookie(name: "nyt-a", value: "abc", domain: "www.nytimes.com", path: "/2026", secure: true),
        ]
        let data = try XCTUnwrap(SiteCookies.serialize(original))
        let restored = SiteCookies.deserialize(data)
        XCTAssertEqual(restored.count, 2)

        let bySName = Dictionary(uniqueKeysWithValues: restored.map { ($0.name, $0) })
        XCTAssertEqual(bySName["NYT-S"]?.value, "session-token")
        XCTAssertEqual(bySName["NYT-S"]?.domain, ".nytimes.com")
        XCTAssertNotNil(bySName["NYT-S"]?.expiresDate)
        XCTAssertEqual(bySName["nyt-a"]?.path, "/2026")
        XCTAssertEqual(bySName["nyt-a"]?.isSecure, true)
    }
}
