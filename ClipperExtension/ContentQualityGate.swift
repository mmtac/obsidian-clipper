import Foundation

/// Decides whether an extracted markdown body is worth saving. A URL-backed
/// clip that produced almost nothing is a failed capture (paywall shell,
/// login wall, consent interstitial) — the pipeline surfaces a named error
/// instead of silently writing a title-only stub note.
///
/// Callers exempt image-only clips, plain-text-primary clips, and clips with
/// no URL before invoking the gate.
enum ContentQualityGate {

    enum Verdict: Equatable {
        case pass
        /// The page shows paywall/login-wall markers and the body is thin.
        case paywalled
        /// No paywall markers, but the body is too thin to be a real capture.
        case thinContent
    }

    /// Bodies below this non-whitespace character count are failed captures.
    /// Matches the corpus floor (`min_body_chars: 100` on example.com, which
    /// extracts to 119 chars) so legitimately tiny pages still save.
    static let thinThreshold = 100

    /// A body at or above this length is always a pass, even when paywall
    /// markers are present — authenticated NYT/Wired pages legitimately carry
    /// `isAccessibleForFree: false` in their JSON-LD while serving the full
    /// article.
    static let paywallSafeThreshold = 1000

    /// Substrings that identify a paywall or login shell. Matched against
    /// lowercased HTML. `gateway-content` is NYT's paywall container id.
    private static let paywallMarkers = [
        "id=\"gateway-content\"",
        "subscribe to continue reading",
        "subscribe to read the full",
        "create your free account or log in",
        "log in or create a free account",
        "to continue reading, subscribe",
        "already a subscriber? sign in",
        "already a subscriber? log in",
    ]

    /// Matches `"isAccessibleForFree": false` (and the quoted-"False"
    /// variants some publishers emit) in JSON-LD.
    private static let notFreeRegex = try? NSRegularExpression(
        pattern: #""isaccessibleforfree"\s*:\s*"?false"?"#,
        options: []
    )

    /// Meter/paywall boilerplate that gets extracted INTO the body when a
    /// gated page is captured anonymously. NYT serves a truncated article
    /// plus these strings and gates client-side — the capture can be
    /// thousands of characters and still be a partial article, so these
    /// override the length check.
    private static let markdownPaywallMarkers = [
        "while we verify access",
        "already a subscriber? log in",
        "want all of the times? subscribe",
    ]

    static func evaluate(markdown: String, html: String) -> Verdict {
        let lowerMarkdown = markdown.lowercased()
        for marker in markdownPaywallMarkers where lowerMarkdown.contains(marker) {
            return .paywalled
        }

        let chars = markdown.filter { !$0.isWhitespace }.count
        if chars >= paywallSafeThreshold {
            return .pass
        }
        if hasPaywallMarkers(html: html) {
            return .paywalled
        }
        if chars < thinThreshold {
            return .thinContent
        }
        return .pass
    }

    /// True when the HTML carries paywall/login-wall markers. Only meaningful
    /// combined with a thin body — full articles can carry these too.
    static func hasPaywallMarkers(html: String) -> Bool {
        let lower = html.lowercased()
        for marker in paywallMarkers where lower.contains(marker) {
            return true
        }
        if let regex = notFreeRegex {
            let range = NSRange(lower.startIndex..., in: lower)
            if regex.firstMatch(in: lower, range: range) != nil {
                return true
            }
        }
        return false
    }
}
