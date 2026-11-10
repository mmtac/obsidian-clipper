import Foundation
import os

/// Converts HTML content to Markdown by parsing the HTML into a DOM tree
/// and walking it to emit Markdown syntax. Uses the same HTMLParser as
/// ReadabilityExtractor — no NSAttributedString or UIKit dependency.
enum HTMLToMarkdown {

    /// Maximum HTML size (in bytes) to parse. Prevents memory exhaustion
    /// in the share extension's constrained environment.
    static let maxHTMLSize = 2 * 1024 * 1024 // 2 MB

    private static let logger = Logger(subsystem: "com.mmtac.md-clipper", category: "markdown")

    /// Truncate `s` to at most `maxBytes` UTF-8 bytes, cutting on a valid
    /// UTF-8 scalar boundary. Never returns more than `maxBytes` bytes and
    /// never falls back to the untruncated input. The result is always a
    /// prefix of `s` (by Unicode scalars).
    static func truncateUTF8(_ s: String, maxBytes: Int) -> String {
        let utf8 = s.utf8
        guard maxBytes > 0 else { return "" }
        guard utf8.count > maxBytes else { return s }
        var end = utf8.index(utf8.startIndex, offsetBy: maxBytes)
        // Walk back off UTF-8 continuation bytes (10xxxxxx) so `end` lands
        // on the first byte of a scalar.
        while end > utf8.startIndex, (utf8[end] & 0xC0) == 0x80 {
            end = utf8.index(before: end)
        }
        return String(s.unicodeScalars[..<end])
    }

    /// Main entry point: takes raw HTML and returns Markdown text.
    /// Pure Swift — no UIKit/WebKit dependency, safe to call from any thread.
    static func convert(_ html: String) -> String {
        // Truncate oversized HTML to prevent memory exhaustion
        let htmlToConvert = truncateUTF8(html, maxBytes: maxHTMLSize)

        var parser = HTMLParser(html: htmlToConvert)
        guard let document = parser.parse() else {
            return stripHTMLTags(htmlToConvert)
        }

        var ctx = MarkdownContext()
        renderNode(document, to: &ctx)

        return finalizeMarkdown(ctx.result)
    }

    /// Convert an already-parsed DOM subtree directly to Markdown, skipping
    /// the HTML parser. Used when the caller (e.g. ReadabilityExtractor) has
    /// already built the tree — avoids a redundant second parse of the same
    /// content.
    static func convert(node: HTMLNode) -> String {
        var ctx = MarkdownContext()
        renderNode(node, to: &ctx)

        return finalizeMarkdown(ctx.result)
    }

    /// Shared post-processing: strip whitespace-only lines (which `<p>&nbsp;</p>`
    /// and similar empty wrappers produce after `collapseWhitespace`), then
    /// collapse runs of 3+ newlines into paragraph breaks.
    private static func finalizeMarkdown(_ raw: String) -> String {
        var md = raw
        md = md.replacingOccurrences(of: "\r\n", with: "\n")
        // Strip trailing whitespace from blank-looking lines so the next
        // collapse can fold them. Lookahead keeps the trailing newline.
        md = md.replacingOccurrences(
            of: "\\n[ \\t]+(?=\\n)",
            with: "\n",
            options: .regularExpression
        )
        md = md.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
        return md.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Tree-Walking Markdown Renderer

    /// Mutable context accumulated while walking the DOM tree.
    private struct MarkdownContext {
        var result: String = ""
        var inPre = false
        var inCode = false
        var listStack: [ListKind] = []
        /// Current element nesting depth; rendering stops descending past
        /// `HTMLNode.maxDepth` so pathological pages can't overflow the stack.
        var depth = 0

        enum ListKind { case ordered(Int), unordered }

        /// Whether the output currently ends with a blank line (two newlines).
        var endsWithBlankLine: Bool {
            result.hasSuffix("\n\n")
        }

        /// Whether the output currently ends with at least one newline.
        var endsWithNewline: Bool {
            result.hasSuffix("\n")
        }

        /// Ensure the output has a blank line (paragraph break) at the end.
        mutating func ensureBlankLine() {
            if result.isEmpty { return }
            if endsWithBlankLine { return }
            if endsWithNewline {
                result += "\n"
            } else {
                result += "\n\n"
            }
        }

        /// Ensure the output ends with at least one newline.
        mutating func ensureNewline() {
            if result.isEmpty { return }
            if !endsWithNewline {
                result += "\n"
            }
        }
    }

    /// Block-level tags that should get paragraph breaks around them.
    private static let blockTags: Set<String> = [
        "p", "div", "section", "article", "main", "aside", "header", "footer",
        "h1", "h2", "h3", "h4", "h5", "h6",
        "ul", "ol", "li",
        "blockquote", "pre", "figure", "figcaption",
        "table", "thead", "tbody", "tfoot", "tr",
        "hr", "br", "details", "summary", "dl", "dt", "dd"
    ]

    private static let headingTags: Set<String> = ["h1", "h2", "h3", "h4", "h5", "h6"]

    private static func renderNode(_ node: HTMLNode, to ctx: inout MarkdownContext) {
        guard ctx.depth < HTMLNode.maxDepth else { return }
        ctx.depth += 1
        defer { ctx.depth -= 1 }
        switch node.kind {
        case .text(let text):
            if ctx.inPre {
                // Inside <pre>, preserve text as-is
                ctx.result += text
            } else {
                // Collapse whitespace for normal text
                let collapsed = collapseWhitespace(text)
                if !collapsed.isEmpty {
                    ctx.result += ctx.inCode ? collapsed : escapeInlineMarkdown(collapsed)
                }
            }

        case .element(let tag, _):
            switch tag {
            case "document", "html", "body", "span", "font", "center", "small", "big", "u",
                 "section", "article", "main", "div", "aside", "details", "summary",
                 "figure", "figcaption", "header", "footer", "dl", "dd", "dt",
                 "thead", "tbody", "tfoot",
                 "abbr", "address", "cite", "mark", "sub", "sup", "time", "var", "wbr",
                 "picture", "source":
                // Block containers: just ensure block separation and render children
                let isBlock = blockTags.contains(tag)
                if isBlock { ctx.ensureBlankLine() }
                renderChildren(node, to: &ctx)
                if isBlock { ctx.ensureBlankLine() }

            case "p":
                ctx.ensureBlankLine()
                renderChildren(node, to: &ctx)
                ctx.ensureBlankLine()

            case "h1", "h2", "h3", "h4", "h5", "h6":
                ctx.ensureBlankLine()
                let level = tag.last?.wholeNumberValue ?? 1
                ctx.result += String(repeating: "#", count: level) + " "
                renderChildrenInline(node, to: &ctx)
                ctx.ensureBlankLine()

            case "br":
                ctx.result += "\n"

            case "hr":
                ctx.ensureBlankLine()
                ctx.result += "---"
                ctx.ensureBlankLine()

            case "strong", "b":
                ctx.result += "**"
                renderChildren(node, to: &ctx)
                ctx.result += "**"

            case "em", "i":
                ctx.result += "_"
                renderChildren(node, to: &ctx)
                ctx.result += "_"

            case "s", "del", "strike":
                ctx.result += "~~"
                renderChildren(node, to: &ctx)
                ctx.result += "~~"

            case "code":
                if ctx.inPre {
                    // Inside <pre><code>, just render children (code fence is handled by <pre>)
                    renderChildren(node, to: &ctx)
                } else {
                    ctx.result += "`"
                    let wasInCode = ctx.inCode
                    ctx.inCode = true
                    renderChildrenInline(node, to: &ctx)
                    ctx.inCode = wasInCode
                    ctx.result += "`"
                }

            case "pre":
                ctx.ensureBlankLine()
                ctx.result += "```\n"
                let wasInPre = ctx.inPre
                ctx.inPre = true
                renderChildren(node, to: &ctx)
                ctx.inPre = wasInPre
                ctx.ensureNewline()
                ctx.result += "```"
                ctx.ensureBlankLine()

            case "blockquote":
                ctx.ensureBlankLine()
                // Render children to a sub-context, then prefix each line with >
                var sub = MarkdownContext()
                sub.depth = ctx.depth
                renderChildren(node, to: &sub)
                let lines = sub.result.trimmingCharacters(in: .whitespacesAndNewlines)
                    .components(separatedBy: "\n")
                for line in lines {
                    ctx.result += "> " + line + "\n"
                }
                ctx.ensureBlankLine()

            case "a":
                let href = node.attribute("href") ?? ""
                let text = node.textContent.trimmingCharacters(in: .whitespacesAndNewlines)
                if href.isEmpty || text.isEmpty {
                    renderChildren(node, to: &ctx)
                } else if Self.isDangerousScheme(href) {
                    // Strip dangerous links, keep text only
                    ctx.result += text
                } else {
                    ctx.result += "[\(text)](\(Self.sanitizeLinkHref(href)))"
                }

            case "img":
                // Self-closing, render as image reference if src is present
                let src = node.attribute("src") ?? ""
                let alt = node.attribute("alt") ?? ""
                if !src.isEmpty {
                    ctx.result += "![\(alt)](\(src))"
                }

            case "ul":
                ctx.ensureBlankLine()
                ctx.listStack.append(.unordered)
                renderChildren(node, to: &ctx)
                ctx.listStack.removeLast()
                ctx.ensureBlankLine()

            case "ol":
                ctx.ensureBlankLine()
                let startAttr = node.attribute("start")
                let start = Int(startAttr ?? "1") ?? 1
                ctx.listStack.append(.ordered(start))
                renderChildren(node, to: &ctx)
                ctx.listStack.removeLast()
                ctx.ensureBlankLine()

            case "li":
                ctx.ensureNewline()
                // Remember where this item starts so an item that renders to
                // nothing (e.g. a "related story" card whose only content is
                // a text-less link) can be rolled back instead of leaving a
                // bare "- " bullet behind.
                let itemStart = ctx.result.utf8.endIndex
                let savedListStack = ctx.listStack
                let indent = String(repeating: "  ", count: max(0, ctx.listStack.count - 1))
                if let current = ctx.listStack.last {
                    switch current {
                    case .unordered:
                        ctx.result += indent + "- "
                    case .ordered(let n):
                        ctx.result += indent + "\(n). "
                        // Increment the counter
                        if let idx = ctx.listStack.indices.last {
                            ctx.listStack[idx] = .ordered(n + 1)
                        }
                    }
                }
                let contentStart = ctx.result.utf8.endIndex
                renderChildrenInline(node, to: &ctx)
                if ctx.result[contentStart...].allSatisfy(\.isWhitespace) {
                    ctx.result.removeSubrange(itemStart...)
                    ctx.listStack = savedListStack
                } else {
                    ctx.ensureNewline()
                }

            case "table":
                ctx.ensureBlankLine()
                renderTable(node, to: &ctx)
                ctx.ensureBlankLine()

            case "tr", "td", "th":
                // Handled by renderTable
                renderChildren(node, to: &ctx)

            case "script", "style", "noscript", "nav", "iframe",
                 "object", "embed", "applet", "form", "button",
                 "input", "select", "textarea", "label", "svg", "canvas", "video", "audio":
                // Skip non-content tags entirely
                break

            default:
                // Unknown tags: just render children
                renderChildren(node, to: &ctx)
            }
        }
    }

    private static func renderChildren(_ node: HTMLNode, to ctx: inout MarkdownContext) {
        for child in node.children {
            renderNode(child, to: &ctx)
        }
    }

    /// Render children without block-level breaks — used for inline contexts like headings, list items.
    private static func renderChildrenInline(_ node: HTMLNode, to ctx: inout MarkdownContext) {
        for child in node.children {
            switch child.kind {
            case .text(let text):
                if ctx.inPre {
                    ctx.result += text
                } else if ctx.inCode {
                    ctx.result += collapseWhitespace(text)
                } else {
                    ctx.result += escapeInlineMarkdown(collapseWhitespace(text))
                }
            case .element(let tag, _):
                if blockTags.contains(tag) && !["br", "li"].contains(tag) {
                    // Flatten block elements inside inline context
                    let text = child.textContent.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty {
                        if !ctx.result.hasSuffix(" ") && !ctx.result.isEmpty { ctx.result += " " }
                        ctx.result += text
                    }
                } else {
                    renderNode(child, to: &ctx)
                }
            }
        }
    }

    /// Render an HTML table as a Markdown table.
    private static func renderTable(_ table: HTMLNode, to ctx: inout MarkdownContext) {
        var rows: [[String]] = []
        collectTableRows(table, into: &rows)

        guard !rows.isEmpty else { return }

        let colCount = rows.map(\.count).max() ?? 0
        guard colCount > 0 else { return }

        // Normalize all rows to have the same column count
        let normalized = rows.map { row -> [String] in
            var r = row
            while r.count < colCount { r.append("") }
            return Array(r.prefix(colCount))
        }

        // First row is header
        ctx.result += "| " + normalized[0].joined(separator: " | ") + " |\n"
        ctx.result += "| " + Array(repeating: "---", count: colCount).joined(separator: " | ") + " |\n"
        for row in normalized.dropFirst() {
            ctx.result += "| " + row.joined(separator: " | ") + " |\n"
        }
    }

    private static func collectTableRows(_ node: HTMLNode, into rows: inout [[String]]) {
        if node.tag == "tr" {
            var cells: [String] = []
            for child in node.children {
                if child.tag == "td" || child.tag == "th" {
                    cells.append(child.textContent.trimmingCharacters(in: .whitespacesAndNewlines))
                }
            }
            if !cells.isEmpty { rows.append(cells) }
            return
        }
        for child in node.children {
            collectTableRows(child, into: &rows)
        }
    }

    /// Check if a URL has a dangerous scheme (javascript:, data:, vbscript:).
    private static func isDangerousScheme(_ href: String) -> Bool {
        let lower = href.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return lower.hasPrefix("javascript:") || lower.hasPrefix("data:") || lower.hasPrefix("vbscript:")
    }

    /// Escape parentheses in link URLs to prevent broken Markdown.
    private static func sanitizeLinkHref(_ href: String) -> String {
        href.replacingOccurrences(of: "(", with: "%28")
            .replacingOccurrences(of: ")", with: "%29")
    }

    /// Escape characters in running text that Markdown would read as
    /// emphasis or code ("*sshole" would otherwise pair up with a later `*`).
    /// `_` is left alone: intraword underscores never open emphasis, and
    /// escaping them mangles identifiers and URLs.
    private static func escapeInlineMarkdown(_ text: String) -> String {
        guard text.contains("*") || text.contains("`") else { return text }
        return text
            .replacingOccurrences(of: "*", with: "\\*")
            .replacingOccurrences(of: "`", with: "\\`")
    }

    /// Collapse runs of whitespace into a single space.
    private static func collapseWhitespace(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        var lastWasWhitespace = false
        for char in text {
            if char.isWhitespace {
                if !lastWasWhitespace {
                    result.append(" ")
                    lastWasWhitespace = true
                }
            } else {
                result.append(char)
                lastWasWhitespace = false
            }
        }
        return result
    }

    /// Fallback: strip HTML tags with regex if parsing fails.
    private static func stripHTMLTags(_ html: String) -> String {
        html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Image marker injection

    /// Replace `<img>` tags in HTML with text markers like `[[IMG:0]]`, `[[IMG:1]]`, etc.
    /// Returns the modified HTML and a mapping of marker index to original image source URL.
    /// The markers survive Readability extraction and tree-based Markdown conversion as plain text,
    /// allowing us to place images inline at their original positions in the final Markdown.
    static func replaceImgTagsWithMarkers(_ html: String, baseURL: URL?) -> (html: String, markerMap: [Int: URL]) {
        logger.debug("replaceImgTagsWithMarkers() entered; html_bytes=\(html.utf8.count, privacy: .public) baseURL=\(baseURL?.absoluteString ?? "nil", privacy: .private)")
        var markerMap: [Int: URL] = [:]
        var markerIndex = 0
        var seen: [String: Int] = [:] // URL string -> marker index

        let nsHTML = html as NSString
        let fullRange = NSRange(location: 0, length: nsHTML.length)

        guard let imgRegex = Self.imgTagRegex else {
            logger.error("replaceImgTagsWithMarkers() img regex unavailable; returning input")
            return (html, markerMap)
        }

        let matches = imgRegex.matches(in: html, range: fullRange)
        logger.debug("replaceImgTagsWithMarkers() <img> matches=\(matches.count, privacy: .public)")

        // Build replacements in forward order so marker indices match document order,
        // then apply in reverse so NSRange offsets remain valid.
        var replacements: [(range: NSRange, marker: String)] = []

        // A <picture> is ONE image offered at several sizes/formats: its
        // <source> elements and <img> carry different URLs (e.g. ?width=600 /
        // 1200 / 1800) for the same photo. Track picture extents and which
        // ones already have a usable <img> so the <source> pass below doesn't
        // turn one photo into several markers (and burn the image cap).
        let pictureRanges: [NSRange] = Self.pictureRegex?.matches(in: html, range: fullRange).map(\.range) ?? []
        var acceptedImgLocations: [Int] = []

        for match in matches {
            let imgTag = nsHTML.substring(with: match.range)

            let src = extractAttribute("src", from: imgTag)
                ?? extractAttribute("data-src", from: imgTag)
                ?? extractAttribute("data-lazy-src", from: imgTag)
                ?? extractAttribute("data-original", from: imgTag)
                ?? extractAttribute("srcset", from: imgTag).flatMap(pickLargestFromSrcset)

            guard let srcStr = src else { continue }
            let trimmed = srcStr.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            // Skip tracking pixels, SVGs, data URIs
            let lower = trimmed.lowercased()
            if lower.contains("pixel") || lower.contains("tracking") || lower.contains("beacon") { continue }
            if lower.contains(".svg") { continue }
            if lower.hasPrefix("data:") { continue }

            // Resolve URL
            let resolved: URL?
            if let absolute = URL(string: trimmed), absolute.scheme != nil {
                resolved = absolute
            } else if let base = baseURL {
                resolved = URL(string: trimmed, relativeTo: base)
            } else {
                resolved = nil
            }

            guard let url = resolved,
                  let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https"
            else { continue }

            let urlStr = url.absoluteString
            acceptedImgLocations.append(match.range.location)

            // If we've seen this URL before, reuse the existing marker index
            if let existingIndex = seen[urlStr] {
                replacements.append((range: match.range, marker: "[[IMG:\(existingIndex)]]"))
                continue
            }

            seen[urlStr] = markerIndex
            markerMap[markerIndex] = url
            replacements.append((range: match.range, marker: "[[IMG:\(markerIndex)]]"))
            markerIndex += 1
        }

        // Second pass: <source> elements (typically inside <picture>). Only emit a
        // new marker when the URL isn't already covered by a sibling <img>.
        if let sourceRegex = Self.sourceTagRegex {
            let sourceMatches = sourceRegex.matches(in: html, range: fullRange)
            let pictureHasImg = pictureRanges.map { range in
                acceptedImgLocations.contains { NSLocationInRange($0, range) }
            }
            var pictureTookSource = [Bool](repeating: false, count: pictureRanges.count)

            for match in sourceMatches {
                // Inside a <picture> that already has a usable <img>, or that
                // already produced a marker from an earlier <source>, this
                // <source> is just another size of the same image.
                let pictureIndex = pictureRanges.firstIndex { NSLocationInRange(match.range.location, $0) }
                if let pictureIndex, pictureHasImg[pictureIndex] || pictureTookSource[pictureIndex] { continue }

                let sourceTag = nsHTML.substring(with: match.range)

                let src = extractAttribute("srcset", from: sourceTag).flatMap(pickLargestFromSrcset)
                    ?? extractAttribute("src", from: sourceTag)

                guard let srcStr = src else { continue }
                let trimmed = srcStr.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }

                let lower = trimmed.lowercased()
                if lower.contains("pixel") || lower.contains("tracking") || lower.contains("beacon") { continue }
                if lower.contains(".svg") { continue }
                if lower.hasPrefix("data:") { continue }

                let resolved: URL?
                if let absolute = URL(string: trimmed), absolute.scheme != nil {
                    resolved = absolute
                } else if let base = baseURL {
                    resolved = URL(string: trimmed, relativeTo: base)
                } else {
                    resolved = nil
                }

                guard let url = resolved,
                      let scheme = url.scheme?.lowercased(),
                      scheme == "http" || scheme == "https"
                else { continue }

                let urlStr = url.absoluteString

                // Already covered by a sibling <img>: skip without a replacement so
                // the existing marker stays positioned at the <img> site.
                if seen[urlStr] != nil { continue }

                seen[urlStr] = markerIndex
                markerMap[markerIndex] = url
                replacements.append((range: match.range, marker: "[[IMG:\(markerIndex)]]"))
                markerIndex += 1
                if let pictureIndex { pictureTookSource[pictureIndex] = true }
            }
        } else {
            logger.error("replaceImgTagsWithMarkers() source regex unavailable; skipping <source> pass")
        }

        // Apply replacements in reverse so offsets stay valid. Source matches may be
        // interleaved with img matches, so sort by location first.
        // A <source> match can sit inside an <img> attribute value (e.g.
        // `<img alt="<source src=x>" src="a.png">`), producing overlapping
        // ranges; replacing both would corrupt offsets. Keep the earliest
        // match and drop anything overlapping the previously kept range.
        let sorted = replacements.sorted { $0.range.location < $1.range.location }
        var kept: [(range: NSRange, marker: String)] = []
        kept.reserveCapacity(sorted.count)
        for replacement in sorted {
            if let last = kept.last, replacement.range.location < NSMaxRange(last.range) {
                continue
            }
            kept.append(replacement)
        }
        var result = html
        for replacement in kept.reversed() {
            guard let swiftRange = Range(replacement.range, in: result) else { continue }
            result.replaceSubrange(swiftRange, with: replacement.marker)
        }

        return (result, markerMap)
    }

    /// Precompiled tag-matching regexes, compiled once instead of per call.
    /// A nil here is a programmer error in the pattern; call sites log loudly
    /// and degrade gracefully instead of silently skipping image handling.
    private static let imgTagRegex: NSRegularExpression? = {
        try? NSRegularExpression(pattern: #"<img\s[^>]*>"#, options: [.caseInsensitive, .dotMatchesLineSeparators])
    }()
    private static let pictureRegex: NSRegularExpression? = {
        try? NSRegularExpression(pattern: #"<picture\b[\s\S]*?</picture\s*>"#, options: [.caseInsensitive])
    }()
    private static let sourceTagRegex: NSRegularExpression? = {
        try? NSRegularExpression(pattern: #"<source\s[^>]*>"#, options: [.caseInsensitive, .dotMatchesLineSeparators])
    }()

    /// Cached regex for marker discovery — `[[IMG:N]]` where N is a non-negative integer.
    private static let markerRegex: NSRegularExpression? = {
        try? NSRegularExpression(pattern: #"\[\[IMG:(\d+)\]\]"#)
    }()

    /// Find every `[[IMG:N]]` marker index present in the given text.
    /// Used to filter the markerMap down to images whose markers survived
    /// Readability's article extraction, so we only download images that
    /// actually appear in the final article body.
    static func findMarkerIndices(in text: String) -> Set<Int> {
        guard let regex = markerRegex else {
            logger.error("findMarkerIndices() regex unavailable; returning empty")
            return []
        }
        let ns = text as NSString
        var indices = Set<Int>()
        regex.enumerateMatches(in: text, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
            guard let match = match, match.numberOfRanges > 1 else { return }
            let captured = ns.substring(with: match.range(at: 1))
            if let n = Int(captured) {
                indices.insert(n)
            }
        }
        logger.debug("findMarkerIndices() text_bytes=\(text.utf8.count, privacy: .public) surviving=\(indices.count, privacy: .public)")
        return indices
    }

    /// Replace `[[IMG:N]]` markers in Markdown with actual image references.
    /// `markerToFilename` maps marker index to the local filename (e.g. "images/abc-1.png").
    /// Returns the processed Markdown and a set of marker indices that were placed inline.
    static func replaceMarkersWithImages(_ markdown: String, markerToPath: [Int: String]) -> (markdown: String, placedIndices: Set<Int>) {
        logger.debug("replaceMarkersWithImages() entered; markdown_bytes=\(markdown.utf8.count, privacy: .public) markerToPath=\(markerToPath.count, privacy: .public)")
        var result = markdown
        var placed = Set<Int>()

        for (index, path) in markerToPath {
            let marker = "[[IMG:\(index)]]"
            if result.contains(marker) {
                let imageRef = "![\(imageAltText(from: path))](\(path))"
                result = result.replacingOccurrences(of: marker, with: imageRef)
                placed.insert(index)
            }
        }

        logger.debug("replaceMarkersWithImages() done; placed=\(placed.count, privacy: .public) unplaced=\(markerToPath.count - placed.count, privacy: .public)")
        return (result, placed)
    }

    private static func imageAltText(from path: String) -> String {
        // Extract filename without extension for alt text
        let filename = (path as NSString).lastPathComponent
        let name = (filename as NSString).deletingPathExtension
        return name
    }

    // MARK: - Image URL extraction from raw HTML

    /// Extract all image source URLs from HTML, including srcset, lazy-load attributes,
    /// and <picture>/<source> elements.
    static func extractImageURLs(from html: String, baseURL: URL?) -> [URL] {
        var seen = Set<String>()
        var urls: [URL] = []

        func addURL(_ src: String) {
            let trimmed = src.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }

            let resolved: URL?
            if let absolute = URL(string: trimmed), absolute.scheme != nil {
                resolved = absolute
            } else if let base = baseURL {
                resolved = URL(string: trimmed, relativeTo: base)
            } else {
                resolved = nil
            }

            if let url = resolved, !seen.contains(url.absoluteString) {
                seen.insert(url.absoluteString)
                urls.append(url)
            }
        }

        let nsHTML = html as NSString
        let fullRange = NSRange(location: 0, length: nsHTML.length)

        // 1. Extract from <img> tags: src, data-src, data-lazy-src, data-original, srcset
        if let imgRegex = Self.imgTagRegex {
            let imgMatches = imgRegex.matches(in: html, range: fullRange)

            for match in imgMatches {
                let imgTag = nsHTML.substring(with: match.range)

                // Standard src
                if let src = extractAttribute("src", from: imgTag) {
                    addURL(src)
                }

                // Lazy-load attributes
                for attr in ["data-src", "data-lazy-src", "data-original"] {
                    if let src = extractAttribute(attr, from: imgTag) {
                        addURL(src)
                    }
                }

                // srcset: pick the largest image
                if let srcset = extractAttribute("srcset", from: imgTag) {
                    if let best = pickLargestFromSrcset(srcset) {
                        addURL(best)
                    }
                }
            }
        }

        // 2. Extract from <source> elements (inside <picture>)
        if let sourceRegex = Self.sourceTagRegex {
            let sourceMatches = sourceRegex.matches(in: html, range: fullRange)

            for match in sourceMatches {
                let sourceTag = nsHTML.substring(with: match.range)

                if let srcset = extractAttribute("srcset", from: sourceTag) {
                    if let best = pickLargestFromSrcset(srcset) {
                        addURL(best)
                    }
                }

                if let src = extractAttribute("src", from: sourceTag) {
                    addURL(src)
                }
            }
        }

        return urls
    }

    /// Cache for compiled attribute-extraction regexes, keyed by attribute name.
    /// Guarded by `attributeRegexCacheLock`: the pipeline runs conversion off
    /// the main actor, so this cache can be touched from any thread.
    private static var attributeRegexCache: [String: NSRegularExpression] = [:]
    private static let attributeRegexCacheLock = NSLock()

    /// Extract a named attribute value from an HTML tag string.
    private static func extractAttribute(_ name: String, from tag: String) -> String? {
        // Match: name="value" or name='value' or name=value
        let regex: NSRegularExpression
        attributeRegexCacheLock.lock()
        if let cached = attributeRegexCache[name] {
            regex = cached
            attributeRegexCacheLock.unlock()
        } else {
            let pattern = name + #"\s*=\s*(?:"([^"]*)"|'([^']*)'|(\S+))"#
            guard let compiled = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
                attributeRegexCacheLock.unlock()
                return nil
            }
            attributeRegexCache[name] = compiled
            attributeRegexCacheLock.unlock()
            regex = compiled
        }

        let nsTag = tag as NSString
        guard let match = regex.firstMatch(in: tag, range: NSRange(location: 0, length: nsTag.length)) else {
            return nil
        }

        // Return whichever capture group matched
        for i in 1...3 {
            if match.range(at: i).location != NSNotFound {
                return nsTag.substring(with: match.range(at: i))
            }
        }
        return nil
    }

    /// Parse a srcset attribute and return the URL with the largest width descriptor.
    /// Supports formats like "url 320w, url 640w" and "url 1x, url 2x".
    private static func pickLargestFromSrcset(_ srcset: String) -> String? {
        let candidates = srcset.components(separatedBy: ",")
        var bestURL: String?
        var bestSize: Double = 0

        for candidate in candidates {
            let parts = candidate.trimmingCharacters(in: .whitespaces)
                .components(separatedBy: .whitespaces)
                .filter { !$0.isEmpty }

            guard let urlPart = parts.first else { continue }

            var size: Double = 1
            if parts.count > 1 {
                let descriptor = parts[1].lowercased()
                if descriptor.hasSuffix("w"), let w = Double(descriptor.dropLast()) {
                    size = w
                } else if descriptor.hasSuffix("x"), let x = Double(descriptor.dropLast()) {
                    size = x * 1000 // Weight x descriptors below w descriptors
                }
            }

            if size > bestSize {
                bestSize = size
                bestURL = urlPart
            }
        }

        return bestURL
    }
}
