import Foundation
import os

/// Which path produced the payload that fed the clipping pipeline.
/// Recorded per clip so "why was this note empty?" is answerable after the
/// fact — the single biggest diagnostic gap behind title-only notes was not
/// knowing whether the HTML came from the live Safari DOM or an anonymous
/// re-fetch of the URL.
enum CaptureSource: String, Codable, Sendable {
    /// Safari ran `Action.js` and handed us the live (possibly authenticated) DOM.
    case jsPreprocessing
    /// The host app shared HTML directly (`public.html`).
    case providedHTML
    /// We re-fetched the URL ourselves with no stored site-login cookies.
    case refetchAnonymous
    /// We re-fetched the URL with cookies from the in-app Site Logins store.
    case refetchAuthenticated
    /// Plain text was the payload (no HTML anywhere).
    case plainText
    /// Images shared directly (Photos, screenshots).
    case image
    /// Nothing usable arrived.
    case none
}

/// One per-clip diagnostic record. Persisted as a small JSON ring buffer in
/// the App Group container so the main app's Settings screen can show the
/// last few clips for field debugging. Contains hostnames and lengths only —
/// never page content or cookies.
struct ClipRecord: Codable, Identifiable, Sendable {
    var id: Date { date }
    let date: Date
    let host: String?
    let source: CaptureSource
    /// Character count of the HTML fed to extraction, if any.
    let htmlChars: Int?
    /// Extraction route taken: "jsonld", "readability", "fullPage", "plainText", "imageOnly".
    let route: String
    /// Non-whitespace character count of the final markdown body.
    let markdownChars: Int
    /// "saved", "paywalled", "thinContent", "fetchFailed", "noContent".
    let outcome: String
    let elapsedMs: Int
}

enum ClipDiagnostics {

    static let logger = Logger(subsystem: "com.obsidian.clipper", category: "pipeline")

    /// Number of records kept in the ring buffer.
    private static let capacity = 20

    private static var storeURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: ClipperSettings.suiteName)?
            .appendingPathComponent("clip_diagnostics.json")
    }

    /// Append a record, trimming to the last `capacity` entries. Failures are
    /// swallowed — diagnostics must never break a clip.
    static func record(_ record: ClipRecord) {
        logger.notice("clip source=\(record.source.rawValue, privacy: .public) host=\(record.host ?? "-", privacy: .public) route=\(record.route, privacy: .public) htmlChars=\(record.htmlChars ?? 0) mdChars=\(record.markdownChars) outcome=\(record.outcome, privacy: .public) elapsedMs=\(record.elapsedMs)")
        guard let url = storeURL else { return }
        var records = recent()
        records.append(record)
        if records.count > capacity {
            records.removeFirst(records.count - capacity)
        }
        if let data = try? JSONEncoder().encode(records) {
            try? data.write(to: url, options: .atomic)
        }
    }

    /// The persisted records, oldest first. Empty when the App Group
    /// container is unavailable or nothing has been recorded yet.
    static func recent() -> [ClipRecord] {
        guard let url = storeURL,
              let data = try? Data(contentsOf: url),
              let records = try? JSONDecoder().decode([ClipRecord].self, from: data) else {
            return []
        }
        return records
    }
}
