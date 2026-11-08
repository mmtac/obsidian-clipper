import Foundation

/// URLProtocol stub so tests can drive `WebContentExtractor`'s fetch path
/// without touching the network. Install with:
///
///     WebContentExtractor.sessionOverride = MockURLProtocol.makeSession()
///     MockURLProtocol.handler = { request in ... }
///
/// and reset both in `tearDown`.
final class MockURLProtocol: URLProtocol {

    /// Answers each intercepted request. Throwing simulates a transport error.
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    /// A session whose every request is routed through this protocol.
    static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }

    /// A session that refuses every connection — the hermetic stand-in for
    /// "no network" so tests never make real fetches.
    static func makeRefusingSession() -> URLSession {
        handler = nil
        return makeSession()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = MockURLProtocol.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        do {
            let (response, data) = try handler(request)
            // A 3xx with a Location header is surfaced as a redirect, the way
            // URLSession does: the follow-up request carries the original
            // request's headers (incl. any manual Cookie) so the session's
            // redirect delegate is exercised exactly as in production.
            if (300...399).contains(response.statusCode),
               let location = response.value(forHTTPHeaderField: "Location"),
               let target = URL(string: location, relativeTo: request.url)?.absoluteURL {
                var redirected = request
                redirected.url = target
                client?.urlProtocol(self, wasRedirectedTo: redirected, redirectResponse: response)
                client?.urlProtocolDidFinishLoading(self)
                return
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

/// In-memory `CookieStoring` so tests never touch the Keychain.
final class InMemoryCookieStore: CookieStoring, @unchecked Sendable {

    private var cookies: [HTTPCookie] = []
    private let lock = NSLock()

    init(_ initial: [HTTPCookie] = []) {
        cookies = initial
    }

    func loadAll() -> [HTTPCookie] {
        lock.lock(); defer { lock.unlock() }
        return cookies
    }

    func saveAll(_ new: [HTTPCookie]) {
        lock.lock(); defer { lock.unlock() }
        cookies = new
    }
}
