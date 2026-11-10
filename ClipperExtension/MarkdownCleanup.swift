import Foundation

/// Removes publisher page chrome that survives extraction and lands in the
/// Markdown body: share/listen widgets, newsletter prompts, comment loaders,
/// "related stories" tails (often a pile of empty bullets), and duplicated
/// responsive copies of the same line (a byline rendered once for mobile and
/// once for desktop).
///
/// Deliberately conservative: it only matches strings seen on real pages and
/// only cuts a trailing section when nothing in it reads like prose. Code
/// fences are never modified.
enum MarkdownCleanup {

    /// Lines (after stripping a list marker) that are always page chrome.
    private static let chromeLines: Set<String> = [
        "share full article",
        "loading comments...",
        "loading comments…",
    ]

    private static let chromePatterns: [NSRegularExpression] = [
        #"^listen\s*·\s*\d+:\d{2}\s*min$"#,
        #"^sign up for the .+ newsletter\.(\s.*)?$"#,
        // NYT blurbs without the word "newsletter": "Sign up for Science Times Get stories that ...".
        // Short standalone lines only, so ordinary prose starting "Sign up for" is left alone.
        #"^sign up for .{1,90}\bget\b.{0,130}$"#,
        // Electrek/9to5-network sign-off: "Stay up to date with the latest content by subscribing to ...".
        #"^stay up to date with the latest content by .*subscribing to .+"#,
    ].compactMap { try? NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }

    /// A heading that opens a trailing recirculation section.
    private static let tailHeading = try? NSRegularExpression(
        pattern: #"^#{1,6}\s*(related(\s+(content|articles|stories|coverage))?|more\s+stories|recommended(\s+for\s+you)?|comments?(\s*\(\d+\))?)\s*:?\s*$"#,
        options: [.caseInsensitive]
    )

    /// A tail longer than this (per line, links stripped) is real prose, so
    /// the section is kept.
    private static let proseLineThreshold = 220

    static func trimBoilerplate(_ markdown: String) -> String {
        var lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")

        lines = cutTrailingSection(lines)
        lines = dropChromeLines(lines)
        lines = collapseDuplicateParagraphs(lines)
        lines = dropTrailingEmptyBullets(lines)

        return lines.joined(separator: "\n")
            .replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Passes

    /// Cut from a recirculation heading (or the comment loader line) to the
    /// end, provided the remainder contains no prose.
    private static func cutTrailingSection(_ lines: [String]) -> [String] {
        var inFence = false
        for (i, line) in lines.enumerated() {
            if isFence(line) { inFence.toggle(); continue }
            if inFence { continue }
            if isTailMarker(line) {
                let tail = lines[(i + 1)...]
                if tail.contains(where: { visibleLength($0) > proseLineThreshold }) { continue }
                return Array(lines[..<i])
            }
            if isCardRunStart(lines, at: i) { return Array(lines[..<i]) }
        }
        return lines
    }

    /// Whether `lines[i...]` is a run of "related story" cards that reaches the
    /// end of the document: a heading, then a link-only line carrying a
    /// "Read more" link, repeated, with nothing else (no prose) in between.
    /// Requiring "Read more" keeps an ordinary trailing heading + link list
    /// (a references section) from being cut.
    private static func isCardRunStart(_ lines: [String], at i: Int) -> Bool {
        guard isHeading(lines[i]) else { return false }
        var sawReadMore = false
        var j = i
        while j < lines.count {
            let line = lines[j]
            if line.trimmingCharacters(in: .whitespaces).isEmpty || isHeading(line) {
                j += 1
                continue
            }
            guard isLinkOnly(line) else { return false }
            if line.range(of: #"\[\s*read more\s*\]\("#, options: [.regularExpression, .caseInsensitive]) != nil {
                sawReadMore = true
            }
            j += 1
        }
        return sawReadMore
    }

    private static func dropChromeLines(_ lines: [String]) -> [String] {
        var inFence = false
        return lines.filter { line in
            if isFence(line) { inFence.toggle(); return true }
            if inFence { return true }
            return !isChrome(line)
        }
    }

    /// Drop a non-blank line identical to the previous non-blank line
    /// (ignoring the blank lines between them).
    private static func collapseDuplicateParagraphs(_ lines: [String]) -> [String] {
        var out: [String] = []
        var inFence = false
        var previous: String?
        for line in lines {
            if isFence(line) { inFence.toggle(); out.append(line); previous = nil; continue }
            if inFence { out.append(line); continue }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { out.append(line); continue }
            if trimmed.count >= 12, trimmed == previous { continue }
            previous = trimmed
            out.append(line)
        }
        return out
    }

    private static func dropTrailingEmptyBullets(_ lines: [String]) -> [String] {
        var result = lines
        while let last = result.last {
            let trimmed = last.trimmingCharacters(in: .whitespaces)
            let isEmptyBullet = trimmed == "-" || trimmed == "*" ||
                trimmed.range(of: #"^\d+\.$"#, options: .regularExpression) != nil
            if trimmed.isEmpty || isEmptyBullet {
                result.removeLast()
            } else {
                break
            }
        }
        return result
    }

    // MARK: - Matching

    private static func isHeading(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).range(of: #"^#{1,6}\s+\S"#, options: .regularExpression) != nil
    }

    /// A line made only of Markdown links (and whitespace): a card's category and "Read more" links.
    private static func isLinkOnly(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("](") else { return false }
        let withoutLinks = trimmed.replacingOccurrences(of: #"\[[^\]]*\]\([^)]*\)"#, with: "", options: .regularExpression)
        return withoutLinks.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private static func isFence(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).hasPrefix("```")
    }

    private static func isTailMarker(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if let tailHeading,
           tailHeading.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)) != nil {
            return true
        }
        return coreText(of: line).hasPrefix("loading comments")
    }

    private static func isChrome(_ line: String) -> Bool {
        let core = coreText(of: line)
        if chromeLines.contains(core) { return true }
        let range = NSRange(core.startIndex..., in: core)
        return chromePatterns.contains { $0.firstMatch(in: core, range: range) != nil }
    }

    /// Lowercased line with surrounding whitespace and a leading list marker
    /// removed, and any `[[IMG:n]]` placeholders stripped.
    private static func coreText(of line: String) -> String {
        var s = line.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("- ") || s.hasPrefix("* ") { s = String(s.dropFirst(2)) }
        s = s.replacingOccurrences(of: #"\[\[IMG:\d+\]\]"#, with: "", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespaces).lowercased()
    }

    /// Line length with Markdown link targets and image placeholders removed,
    /// so a list of headlines-as-links doesn't count as prose.
    private static func visibleLength(_ line: String) -> Int {
        line
            .replacingOccurrences(of: #"\]\([^)]*\)"#, with: "]", options: .regularExpression)
            .replacingOccurrences(of: #"\[\[IMG:\d+\]\]"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
            .count
    }
}
