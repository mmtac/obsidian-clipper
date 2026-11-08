import XCTest
@testable import ClipperExtension

final class WebContentExtractorTests: XCTestCase {

    // MARK: - detectURL

    func testDetectURLPlainHTTPS() {
        let url = WebContentExtractor.detectURL(in: "https://example.com/article")
        XCTAssertEqual(url?.absoluteString, "https://example.com/article")
    }

    func testDetectURLPlainHTTP() {
        let url = WebContentExtractor.detectURL(in: "http://example.com")
        XCTAssertEqual(url?.absoluteString, "http://example.com")
    }

    func testDetectURLEmbeddedInText() {
        let url = WebContentExtractor.detectURL(in: "Check out https://example.com/page for more")
        XCTAssertNotNil(url)
        XCTAssertEqual(url?.host, "example.com")
    }

    func testDetectURLWithWhitespace() {
        let url = WebContentExtractor.detectURL(in: "  https://example.com  ")
        XCTAssertEqual(url?.absoluteString, "https://example.com")
    }

    func testDetectURLNoURL() {
        let url = WebContentExtractor.detectURL(in: "Just some plain text")
        XCTAssertNil(url)
    }

    func testDetectURLEmptyString() {
        let url = WebContentExtractor.detectURL(in: "")
        XCTAssertNil(url)
    }

    // MARK: - detectEncoding

    func testDetectEncodingUTF8() {
        let response = makeResponse(contentType: "text/html; charset=utf-8")
        XCTAssertEqual(WebContentExtractor.detectEncoding(from: response), .utf8)
    }

    func testDetectEncodingISO88591() {
        let response = makeResponse(contentType: "text/html; charset=iso-8859-1")
        XCTAssertEqual(WebContentExtractor.detectEncoding(from: response), .isoLatin1)
    }

    func testDetectEncodingLatin1Alias() {
        let response = makeResponse(contentType: "text/html; charset=latin1")
        XCTAssertEqual(WebContentExtractor.detectEncoding(from: response), .isoLatin1)
    }

    func testDetectEncodingWindows1252() {
        let response = makeResponse(contentType: "text/html; charset=windows-1252")
        XCTAssertEqual(WebContentExtractor.detectEncoding(from: response), .windowsCP1252)
    }

    func testDetectEncodingASCII() {
        let response = makeResponse(contentType: "text/html; charset=ascii")
        XCTAssertEqual(WebContentExtractor.detectEncoding(from: response), .ascii)
    }

    func testDetectEncodingUTF16() {
        let response = makeResponse(contentType: "text/html; charset=utf-16")
        XCTAssertEqual(WebContentExtractor.detectEncoding(from: response), .utf16)
    }

    func testDetectEncodingNoCharset() {
        let response = makeResponse(contentType: "text/html")
        XCTAssertEqual(WebContentExtractor.detectEncoding(from: response), .utf8)
    }

    func testDetectEncodingNoContentType() {
        let response = makeResponse(contentType: nil)
        XCTAssertEqual(WebContentExtractor.detectEncoding(from: response), .utf8)
    }

    func testDetectEncodingUnknownCharset() {
        let response = makeResponse(contentType: "text/html; charset=some-unknown")
        XCTAssertEqual(WebContentExtractor.detectEncoding(from: response), .utf8) // falls back to utf8
    }

    // MARK: - detectEncoding (body-aware / meta tag fallback)

    func testDetectEncodingHeaderWinsOverMeta() {
        let response = makeResponse(contentType: "text/html; charset=utf-8")
        let body = #"<html><head><meta charset="iso-8859-1"></head></html>"#.data(using: .ascii)!
        XCTAssertEqual(
            WebContentExtractor.detectEncoding(response: response, body: body),
            .utf8,
            "HTTP Content-Type charset should take precedence over meta tag"
        )
    }

    func testDetectEncodingFallsBackToMetaCharset() {
        let response = makeResponse(contentType: "text/html")
        let body = #"<html><head><meta charset="iso-8859-1"><title>x</title></head></html>"#.data(using: .ascii)!
        XCTAssertEqual(
            WebContentExtractor.detectEncoding(response: response, body: body),
            .isoLatin1
        )
    }

    func testDetectEncodingFallsBackToHttpEquivMeta() {
        let response = makeResponse(contentType: "text/html")
        let body = #"<html><head><meta http-equiv="Content-Type" content="text/html; charset=windows-1252"></head></html>"#.data(using: .ascii)!
        XCTAssertEqual(
            WebContentExtractor.detectEncoding(response: response, body: body),
            .windowsCP1252
        )
    }

    func testDetectEncodingNoCharsetAnywhereDefaultsToUTF8() {
        let response = makeResponse(contentType: "text/html")
        let body = "<html><head><title>no charset</title></head></html>".data(using: .ascii)!
        XCTAssertEqual(
            WebContentExtractor.detectEncoding(response: response, body: body),
            .utf8
        )
    }

    func testDetectEncodingMetaShiftJIS() {
        let response = makeResponse(contentType: "text/html")
        let body = #"<html><head><meta charset="shift_jis"></head></html>"#.data(using: .ascii)!
        XCTAssertEqual(
            WebContentExtractor.detectEncoding(response: response, body: body),
            .shiftJIS
        )
    }

    func testDetectEncodingMetaSingleQuotes() {
        let response = makeResponse(contentType: "text/html")
        let body = "<meta charset='windows-1251'>".data(using: .ascii)!
        XCTAssertEqual(
            WebContentExtractor.detectEncoding(response: response, body: body),
            .windowsCP1251
        )
    }

    func testDetectEncodingMetaBeyondFirstKBIgnored() {
        let response = makeResponse(contentType: "text/html")
        // Pad with >1KB of whitespace before the meta tag — should NOT be found.
        let padding = String(repeating: " ", count: 1100)
        let body = ("<html>" + padding + #"<meta charset="iso-8859-1">"# + "</html>").data(using: .ascii)!
        XCTAssertEqual(
            WebContentExtractor.detectEncoding(response: response, body: body),
            .utf8,
            "Meta tags beyond the first ~1KB should not be parsed"
        )
    }

    // MARK: - isAllowedScheme (Story 3.1)

    func testAllowedSchemeHTTPS() {
        XCTAssertTrue(WebContentExtractor.isAllowedScheme(URL(string: "https://example.com")!))
    }

    func testAllowedSchemeHTTP() {
        XCTAssertTrue(WebContentExtractor.isAllowedScheme(URL(string: "http://example.com")!))
    }

    func testAllowedSchemeHTTPSUppercase() {
        XCTAssertTrue(WebContentExtractor.isAllowedScheme(URL(string: "HTTPS://example.com")!))
    }

    func testRejectedSchemeFile() {
        XCTAssertFalse(WebContentExtractor.isAllowedScheme(URL(string: "file:///etc/passwd")!))
    }

    func testRejectedSchemeJavaScript() {
        XCTAssertFalse(WebContentExtractor.isAllowedScheme(URL(string: "javascript:alert(1)")!))
    }

    func testRejectedSchemeFTP() {
        XCTAssertFalse(WebContentExtractor.isAllowedScheme(URL(string: "ftp://example.com/file")!))
    }

    func testRejectedSchemeData() {
        XCTAssertFalse(WebContentExtractor.isAllowedScheme(URL(string: "data:text/html,<h1>hi</h1>")!))
    }

    // MARK: - extractTitle

    func testExtractTitleBasic() {
        let title = WebContentExtractor.extractTitle(from: "<html><head><title>My Page</title></head></html>")
        XCTAssertEqual(title, "My Page")
    }

    func testExtractTitleWithEntities() {
        let title = WebContentExtractor.extractTitle(from: "<title>A &amp; B &lt;C&gt;</title>")
        XCTAssertEqual(title, "A & B <C>")
    }

    func testExtractTitleWithApostrophe() {
        let title = WebContentExtractor.extractTitle(from: "<title>It&#39;s a test</title>")
        XCTAssertEqual(title, "It's a test")
    }

    func testExtractTitleMissing() {
        let title = WebContentExtractor.extractTitle(from: "<html><head></head></html>")
        XCTAssertNil(title)
    }

    func testExtractTitleEmpty() {
        let title = WebContentExtractor.extractTitle(from: "<title></title>")
        XCTAssertEqual(title, "")
    }

    func testExtractTitleMultiline() {
        let title = WebContentExtractor.extractTitle(from: "<title>Line One\nLine Two</title>")
        XCTAssertEqual(title, "Line One\nLine Two")
    }

    // MARK: - Fetch retry classification

    func testRetryableStatusCodes() {
        XCTAssertTrue(WebContentExtractor.isRetryableStatus(500))
        XCTAssertTrue(WebContentExtractor.isRetryableStatus(502))
        XCTAssertTrue(WebContentExtractor.isRetryableStatus(503))
        XCTAssertTrue(WebContentExtractor.isRetryableStatus(429))
    }

    func testNonRetryableStatusCodes() {
        // 4xx (other than 429) are permanent for an unauthenticated fetcher —
        // a paywall 403 or missing page 404 won't change on retry.
        XCTAssertFalse(WebContentExtractor.isRetryableStatus(400))
        XCTAssertFalse(WebContentExtractor.isRetryableStatus(401))
        XCTAssertFalse(WebContentExtractor.isRetryableStatus(403))
        XCTAssertFalse(WebContentExtractor.isRetryableStatus(404))
        XCTAssertFalse(WebContentExtractor.isRetryableStatus(410))
    }

    func testFetchErrorDescriptions() {
        XCTAssertEqual(
            WebContentExtractor.FetchError.badStatus(403).errorDescription,
            "The page returned HTTP 403."
        )
        XCTAssertTrue(
            WebContentExtractor.FetchError.network("timed out").errorDescription?
                .contains("timed out") ?? false
        )
    }

    // MARK: - Fetch hardening (MIME, size cap, cookie redirects)

    override func tearDown() {
        WebContentExtractor.sessionOverride = nil
        WebContentExtractor.cookieStore = KeychainCookieStore.shared
        MockURLProtocol.handler = nil
        super.tearDown()
    }

    /// Thread-safe log of requests seen by the mock (the handler runs off the
    /// test's thread).
    private final class RequestLog: @unchecked Sendable {
        private let lock = NSLock()
        private var _requests: [URLRequest] = []
        func append(_ request: URLRequest) { lock.lock(); _requests.append(request); lock.unlock() }
        var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return _requests }
    }

    private func nytCookie() -> HTTPCookie {
        HTTPCookie(properties: [
            .name: "NYT-S",
            .value: "secret-session",
            .domain: ".nytimes.com",
            .path: "/",
            .secure: "TRUE",
        ])!
    }

    private func http(_ url: URL, status: Int = 200, headers: [String: String] = ["Content-Type": "text/html; charset=utf-8"]) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
    }

    private let pageHTML = "<html><head><title>T</title></head><body><p>Hello</p></body></html>"

    /// Installs a mock that redirects the first hop to `redirectTarget` and
    /// serves HTML (plus optional extra headers) from the target.
    private func installRedirect(to redirectTarget: String, targetHeaders: [String: String] = [:]) -> RequestLog {
        let log = RequestLog()
        let html = pageHTML
        MockURLProtocol.handler = { [unowned self] request in
            log.append(request)
            let url = request.url!
            if url.absoluteString == redirectTarget {
                var headers = ["Content-Type": "text/html; charset=utf-8"]
                headers.merge(targetHeaders) { _, new in new }
                return (self.http(url, headers: headers), Data(html.utf8))
            }
            return (self.http(url, status: 302, headers: ["Location": redirectTarget]), Data())
        }
        WebContentExtractor.sessionOverride = MockURLProtocol.makeSession()
        return log
    }

    func testFetchRejectsPDFMimeType() async {
        MockURLProtocol.handler = { request in
            (self.http(request.url!, headers: ["Content-Type": "application/pdf"]), Data("%PDF-1.4\n\0binary".utf8))
        }
        WebContentExtractor.sessionOverride = MockURLProtocol.makeSession()
        WebContentExtractor.cookieStore = InMemoryCookieStore()

        do {
            _ = try await WebContentExtractor.fetchHTML(from: URL(string: "https://example.com/paper.pdf")!)
            XCTFail("Expected FetchError.notHTML")
        } catch let error as WebContentExtractor.FetchError {
            guard case .notHTML(let mime) = error else { return XCTFail("Expected .notHTML, got \(error)") }
            XCTAssertEqual(mime, "application/pdf")
            XCTAssertTrue(error.localizedDescription.contains("isn't a web page"))
        } catch {
            XCTFail("Unexpected error \(error)")
        }
    }

    func testFetchAllowsMissingMimeTypeAndXHTML() async throws {
        WebContentExtractor.cookieStore = InMemoryCookieStore()
        let html = pageHTML
        MockURLProtocol.handler = { request in
            let headers: [String: String] = request.url!.path == "/xhtml"
                ? ["Content-Type": "application/xhtml+xml"] : [:]
            return (self.http(request.url!, headers: headers), Data(html.utf8))
        }
        WebContentExtractor.sessionOverride = MockURLProtocol.makeSession()

        let none = try await WebContentExtractor.fetchHTML(from: URL(string: "https://example.com/none")!)
        XCTAssertTrue(none.html.contains("Hello"))
        let xhtml = try await WebContentExtractor.fetchHTML(from: URL(string: "https://example.com/xhtml")!)
        XCTAssertTrue(xhtml.html.contains("Hello"))
    }

    func testFetchTruncatesOversizedBodyWithoutFailing() async throws {
        WebContentExtractor.cookieStore = InMemoryCookieStore()
        // 6 MB of multi-byte text so truncation lands mid-character.
        let filler = String(repeating: "é", count: 3 * 1024 * 1024)
        let body = Data(("<html><body><p>" + filler + "</p></body></html>").utf8)
        XCTAssertGreaterThan(body.count, WebContentExtractor.maxResponseBytes)
        MockURLProtocol.handler = { request in (self.http(request.url!), body) }
        WebContentExtractor.sessionOverride = MockURLProtocol.makeSession()

        let result = try await WebContentExtractor.fetchHTML(from: URL(string: "https://example.com/huge")!)
        XCTAssertLessThanOrEqual(result.html.utf8.count, WebContentExtractor.maxResponseBytes)
        XCTAssertGreaterThan(result.html.utf8.count, WebContentExtractor.maxResponseBytes - 4)
        XCTAssertTrue(result.html.hasPrefix("<html><body><p>é"))
    }

    func testTrimIncompleteUTF8Tail() {
        let full = Data("aé".utf8)                    // 61 C3 A9
        XCTAssertEqual(WebContentExtractor.trimmingIncompleteUTF8Tail(full), full)
        let cut = full.prefix(2)                       // 61 C3
        XCTAssertEqual(WebContentExtractor.trimmingIncompleteUTF8Tail(cut), Data("a".utf8))
        let emoji = Data("a😀".utf8).prefix(4)         // lead + 2 of 3 continuations
        XCTAssertEqual(WebContentExtractor.trimmingIncompleteUTF8Tail(emoji), Data("a".utf8))
    }

    func testRedirectToForeignHostDropsCookieHeader() async throws {
        WebContentExtractor.cookieStore = InMemoryCookieStore([nytCookie()])
        let log = installRedirect(to: "https://evil.example/")

        _ = try await WebContentExtractor.fetchHTML(from: URL(string: "https://www.nytimes.com/article")!)

        let requests = log.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertTrue(requests[0].value(forHTTPHeaderField: "Cookie")?.contains("NYT-S") ?? false,
                      "First-party request must carry the stored session")
        XCTAssertEqual(requests[1].url?.host, "evil.example")
        XCTAssertNil(requests[1].value(forHTTPHeaderField: "Cookie"),
                     "Stored cookies must not follow a redirect to another host")
    }

    func testSameSiteRedirectKeepsCookieHeader() async throws {
        WebContentExtractor.cookieStore = InMemoryCookieStore([nytCookie()])
        let log = installRedirect(to: "https://www.nytimes.com/2026/real-article.html")

        let result = try await WebContentExtractor.fetchHTML(from: URL(string: "https://nytimes.com/short")!)

        let requests = log.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertTrue(requests[1].value(forHTTPHeaderField: "Cookie")?.contains("NYT-S") ?? false)
        XCTAssertTrue(result.authenticated)
    }

    func testHTTPToHTTPSRedirectAttachesCookiesOnlyOnHTTPSHop() async throws {
        WebContentExtractor.cookieStore = InMemoryCookieStore([nytCookie()])
        let log = installRedirect(to: "https://www.nytimes.com/a")

        let result = try await WebContentExtractor.fetchHTML(from: URL(string: "http://www.nytimes.com/a")!)

        let requests = log.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertNil(requests[0].value(forHTTPHeaderField: "Cookie"), "Plain http must never carry stored cookies")
        XCTAssertTrue(requests[1].value(forHTTPHeaderField: "Cookie")?.contains("NYT-S") ?? false)
        XCTAssertTrue(result.authenticated)
    }

    func testHTTPURLGetsNoStoredCookies() async throws {
        let plain = HTTPCookie(properties: [.name: "NYT-S", .value: "v", .domain: ".nytimes.com", .path: "/"])!
        WebContentExtractor.cookieStore = InMemoryCookieStore([plain])
        let log = RequestLog()
        let html = pageHTML
        MockURLProtocol.handler = { request in
            log.append(request)
            return (self.http(request.url!), Data(html.utf8))
        }
        WebContentExtractor.sessionOverride = MockURLProtocol.makeSession()

        let result = try await WebContentExtractor.fetchHTML(from: URL(string: "http://www.nytimes.com/a")!)

        XCTAssertNil(log.requests.first?.value(forHTTPHeaderField: "Cookie"))
        XCTAssertFalse(result.authenticated)
    }

    func testSetCookieFromRedirectTargetIsNotMergedIntoAnotherSite() async throws {
        let store = InMemoryCookieStore([nytCookie()])
        WebContentExtractor.cookieStore = store
        // No Domain attribute: parsed against the original URL this would have
        // been planted as a www.nytimes.com cookie.
        _ = installRedirect(to: "https://evil.example/",
                            targetHeaders: ["Set-Cookie": "planted=1; Path=/"])

        _ = try await WebContentExtractor.fetchHTML(from: URL(string: "https://www.nytimes.com/article")!)

        XCTAssertFalse(store.loadAll().contains { $0.name == "planted" },
                       "Cookies set by a redirect target must not enter the store")
        XCTAssertEqual(store.loadAll().map(\.name), ["NYT-S"])
    }

    func testSetCookieRefreshFromStoredSiteIsMerged() async throws {
        let store = InMemoryCookieStore([nytCookie()])
        WebContentExtractor.cookieStore = store
        let html = pageHTML
        MockURLProtocol.handler = { request in
            (self.http(request.url!, headers: [
                "Content-Type": "text/html",
                "Set-Cookie": "NYT-S=rotated; Domain=.nytimes.com; Path=/; Secure",
            ]), Data(html.utf8))
        }
        WebContentExtractor.sessionOverride = MockURLProtocol.makeSession()

        _ = try await WebContentExtractor.fetchHTML(from: URL(string: "https://www.nytimes.com/article")!)

        XCTAssertEqual(store.loadAll().first { $0.name == "NYT-S" }?.value, "rotated")
    }

    // MARK: - Helpers

    private func makeResponse(contentType: String?) -> HTTPURLResponse {
        var headers: [String: String] = [:]
        if let ct = contentType {
            headers["Content-Type"] = ct
        }
        return HTTPURLResponse(
            url: URL(string: "https://example.com")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: headers
        )!
    }
}
