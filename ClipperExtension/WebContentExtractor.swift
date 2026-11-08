import Foundation
import UIKit
import os

/// Extracts web page content from Share Extension input items.
/// Handles URLs, HTML text, plain text, and images shared from Safari and other apps.
enum WebContentExtractor {

    /// URLSession configured with timeouts matching ImageProcessor for consistency.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForResource = 15
        config.timeoutIntervalForRequest = 10
        return URLSession(configuration: config)
    }()

    /// Test seam: when set, fetches go through this session instead of the
    /// default one (lets tests register a mock URLProtocol). Production never
    /// touches it.
    static var sessionOverride: URLSession?

    /// Site-login cookies harvested by the main app. The re-fetch path
    /// attaches these so paywalled pages return the full article instead of
    /// the anonymous shell. Swappable for tests.
    static var cookieStore: CookieStoring = KeychainCookieStore.shared

    /// Live HTML from the share sheet below this byte count is treated as
    /// missing so the (possibly authenticated) re-fetch runs instead — iOS
    /// truncating an oversized `Action.js` payload can surface as a tiny
    /// fragment. Tests set 0 to pass small inline fixtures through.
    static var minimumLiveHTMLBytes = 1024

    /// Re-fetched page bodies are truncated (not failed) at this many bytes
    /// so a huge or never-ending response can't exhaust the extension's
    /// ~120 MB memory budget.
    static let maxResponseBytes = 5 * 1024 * 1024

    /// Directly shared images beyond this count are never loaded —
    /// `ImageProcessor` only keeps the first 10 anyway.
    static let maxSharedImages = 10

    private static let log = Logger(subsystem: "com.obsidian.clipper", category: "fetch")

    struct RawContent {
        let title: String
        let url: URL?
        let html: String?
        let plainText: String?
        /// Images shared directly (e.g. from Photos, Screenshots). Not from HTML extraction.
        let sharedImages: [Data]
        /// Human-readable reason the URL re-fetch failed, when one was attempted.
        /// Lets the pipeline name the failure instead of a generic "no content".
        let fetchErrorDescription: String?
        /// True when `url` was discovered inside a larger plain-text share rather
        /// than shared explicitly (`public.url` / Safari). In that case the text
        /// itself is the payload, so a failed fetch should still save the text;
        /// for an explicitly-shared URL a failed fetch has nothing worth saving.
        let urlFromPlainText: Bool
        /// Which path produced the payload — recorded for diagnostics so
        /// failures can be traced to the capture stage after the fact.
        let captureSource: CaptureSource
    }

    /// Typed failure for the URL re-fetch path so the share UI can name the cause.
    enum FetchError: LocalizedError {
        case badStatus(Int)
        case network(String)
        case undecodable
        /// The server answered with a non-HTML MIME type (PDF, image, ...).
        case notHTML(String)

        var errorDescription: String? {
            switch self {
            case .badStatus(let code):
                return "The page returned HTTP \(code)."
            case .network(let detail):
                return "The network request failed: \(detail)"
            case .undecodable:
                return "The page content could not be decoded as text."
            case .notHTML:
                return "This link isn't a web page (it's a PDF or other file). Open it in Safari and share from there."
            }
        }
    }

    /// Retries beyond the initial attempt for transient fetch failures.
    private static let maxFetchRetries = 2

    /// HTTP statuses worth retrying: server errors and rate limiting.
    /// 4xx (other than 429) are permanent for an unauthenticated fetcher.
    static func isRetryableStatus(_ code: Int) -> Bool {
        code >= 500 || code == 429
    }

    /// Extract content from the NSExtensionContext input items.
    static func extract(from extensionContext: NSExtensionContext) async -> RawContent? {
        guard let items = extensionContext.inputItems as? [NSExtensionItem] else {
            return nil
        }

        var url: URL?
        var html: String?
        var plainText: String?
        var title: String?
        var sharedImages: [Data] = []
        var htmlSource: CaptureSource = .none

        for item in items {
            // Grab the attributed title if available
            if let attrTitle = item.attributedContentText?.string, !attrTitle.isEmpty {
                title = attrTitle
            }

            guard let attachments = item.attachments else { continue }

            for provider in attachments {
                // 1. Try to get a URL (highest priority — Safari shares the page URL)
                if provider.hasItemConformingToTypeIdentifier("public.url") {
                    if let loaded = try? await provider.loadItem(forTypeIdentifier: "public.url") as? URL {
                        url = loaded
                    }
                }

                // 2. Try to get HTML content directly
                if provider.hasItemConformingToTypeIdentifier("public.html") {
                    if let loaded = try? await provider.loadItem(forTypeIdentifier: "public.html") as? String {
                        html = loaded
                        htmlSource = .providedHTML
                    }
                }

                // 3. Try plain text as fallback
                if provider.hasItemConformingToTypeIdentifier("public.plain-text") {
                    if let loaded = try? await provider.loadItem(forTypeIdentifier: "public.plain-text") as? String {
                        plainText = loaded
                    }
                }

                // 4. Property list — the carrier Safari uses to deliver the
                //    `Action.js` preprocessing dict (NSExtensionJavaScriptPreprocessingResultsKey).
                //    The correct Apple UTI is `com.apple.property-list`; a previous
                //    `public.property-list` string here matched nothing on real iOS
                //    (no public counterpart is declared) so html stayed nil and
                //    every Safari clip wrote a frontmatter-only file.
                if provider.hasItemConformingToTypeIdentifier("com.apple.property-list") {
                    if let dict = try? await provider.loadItem(forTypeIdentifier: "com.apple.property-list") as? [String: Any] {
                        if let results = dict[NSExtensionJavaScriptPreprocessingResultsKey] as? [String: Any] {
                            if let pageTitle = results["title"] as? String {
                                title = pageTitle
                            }
                            if let pageURL = results["URL"] as? String {
                                url = URL(string: pageURL)
                            }
                            if let pageHTML = results["html"] as? String {
                                html = pageHTML
                                htmlSource = .jsPreprocessing
                            }
                        }
                    }
                }

                // 5. Try to get images shared directly (Photos, Screenshots, etc.).
                //    Stop loading once the cap is reached — each one is a full
                //    photo held in memory.
                if sharedImages.count < maxSharedImages,
                   provider.hasItemConformingToTypeIdentifier("public.image") {
                    if let imageData = await loadImageData(from: provider) {
                        sharedImages.append(imageData)
                    }
                }
            }
        }

        // If plain text looks like a URL and we don't already have one, treat it as a URL.
        // Record this provenance: a URL merely detected inside text means the text is the
        // primary payload, so a failed fetch should fall back to saving the text.
        var urlFromPlainText = false
        if url == nil, let text = plainText {
            if let detected = detectURL(in: text) {
                url = detected
                urlFromPlainText = true
            }
        }

        // Live HTML that is suspiciously tiny is treated as missing when we
        // have a URL to re-fetch — a truncated Action.js payload otherwise
        // produces a title-only note with no error.
        if let liveHTML = html, url != nil, liveHTML.utf8.count < minimumLiveHTMLBytes {
            log.notice("live html too small (\(liveHTML.utf8.count) bytes, source=\(htmlSource.rawValue, privacy: .public)); discarding for re-fetch")
            html = nil
            htmlSource = .none
        }

        // If we have a URL but no HTML, fetch the page content
        var fetchErrorDescription: String?
        if html == nil, let pageURL = url {
            do {
                let fetched = try await fetchHTML(from: pageURL)
                html = fetched.html
                htmlSource = fetched.authenticated ? .refetchAuthenticated : .refetchAnonymous
                log.notice("re-fetched \(pageURL.absoluteString, privacy: .private) (\(htmlSource.rawValue, privacy: .public), \(fetched.html.count) chars)")
            } catch is CancellationError {
                return nil
            } catch {
                fetchErrorDescription = error.localizedDescription
                log.error("fetchHTML FAILED for \(pageURL.absoluteString, privacy: .private): \(error.localizedDescription, privacy: .public)")
            }
        }

        // Derive title from HTML <title> tag if not already set
        if title == nil || title!.isEmpty {
            if let h = html {
                title = extractTitle(from: h)
            }
        }

        // Final fallback for title
        if title == nil || title!.isEmpty {
            if !sharedImages.isEmpty {
                let formatter = DateFormatter()
                formatter.dateFormat = "yyyy-MM-dd HH.mm"
                title = "Clipped Image \u{2014} \(formatter.string(from: Date()))"
            } else {
                title = url?.host ?? "Untitled"
            }
        }

        let captureSource: CaptureSource
        if html != nil {
            captureSource = htmlSource
        } else if !sharedImages.isEmpty && url == nil {
            captureSource = .image
        } else if plainText != nil {
            captureSource = .plainText
        } else {
            captureSource = .none
        }

        return RawContent(
            title: title!,
            url: url,
            html: html,
            plainText: plainText,
            sharedImages: sharedImages,
            fetchErrorDescription: fetchErrorDescription,
            urlFromPlainText: urlFromPlainText,
            captureSource: captureSource
        )
    }

    /// Detect a URL in plain text. Many apps (Twitter, Reddit, Messages) share URLs as plain text.
    static func detectURL(in text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Quick check: if the entire text is a URL
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
            if let url = URL(string: trimmed), url.host != nil {
                return url
            }
        }
        // Try to find a URL anywhere in the text using NSDataDetector
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return nil
        }
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        if let match = detector.firstMatch(in: trimmed, range: range),
           let url = match.url,
           let scheme = url.scheme,
           ["http", "https"].contains(scheme.lowercased()) {
            return url
        }
        return nil
    }

    /// Load image data from an NSItemProvider. Prefers the provider's own
    /// encoded bytes (Data or a local file URL); a bare UIImage is re-encoded
    /// as JPEG, which is far smaller than PNG for photos.
    private static func loadImageData(from provider: NSItemProvider) async -> Data? {
        guard let item = try? await provider.loadItem(forTypeIdentifier: "public.image") else {
            return nil
        }
        if let imageData = item as? Data {
            return imageData
        }
        // Only local files: Data(contentsOf:) on a remote URL would block on
        // the network synchronously.
        if let imageURL = item as? URL, imageURL.isFileURL {
            return try? Data(contentsOf: imageURL, options: .mappedIfSafe)
        }
        if let image = item as? UIImage {
            return image.jpegData(compressionQuality: 0.9)
        }
        return nil
    }

    /// Fetch HTML from a URL, detecting character encoding from the Content-Type header or HTML meta tags.
    /// Rejects non-HTTP(S) schemes (file://, javascript:, ftp://, data:, etc.).
    /// Transient failures (timeout, connection reset, 5xx, 429) are retried up to
    /// `maxFetchRetries` times with jittered exponential backoff; permanent
    /// failures (other 4xx, non-HTML MIME type) throw immediately. Bodies are
    /// streamed and truncated at `maxResponseBytes`.
    static func fetchHTML(from url: URL) async throws -> (html: String, authenticated: Bool) {
        guard isAllowedScheme(url) else {
            throw FetchError.network("Unsupported URL scheme.")
        }

        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue(
            "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            forHTTPHeaderField: "Accept"
        )
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")

        // Attach site-login cookies harvested by the main app, so paywalled
        // pages (NYT etc.) serve the full article. Cookie handling is manual
        // here: the extension's own cookie jar must not overwrite the stored
        // session, and Set-Cookie refreshes are merged back explicitly below.
        // URLSession carries custom headers across redirects, so the redirect
        // delegate re-derives the Cookie header for every hop.
        let storedCookies = cookieStore.cookies(for: url)
        if !storedCookies.isEmpty {
            request.httpShouldHandleCookies = false
            if let cookieHeader = HTTPCookie.requestHeaderFields(with: storedCookies)["Cookie"] {
                request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
            }
        }

        var lastError: FetchError = .network("Unknown error.")

        for attempt in 0...maxFetchRetries {
            if attempt > 0 {
                // Jittered exponential backoff: ~0.5s, then ~1s, +0–50% jitter.
                let base = 0.5 * pow(2.0, Double(attempt - 1))
                let delay = base * (1.0 + Double.random(in: 0...0.5))
                try await Task.sleep(for: .seconds(delay))
            }
            try Task.checkCancellation()

            let redirectDelegate = CookieRedirectDelegate(cookieStore: cookieStore)
            let bytes: URLSession.AsyncBytes
            let response: URLResponse
            do {
                (bytes, response) = try await (sessionOverride ?? session).bytes(for: request, delegate: redirectDelegate)
            } catch {
                if (error as? URLError)?.code == .cancelled || error is CancellationError {
                    throw CancellationError()
                }
                lastError = .network(error.localizedDescription)
                log.error("attempt \(attempt + 1)/\(maxFetchRetries + 1) failed: \(error.localizedDescription, privacy: .public)")
                continue
            }

            guard let httpResponse = response as? HTTPURLResponse else {
                bytes.task.cancel()
                lastError = .network("Invalid response from server.")
                continue
            }
            guard (200...299).contains(httpResponse.statusCode) else {
                bytes.task.cancel()
                lastError = .badStatus(httpResponse.statusCode)
                log.error("attempt \(attempt + 1)/\(maxFetchRetries + 1) HTTP \(httpResponse.statusCode)")
                if isRetryableStatus(httpResponse.statusCode) { continue }
                throw lastError
            }

            let authenticated = !storedCookies.isEmpty || redirectDelegate.attachedCookies

            // Persist any refreshed session cookies so a rotating login
            // (NYT rotates NYT-S periodically) stays valid between clips.
            if authenticated {
                mergeRefreshedCookies(from: httpResponse, requestURL: httpResponse.url ?? url, into: cookieStore)
            }

            // Reject PDFs, images, downloads etc. before reading the body —
            // they would otherwise be decoded (e.g. as Latin-1) into garbage.
            if let mime = mimeType(of: httpResponse), !isHTMLMimeType(mime) {
                bytes.task.cancel()
                log.error("non-HTML response (\(mime, privacy: .public)) for \(url.absoluteString, privacy: .private)")
                throw FetchError.notHTML(mime)
            }

            var data = Data()
            var truncated = false
            do {
                data.reserveCapacity(min(Int(max(httpResponse.expectedContentLength, 0)), maxResponseBytes))
                for try await byte in bytes {
                    if data.count >= maxResponseBytes {
                        truncated = true
                        break
                    }
                    data.append(byte)
                }
            } catch {
                if (error as? URLError)?.code == .cancelled || error is CancellationError || Task.isCancelled {
                    throw CancellationError()
                }
                lastError = .network(error.localizedDescription)
                log.error("attempt \(attempt + 1)/\(maxFetchRetries + 1) body read failed: \(error.localizedDescription, privacy: .public)")
                continue
            }
            if truncated {
                bytes.task.cancel()
                log.notice("response truncated at \(maxResponseBytes) bytes for \(url.absoluteString, privacy: .private)")
            }

            let encoding = Self.detectEncoding(response: httpResponse, body: data)
            if truncated, encoding == .utf8 {
                data = trimmingIncompleteUTF8Tail(data)
            }
            // A body without a MIME type that is actually binary must never
            // reach the parser (Latin-1 decodes any byte sequence).
            if encoding != .utf16, looksBinary(data) {
                throw FetchError.notHTML("application/octet-stream")
            }
            if let html = String(data: data, encoding: encoding) ?? String(data: data, encoding: .utf8) {
                return (html, authenticated)
            }
            throw FetchError.undecodable
        }

        throw lastError
    }

    /// Lowercased MIME type from the Content-Type header (nil when absent).
    private static func mimeType(of response: HTTPURLResponse) -> String? {
        guard let contentType = response.value(forHTTPHeaderField: "Content-Type") else { return nil }
        let mime = contentType.split(separator: ";", maxSplits: 1).first
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
        return mime.isEmpty ? nil : mime
    }

    static func isHTMLMimeType(_ mime: String) -> Bool {
        mime == "text/html" || mime == "application/xhtml+xml"
    }

    /// NUL bytes in the first KB are a reliable binary tell for 8-bit and
    /// UTF-8 text encodings.
    private static func looksBinary(_ data: Data) -> Bool {
        data.prefix(1024).contains(0)
    }

    /// Drop a multi-byte UTF-8 sequence cut off by truncation so strict
    /// decoding doesn't reject the whole document.
    static func trimmingIncompleteUTF8Tail(_ data: Data) -> Data {
        let bytes = [UInt8](data.suffix(4))
        guard !bytes.isEmpty else { return data }
        // Find the last non-continuation byte.
        var index = bytes.count - 1
        while index > 0 && bytes[index] & 0xC0 == 0x80 { index -= 1 }
        let lead = bytes[index]
        let needed: Int
        switch lead {
        case 0x00..<0x80: needed = 1
        case 0xC0..<0xE0: needed = 2
        case 0xE0..<0xF0: needed = 3
        case 0xF0..<0xF8: needed = 4
        default: return data
        }
        let available = bytes.count - index
        if available < needed {
            return data.prefix(data.count - available)
        }
        return data
    }

    /// Merge Set-Cookie refreshes from `response`, parsed against the URL that
    /// actually served it, keeping only cookies for sites already in the store
    /// (a redirect to another host can't plant cookies for it).
    fileprivate static func mergeRefreshedCookies(from response: HTTPURLResponse, requestURL: URL, into store: CookieStoring) {
        let headerFields = (response.allHeaderFields as? [String: String]) ?? [:]
        let parsed = HTTPCookie.cookies(withResponseHeaderFields: headerFields, for: requestURL)
        let refreshed = SiteCookies.restrictedToStoredSites(parsed, stored: store.loadAll())
        if !refreshed.isEmpty {
            store.merge(refreshed)
        }
    }

    /// Returns true if the URL uses a scheme safe for network fetching (http/https only).
    static func isAllowedScheme(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    /// Detect string encoding from HTTP Content-Type header charset.
    /// Retained for backward compatibility; delegates to the body-aware variant with an empty body.
    static func detectEncoding(from response: HTTPURLResponse) -> String.Encoding {
        return detectEncoding(response: response, body: Data())
    }

    /// Detect string encoding, preferring HTTP Content-Type charset, then HTML `<meta>` tags in the body.
    static func detectEncoding(response: HTTPURLResponse, body: Data) -> String.Encoding {
        if let contentType = response.value(forHTTPHeaderField: "Content-Type"),
           let charset = parseCharset(fromContentType: contentType) {
            return encoding(forCharset: charset)
        }

        if let metaCharset = parseCharset(fromHTMLBody: body) {
            return encoding(forCharset: metaCharset)
        }

        return .utf8
    }

    /// Parse the charset value from an HTTP Content-Type header value.
    private static func parseCharset(fromContentType contentType: String) -> String? {
        let lower = contentType.lowercased()
        guard let charsetRange = lower.range(of: "charset=") else {
            return nil
        }
        var charsetValue = String(lower[charsetRange.upperBound...])
        if let semicolonIndex = charsetValue.firstIndex(of: ";") {
            charsetValue = String(charsetValue[..<semicolonIndex])
        }
        charsetValue = charsetValue.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "'", with: "")
        return charsetValue.isEmpty ? nil : charsetValue
    }

    /// Parse the charset from the first ~1KB of an HTML document, looking at `<meta>` tags.
    /// Supports both `<meta http-equiv="Content-Type" content="...; charset=...">` and `<meta charset="...">`.
    private static func parseCharset(fromHTMLBody body: Data) -> String? {
        guard !body.isEmpty else { return nil }
        let prefix = body.prefix(1024)
        guard let head = String(data: prefix, encoding: .ascii)
                ?? String(data: prefix, encoding: .isoLatin1) else {
            return nil
        }

        let pattern = #"<meta[^>]+charset\s*=\s*["']?([^"'>\s;]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(head.startIndex..., in: head)
        guard let match = regex.firstMatch(in: head, range: range),
              match.numberOfRanges > 1,
              let charsetRange = Range(match.range(at: 1), in: head) else {
            return nil
        }
        return String(head[charsetRange]).lowercased()
    }

    /// Map a charset string (lowercased) to a `String.Encoding`, falling back to UTF-8 for unknown values.
    private static func encoding(forCharset charset: String) -> String.Encoding {
        switch charset {
        case "utf-8", "utf8":
            return .utf8
        case "iso-8859-1", "latin1", "latin-1":
            return .isoLatin1
        case "iso-8859-2", "latin2", "latin-2":
            return .isoLatin2
        case "iso-8859-15", "latin-9", "latin9":
            return isoLatin15Encoding()
        case "windows-1252", "cp1252":
            return .windowsCP1252
        case "windows-1251", "cp1251":
            return .windowsCP1251
        case "ascii", "us-ascii":
            return .ascii
        case "utf-16":
            return .utf16
        case "shift_jis", "shift-jis", "sjis":
            return .shiftJIS
        case "euc-jp", "eucjp":
            return .japaneseEUC
        default:
            return .utf8
        }
    }

    /// ISO-8859-15 (Latin-9) via CoreFoundation bridging; falls back to UTF-8 if unavailable.
    private static func isoLatin15Encoding() -> String.Encoding {
        let cfEncoding = CFStringEncoding(CFStringEncodings.isoLatin9.rawValue)
        let nsEncoding = CFStringConvertEncodingToNSStringEncoding(cfEncoding)
        if nsEncoding == UInt(kCFStringEncodingInvalidId) { return .utf8 }
        return String.Encoding(rawValue: nsEncoding)
    }

    /// Extract the <title> content from HTML.
    static func extractTitle(from html: String) -> String? {
        let pattern = #"<title[^>]*>(.*?)</title>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]),
              let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: html) else {
            return nil
        }
        let raw = String(html[range])
        // Decode basic HTML entities
        return raw
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Per-task delegate for the page re-fetch. URLSession copies custom headers
/// (including a manually set Cookie) onto every redirect hop, which would leak
/// a site-login session to whatever host the page redirects to. Each hop's
/// Cookie header is therefore rebuilt from the store for the new URL only.
private final class CookieRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {

    private let cookieStore: CookieStoring
    private let lock = NSLock()
    private var _attachedCookies = false

    /// True when a redirect hop received stored cookies (e.g. http -> https).
    var attachedCookies: Bool {
        lock.lock(); defer { lock.unlock() }
        return _attachedCookies
    }

    init(cookieStore: CookieStoring) {
        self.cookieStore = cookieStore
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        // Refreshes delivered on an authenticated redirect hop still count.
        if task.currentRequest?.value(forHTTPHeaderField: "Cookie") != nil,
           let hopURL = response.url ?? task.currentRequest?.url {
            WebContentExtractor.mergeRefreshedCookies(from: response, requestURL: hopURL, into: cookieStore)
        }

        var redirected = request
        redirected.setValue(nil, forHTTPHeaderField: "Cookie")
        if let newURL = redirected.url {
            let cookies = cookieStore.cookies(for: newURL)
            if !cookies.isEmpty,
               let header = HTTPCookie.requestHeaderFields(with: cookies)["Cookie"] {
                redirected.httpShouldHandleCookies = false
                redirected.setValue(header, forHTTPHeaderField: "Cookie")
                lock.lock(); _attachedCookies = true; lock.unlock()
            }
        }
        completionHandler(redirected)
    }
}
