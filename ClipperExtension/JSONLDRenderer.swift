import Foundation

/// Turns a JSON-LD fast-path hit into Markdown.
///
/// JSON-LD `articleBody` is the publisher's canonical *text*, but for most
/// publishers (Wired, The Verge, NYT) it is plain text: links, subheads and
/// lists are gone, and some (Wired) omit the opening paragraph entirely.
/// So for plain-text bodies this renderer lets JSON-LD decide *which*
/// paragraphs belong to the article, and borrows the *markup* — and any
/// opening paragraphs the structured data left out — from the page DOM.
///
/// Only DOM blocks whose text matches a JSON-LD paragraph are used, so
/// related-story cards and other page chrome (the reason the fast path
/// exists) never leak in. If too few paragraphs can be matched (e.g. an
/// anonymous paywall shell whose DOM holds less than the JSON-LD body), it
/// falls back to plain paragraphs.
enum JSONLDRenderer {

    struct Output {
        let markdown: String
        let markerMap: [Int: URL]
    }

    /// Minimum share of JSON-LD paragraphs that must be found in the DOM
    /// before the DOM's markup is trusted.
    static let minMatchRatio = 0.6

    /// Most opening paragraphs recovered from the DOM.
    private static let maxLedeParagraphs = 3

    /// Shortest paragraph trusted to locate the article in the page.
    private static let anchorMinLength = 40

    static func render(
        _ ld: JSONLDExtractor.Result,
        pageHTML: String,
        baseURL: URL?,
        maxBytes: Int
    ) -> Output {
        if ld.articleBodyIsHTML {
            let bounded = HTMLToMarkdown.truncateUTF8(ld.articleBody, maxBytes: maxBytes)
            let marked = HTMLToMarkdown.replaceImgTagsWithMarkers(bounded, baseURL: baseURL)
            return Output(markdown: HTMLToMarkdown.convert(marked.html), markerMap: marked.markerMap)
        }

        // The lead image goes through the same marker injection as any
        // inline image so the downloader treats it identically.
        let lead = HTMLToMarkdown.replaceImgTagsWithMarkers(leadImageHTML(from: ld.imageURLs), baseURL: baseURL)
        let leadMarkdown = HTMLToMarkdown.convert(lead.html)

        let splits = candidateSplits(ld.articleBody)
        let blocks = hydratedBlocks(
            splits: splits,
            pageHTML: HTMLToMarkdown.truncateUTF8(pageHTML, maxBytes: maxBytes)
        ) ?? [HTMLToMarkdown.convert(plainHTML(splitParagraphs(ld.articleBody)))]

        let markdown = ([leadMarkdown] + blocks)
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        return Output(markdown: markdown, markerMap: lead.markerMap)
    }

    // MARK: - DOM hydration

    private struct Candidate {
        let node: HTMLNode
        let text: String
    }

    /// One Markdown block per article paragraph (preceded by any recovered
    /// lede), or nil when the DOM can't be trusted to hold the article.
    ///
    /// Publishers disagree about what separates paragraphs in `articleBody`
    /// (one Wired body uses "\n" almost everywhere but "\n\n" once), so each
    /// plausible split is aligned against the page and the one that accounts
    /// for the most article text wins.
    private static func hydratedBlocks(splits: [[String]], pageHTML: String) -> [String]? {
        guard splits.contains(where: { !$0.isEmpty }),
              let document = SwiftSoupAdapter.parse(html: pageHTML)
        else { return nil }

        var candidates: [Candidate] = []
        collectCandidates(document, into: &candidates, depth: 0)
        guard !candidates.isEmpty else { return nil }

        var best: (paragraphs: [String], matches: [Int?], ratio: Double)?
        for paragraphs in splits where !paragraphs.isEmpty {
            let matches = alignParagraphs(paragraphs, to: candidates)
            let total = paragraphs.reduce(0) { $0 + normalize($1).count }
            let matchedChars = zip(paragraphs, matches).reduce(0) { sum, pair in
                pair.1 == nil ? sum : sum + normalize(pair.0).count
            }
            let ratio = total == 0 ? 0 : Double(matchedChars) / Double(total)
            if ratio > (best?.ratio ?? -1) { best = (paragraphs, matches, ratio) }  // ties keep the earlier split
        }
        guard let chosen = best, chosen.ratio >= minMatchRatio else { return nil }
        let (paragraphs, matches) = (chosen.paragraphs, chosen.matches)

        var blocks: [String] = []
        if let firstIndex = matches.compactMap({ $0 }).first {
            blocks += ledeBlocks(before: candidates, at: firstIndex)
        }
        for (paragraph, match) in zip(paragraphs, matches) {
            if let match, let rendered = render(candidates[match].node), !rendered.isEmpty {
                blocks.append(rendered)
            } else {
                blocks.append(HTMLToMarkdown.convert(plainHTML([paragraph])))
            }
        }
        return blocks
    }

    /// Paragraph-level blocks in document order that can hold article text.
    private static let blockTags: Set<String> = ["p", "h1", "h2", "h3", "h4", "h5", "h6", "li", "blockquote"]
    private static let skippedTags: Set<String> = ["script", "style", "noscript", "svg", "template", "iframe", "button", "form"]

    private static func collectCandidates(_ node: HTMLNode, into out: inout [Candidate], depth: Int) {
        guard depth < HTMLNode.maxDepth else { return }
        guard let tag = node.tag else { return }
        if skippedTags.contains(tag) || ReadabilityExtractor.isHiddenNode(node) { return }

        if blockTags.contains(tag), !containsBlockChild(node) {
            let text = normalize(node.textContent)
            if !text.isEmpty { out.append(Candidate(node: node, text: text)) }
            return
        }
        for child in node.children { collectCandidates(child, into: &out, depth: depth + 1) }
    }

    /// A `li`/`blockquote` that wraps paragraphs is a container, not a block.
    private static func containsBlockChild(_ node: HTMLNode) -> Bool {
        guard node.tag == "li" || node.tag == "blockquote" else { return false }
        return node.children.contains { child in
            guard let tag = child.tag else { return false }
            return tag == "p" || tag == "ul" || tag == "ol" || tag == "li"
        }
    }

    private static func isMatch(_ domText: String, _ needle: String, prefix: String) -> Bool {
        if domText == needle { return true }
        // The DOM block may carry a little extra text (a footnote marker, an
        // inline "Read more"). Accept a shared opening and comparable length.
        guard prefix.count >= 20, domText.hasPrefix(prefix) else { return false }
        let ratio = Double(domText.count) / Double(needle.count)
        return ratio >= 0.75 && ratio <= 1.33
    }

    /// Assign each paragraph to a DOM block so that the assignments are in
    /// document order and cover as much text as possible. A greedy "first
    /// match ahead" is not enough: a short line that recurs in a widget far
    /// down the page ("Got a Tip?") would pull the cursor past the whole
    /// article. Instead this finds the heaviest increasing sequence of
    /// (paragraph, block) pairs, weighting by paragraph length, so a short
    /// stray match can never outweigh the long paragraphs it would orphan.
    private static func alignParagraphs(_ paragraphs: [String], to candidates: [Candidate]) -> [Int?] {
        struct Pair { let paragraph: Int; let block: Int; let weight: Int; var best = 0; var previous: Int? }

        var pairs: [Pair] = []
        for (index, paragraph) in paragraphs.enumerated() {
            let needle = normalize(paragraph)
            let prefix = String(needle.prefix(50))
            var taken = 0
            for (block, candidate) in candidates.enumerated() where isMatch(candidate.text, needle, prefix: prefix) {
                pairs.append(Pair(paragraph: index, block: block, weight: min(needle.count, 300)))
                taken += 1
                if taken == 8 { break }  // pathological repeats; the best-ordered few suffice
            }
        }
        guard !pairs.isEmpty else { return Array(repeating: nil, count: paragraphs.count) }

        for a in pairs.indices {
            var bestBefore = 0
            var previous: Int?
            for b in 0..<a
            where pairs[b].paragraph < pairs[a].paragraph && pairs[b].block < pairs[a].block && pairs[b].best > bestBefore {
                bestBefore = pairs[b].best
                previous = b
            }
            pairs[a].best = pairs[a].weight + bestBefore
            pairs[a].previous = previous
        }

        var matches = [Int?](repeating: nil, count: paragraphs.count)
        var cursor = pairs.indices.max { pairs[$0].best < pairs[$1].best }
        while let i = cursor {
            matches[pairs[i].paragraph] = pairs[i].block
            cursor = pairs[i].previous
        }

        // A short line ahead of the first substantial match is too ambiguous
        // to trust (it may be nav chrome); leave it to the plain fallback.
        for (index, paragraph) in paragraphs.enumerated() {
            if normalize(paragraph).count >= anchorMinLength { break }
            matches[index] = nil
        }
        return matches
    }

    // MARK: - Lede recovery

    /// Opening paragraphs that sit just before the first matched block but
    /// are missing from the JSON-LD body.
    private static func ledeBlocks(before candidates: [Candidate], at index: Int) -> [String] {
        let first = candidates[index].node
        var lede: [HTMLNode] = []

        if let parent = first.parent, let position = parent.children.firstIndex(where: { $0 === first }) {
            var j = position - 1
            while j >= 0, lede.count < maxLedeParagraphs {
                let sibling = parent.children[j]
                j -= 1
                if case .text(let t) = sibling.kind, t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
                guard isLedeParagraph(sibling) else { break }
                lede.insert(sibling, at: 0)
            }
        }

        return lede.compactMap { render($0) }.filter { !$0.isEmpty }
    }

    private static func isLedeParagraph(_ node: HTMLNode) -> Bool {
        guard node.tag == "p", !ReadabilityExtractor.isHiddenNode(node), !containsImage(node) else { return false }
        let text = node.textContent.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.count >= 40 && ReadabilityExtractor.linkDensity(of: node) < 0.5
    }

    // MARK: - Rendering

    /// Markdown for one matched DOM block; nil when it can't be rendered
    /// safely (it holds an image, which would bypass marker injection).
    private static func render(_ node: HTMLNode) -> String? {
        guard !containsImage(node) else { return nil }
        let markdown = HTMLToMarkdown.convert(node: node)
        return node.tag == "li" && !markdown.isEmpty ? "- " + markdown : markdown
    }

    private static func containsImage(_ node: HTMLNode) -> Bool {
        if node.tag == "img" || node.tag == "picture" { return true }
        return node.children.contains { containsImage($0) }
    }

    // MARK: - Plain-text helpers

    /// Every plausible paragraph split of a plain-text body, most-likely
    /// first: blank-line separated (when the body has blank lines), then one
    /// paragraph per line.
    static func candidateSplits(_ text: String) -> [[String]] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        let clean: (String) -> String = { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        var splits: [[String]] = []
        if normalized.contains("\n\n") {
            splits.append(normalized.components(separatedBy: "\n\n").map(clean).filter { !$0.isEmpty })
        }
        splits.append(normalized.components(separatedBy: "\n").map(clean).filter { !$0.isEmpty })
        return splits
    }

    /// Split a plain-text body into paragraphs: blank-line separated when
    /// available, else one per line (Wired emits the latter).
    static func splitParagraphs(_ text: String) -> [String] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        let separator = normalized.contains("\n\n") ? "\n\n" : "\n"
        return normalized
            .components(separatedBy: separator)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// `<p>` markup for plain paragraphs. HTMLToMarkdown parses it, so the
    /// text must be escaped.
    static func plainHTML(_ paragraphs: [String]) -> String {
        paragraphs
            .map { "<p>\(escapeHTML($0))</p>" }
            .joined(separator: "\n")
    }

    /// Publisher-declared lead image as a bare `<img>`; capped at one since
    /// publishers list the same hero at several aspect ratios.
    static func leadImageHTML(from urls: [URL]) -> String {
        guard let lead = urls.first else { return "" }
        let escaped = lead.absoluteString
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
        return "<img src=\"\(escaped)\">\n"
    }

    private static func escapeHTML(_ s: String) -> String {
        s
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    /// Whitespace-, nbsp- and quote-insensitive form used only for matching.
    static func normalize(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        var lastWasSpace = true
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\u{2018}", "\u{2019}": out.append("'"); lastWasSpace = false
            case "\u{201C}", "\u{201D}": out.append("\""); lastWasSpace = false
            default:
                if CharacterSet.whitespacesAndNewlines.contains(scalar) || scalar == "\u{00A0}" {
                    if !lastWasSpace { out.append(" "); lastWasSpace = true }
                } else {
                    out.unicodeScalars.append(scalar)
                    lastWasSpace = false
                }
            }
        }
        if out.hasSuffix(" ") { out.removeLast() }
        return out
    }
}
