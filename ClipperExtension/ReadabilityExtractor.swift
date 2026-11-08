import Foundation

// MARK: - Result Type

/// The result of Readability extraction, containing the cleaned article content
/// and metadata extracted from the page.
struct ReadabilityResult: Sendable {
    let articleNode: HTMLNode
    let title: String?
    let excerpt: String?
    let siteName: String?
}

// MARK: - Readability Extractor

/// A Mozilla Readability-inspired article extractor that isolates the main content
/// from a web page's HTML by scoring block-level elements and selecting the most
/// likely article container.
///
/// Implemented in pure Swift with no external dependencies. The HTML parser is a
/// minimal recursive-descent parser — not spec-compliant, but robust enough for
/// real-world pages.
enum ReadabilityExtractor {

    /// Extract the main article content from raw HTML.
    /// - Parameters:
    ///   - html: The full raw HTML of the page.
    ///   - url: The page URL (used for resolving relative links if needed).
    /// - Returns: A `ReadabilityResult` with the cleaned article HTML, or `nil`
    ///   if extraction fails.
    static func extract(html: String, url: URL?) -> ReadabilityResult? {
        // Spike C: route through SwiftSoup. The adapter produces the same
        // HTMLNode tree shape the rest of the pipeline expects, so all
        // downstream scoring and post-processing work unchanged.
        guard let document = SwiftSoupAdapter.parse(html: html) else { return nil }

        // Extract metadata before preprocessing mutates the tree
        let metadata = extractMetadata(from: document)

        // Preprocess: remove junk elements
        preprocess(&document.children)

        // Score candidates
        var candidates: [CandidateScore] = []
        scoreCandidates(node: document, candidates: &candidates)

        // Re-apply link-density penalty at the *aggregated* level. The per-element
        // scoreElement penalty is applied to each candidate in isolation, but it
        // doesn't account for the fact that many candidates get their score
        // propagated from high-link-density children (e.g. a grid of 9 related-
        // article summary cards on a news page). Without this, the accumulated
        // score of a "list of cards" container can easily exceed the actual
        // article body -- see the Wired ArticlePageChunks layout, where body is
        // split into 4 BodyWrapper chunks and the sidebar recirc widget wins.
        guard let winner = candidates.max(by: { c1, c2 in
            effectiveScore(c1) < effectiveScore(c2)
        }), winner.score > 0 else {
            return nil
        }

        // Post-process: clean up the winning subtree
        postProcess(winner.element)

        // Extract title: prefer og:title, then <h1> within article, then <title> tag
        let title = metadata.ogTitle
            ?? findFirstHeading(in: winner.element)
            ?? metadata.title

        // Extract excerpt: first paragraph text or meta description
        let excerpt = metadata.description
            ?? findFirstParagraphText(in: winner.element)

        let siteName = metadata.siteName

        // Detach the winner from its parent so the rest of the document tree
        // can be ARC-released once `document` goes out of scope. `parent` is a
        // weak reference, so we just null it out here; the winner's subtree
        // is the only thing the caller needs.
        winner.element.parent = nil

        return ReadabilityResult(
            articleNode: winner.element,
            title: title,
            excerpt: excerpt,
            siteName: siteName
        )
    }
}

// MARK: - Lightweight DOM

/// A node in the parsed HTML tree. Uses a class (reference type) so that parent
/// pointers and in-place mutation during scoring work naturally. The tree is built
/// once and discarded after extraction, so ARC overhead is minimal.
///
/// `@unchecked Sendable`: the tree is built synchronously by `HTMLParser.parse()`,
/// all mutation (preprocess, postProcess) completes on the same actor before the
/// tree is handed off for scoring, and the `_cachedTextContent` field is only
/// written during sequential tree traversal. No cross-actor concurrent mutation occurs.
final class HTMLNode: @unchecked Sendable {
    enum Kind {
        case element(tag: String, attributes: [(name: String, value: String)])
        case text(String)
    }

    /// Maximum element nesting depth any tree builder or recursive walker
    /// descends to. Real pages rarely exceed ~50; adversarial or broken pages
    /// can nest thousands deep and overflow the (small, secondary-thread)
    /// stack. Builders silently flatten/stop past this; walkers stop descending.
    static let maxDepth = 512

    var kind: Kind
    var children: [HTMLNode]
    weak var parent: HTMLNode?

    /// Memoized result of `textContent`. Cleared via `invalidateTextContentCache()`
    /// whenever descendant structure mutates.
    private var _cachedTextContent: String?

    init(kind: Kind, children: [HTMLNode] = []) {
        self.kind = kind
        self.children = children
    }

    var tag: String? {
        if case .element(let tag, _) = kind { return tag }
        return nil
    }

    var attributes: [(name: String, value: String)] {
        if case .element(_, let attrs) = kind { return attrs }
        return []
    }

    func attribute(_ name: String) -> String? {
        attributes.first(where: { $0.name.lowercased() == name.lowercased() })?.value
    }

    /// Concatenated text content of this node and all descendants.
    ///
    /// Caching strategy (Story 4.4): the first read memoizes the result in
    /// `_cachedTextContent`. Mutation sites in `preprocess`/`postProcess` call
    /// `invalidateTextContentCache()` on the mutated parent, which walks up the
    /// parent chain clearing caches so stale descendant sums never get returned.
    var textContent: String {
        textContent(depth: 0)
    }

    private func textContent(depth: Int) -> String {
        if let cached = _cachedTextContent { return cached }
        let computed: String
        switch kind {
        case .text(let t): computed = t
        case .element:
            guard depth < Self.maxDepth else { return "" }
            computed = children.map { $0.textContent(depth: depth + 1) }.joined()
        }
        _cachedTextContent = computed
        return computed
    }

    /// Clear the cached `textContent` on this node and every ancestor, since an
    /// ancestor's cached value depends on this node's descendants.
    func invalidateTextContentCache() {
        var node: HTMLNode? = self
        while let n = node {
            n._cachedTextContent = nil
            node = n.parent
        }
    }

    /// Serialize this node (and descendants) back to an HTML string.
    func serialize() -> String {
        serialize(depth: 0)
    }

    private func serialize(depth: Int) -> String {
        switch kind {
        case .text(let t):
            return t
        case .element(let tag, let attrs):
            let attrStr = attrs.map { " \($0.name)=\"\(escapeAttribute($0.value))\"" }.joined()
            let inner = depth < Self.maxDepth
                ? children.map { $0.serialize(depth: depth + 1) }.joined()
                : ""
            if HTMLParser.selfClosingTags.contains(tag) {
                return "<\(tag)\(attrStr) />"
            }
            return "<\(tag)\(attrStr)>\(inner)</\(tag)>"
        }
    }
}

private func escapeAttribute(_ value: String) -> String {
    value.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "\"", with: "&quot;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
}

// MARK: - HTML Parser

/// Minimal recursive-descent HTML parser. Produces an `HTMLNode` tree.
/// Not spec-compliant — handles the common patterns found on real web pages.
struct HTMLParser {

    static let selfClosingTags: Set<String> = [
        "area", "base", "br", "col", "embed", "hr", "img", "input",
        "link", "meta", "param", "source", "track", "wbr"
    ]

    /// Tags whose content is raw text (not parsed as HTML).
    private static let rawTextTags: Set<String> = [
        "script", "style", "textarea", "title", "noscript"
    ]

    /// Tags that implicitly close certain open tags.
    private static let implicitCloseRules: [String: Set<String>] = [
        "p": ["p", "div", "section", "article", "aside", "nav", "header",
              "footer", "ul", "ol", "table", "blockquote", "form", "h1",
              "h2", "h3", "h4", "h5", "h6", "pre", "hr"],
        "li": ["li"],
        "dt": ["dt", "dd"],
        "dd": ["dt", "dd"],
        "tr": ["tr"],
        "td": ["td", "th"],
        "th": ["td", "th"],
        "option": ["option"],
    ]

    // UTF-8 byte-buffer backing store. Replaces the previous `String.Index`
    // traversal, which was slow on multi-byte UTF-8 content (CJK pages) and
    // allocated a new `String` per `peekString` call. Byte-level iteration is
    // safe for the tokens we care about because HTML delimiters, tag names,
    // and attribute names are ASCII per spec. UTF-8 is only decoded into a
    // `String` at text-node/attribute-value emission sites.
    private let bytes: ContiguousArray<UInt8>
    private var offset: Int
    private let endOffset: Int

    // Frequently compared ASCII literals — cached as byte arrays so hot-path
    // `peekString`/`consume` calls don't re-allocate on each invocation.
    private static let openCommentBytes: [UInt8] = Array("<!--".utf8)
    private static let closeCommentBytes: [UInt8] = Array("-->".utf8)
    private static let openCDATABytes: [UInt8] = Array("<![CDATA[".utf8)
    private static let closeCDATABytes: [UInt8] = Array("]]>".utf8)
    private static let openDeclBytes: [UInt8] = Array("<!".utf8)
    private static let openPIBytes: [UInt8] = Array("<?".utf8)
    private static let openCloseTagBytes: [UInt8] = Array("</".utf8)

    init(html: String) {
        self.bytes = ContiguousArray(html.utf8)
        self.offset = 0
        self.endOffset = self.bytes.count
    }

    mutating func parse() -> HTMLNode? {
        let children = parseNodes(until: nil)
        let root = HTMLNode(kind: .element(tag: "document", attributes: []), children: children)
        setParents(root, depth: 0)
        return root
    }

    // MARK: - ASCII Helpers

    /// Lower-case an ASCII byte. Bytes outside A-Z are returned unchanged.
    /// HTML tag and attribute names are ASCII per spec, so this is safe for
    /// case-insensitive tag/attribute matching.
    @inline(__always) private static func asciiLower(_ b: UInt8) -> UInt8 {
        (b >= 0x41 && b <= 0x5A) ? b &+ 0x20 : b
    }

    /// HTML whitespace is limited to ASCII space, tab, LF, CR, FF. Any
    /// multi-byte UTF-8 character has all continuation bytes ≥ 0x80, so a
    /// byte-level check is safe inside tokens (between `<`/`>` delimiters).
    @inline(__always) private static func isASCIIWhitespace(_ b: UInt8) -> Bool {
        b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D || b == 0x0C
    }

    @inline(__always) private static func isASCIILetter(_ b: UInt8) -> Bool {
        (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A)
    }

    @inline(__always) private static func isASCIIDigit(_ b: UInt8) -> Bool {
        b >= 0x30 && b <= 0x39
    }

    @inline(__always) private static func isTagNameByte(_ b: UInt8) -> Bool {
        isASCIILetter(b) || isASCIIDigit(b) || b == 0x2D /* - */ || b == 0x5F /* _ */ || b == 0x3A /* : */
    }

    // MARK: - Core Parsing

    private mutating func parseNodes(until closingTag: String?) -> [HTMLNode] {
        var nodes: [HTMLNode] = []
        while offset < endOffset {
            // Check for closing tag
            if let closing = closingTag, peekClosingTag(closing) {
                break
            }

            if peek() == UInt8(ascii: "<") {
                if peekBytes(Self.openCommentBytes) {
                    skipComment()
                } else if peekBytes(Self.openCDATABytes) {
                    skipCDATA()
                } else if peekBytes(Self.openDeclBytes) || peekBytes(Self.openPIBytes) {
                    skipDeclaration()
                } else if peekBytes(Self.openCloseTagBytes) {
                    // Unexpected closing tag — if we're in an implicit-close context,
                    // let the caller handle it; otherwise skip it.
                    if closingTag != nil {
                        break
                    }
                    skipToAfter(UInt8(ascii: ">"))
                } else {
                    if let element = parseElement(parentClosingTag: closingTag, depth: 1) {
                        nodes.append(element)
                    }
                }
            } else {
                let text = parseText()
                if !text.isEmpty {
                    nodes.append(HTMLNode(kind: .text(text)))
                }
            }
        }
        return nodes
    }

    /// `depth` is this element's nesting depth. Past `HTMLNode.maxDepth` the
    /// element is emitted childless and its content is parsed as siblings by
    /// the caller's loop (flattening), which bounds recursion.
    private mutating func parseElement(parentClosingTag: String?, depth: Int) -> HTMLNode? {
        guard consume(UInt8(ascii: "<")) else { return nil }

        let tag = parseTagName()
        guard !tag.isEmpty else {
            // Malformed tag — skip to >
            skipToAfter(UInt8(ascii: ">"))
            return nil
        }

        let attrs = parseAttributes()

        // Check for self-closing /> or self-closing tag
        let selfClose = consume(UInt8(ascii: "/"))
        consume(UInt8(ascii: ">"))

        if Self.selfClosingTags.contains(tag) || selfClose {
            return HTMLNode(kind: .element(tag: tag, attributes: attrs))
        }

        // Raw text elements: read until matching closing tag
        if Self.rawTextTags.contains(tag) {
            let content = readUntilClosingTag(tag)
            let textNode = HTMLNode(kind: .text(content))
            return HTMLNode(kind: .element(tag: tag, attributes: attrs), children: [textNode])
        }

        guard depth < HTMLNode.maxDepth else {
            return HTMLNode(kind: .element(tag: tag, attributes: attrs))
        }

        // Parse children
        let children = parseChildren(tag: tag, parentClosingTag: parentClosingTag, depth: depth)
        return HTMLNode(kind: .element(tag: tag, attributes: attrs), children: children)
    }

    private mutating func parseChildren(tag: String, parentClosingTag: String?, depth: Int) -> [HTMLNode] {
        var children: [HTMLNode] = []

        while offset < endOffset {
            // Check for our own closing tag
            if peekClosingTag(tag) {
                consumeClosingTag(tag)
                break
            }

            // Check if parent's closing tag terminates us (implicit close)
            if let parent = parentClosingTag, peekClosingTag(parent) {
                break
            }

            // Check for implicit closing rules
            if let openTag = peekOpenTag(),
               let closers = Self.implicitCloseRules[tag],
               closers.contains(openTag) {
                // This opening tag implicitly closes us
                break
            }

            if peek() == UInt8(ascii: "<") {
                if peekBytes(Self.openCommentBytes) {
                    skipComment()
                } else if peekBytes(Self.openCDATABytes) {
                    skipCDATA()
                } else if peekBytes(Self.openDeclBytes) || peekBytes(Self.openPIBytes) {
                    skipDeclaration()
                } else if peekBytes(Self.openCloseTagBytes) {
                    // A closing tag that doesn't match us — might be for an ancestor.
                    // Let the ancestor handle it.
                    break
                } else {
                    if let element = parseElement(parentClosingTag: tag, depth: depth + 1) {
                        children.append(element)
                    }
                }
            } else {
                let text = parseText()
                if !text.isEmpty {
                    children.append(HTMLNode(kind: .text(text)))
                }
            }
        }

        return children
    }

    // MARK: - Tag/Attribute Parsing

    /// Parse an ASCII tag name, lowercased. Returns an empty string if no
    /// valid tag-name byte is present. Operates entirely on bytes — no
    /// intermediate `String` allocation.
    private mutating func parseTagName() -> String {
        let start = offset
        while offset < endOffset, Self.isTagNameByte(bytes[offset]) {
            offset &+= 1
        }
        guard offset > start else { return "" }
        // Tag names are ASCII; lowercase in-place into a small buffer.
        var lower = [UInt8]()
        lower.reserveCapacity(offset - start)
        for i in start..<offset {
            lower.append(Self.asciiLower(bytes[i]))
        }
        return String(decoding: lower, as: UTF8.self)
    }

    private mutating func parseAttributes() -> [(name: String, value: String)] {
        var attrs: [(name: String, value: String)] = []

        while offset < endOffset {
            skipWhitespace()
            guard offset < endOffset else { break }

            let b = bytes[offset]
            if b == UInt8(ascii: ">") || b == UInt8(ascii: "/") { break }

            let name = parseAttributeName()
            guard !name.isEmpty else {
                // Skip unknown byte
                offset &+= 1
                continue
            }

            skipWhitespace()

            var value = ""
            if offset < endOffset && bytes[offset] == UInt8(ascii: "=") {
                offset &+= 1
                skipWhitespace()
                value = parseAttributeValue()
            }

            attrs.append((name: name, value: decodeEntities(value)))
        }

        return attrs
    }

    /// Parse an attribute name. HTML attribute names are ASCII in practice;
    /// any byte ≥ 0x80 (UTF-8 lead/continuation) falls outside the stopping
    /// set (`=`, `>`, `/`, whitespace) and will be included verbatim in the
    /// range, which matches the previous Character-based behavior.
    private mutating func parseAttributeName() -> String {
        let start = offset
        while offset < endOffset {
            let b = bytes[offset]
            if b == UInt8(ascii: "=") || b == UInt8(ascii: ">") || b == UInt8(ascii: "/") || Self.isASCIIWhitespace(b) {
                break
            }
            offset &+= 1
        }
        guard offset > start else { return "" }
        // Lowercase the ASCII byte range. Non-ASCII bytes (≥ 0x80) pass
        // through asciiLower unchanged and are emitted as-is; String(decoding:)
        // reassembles them into valid UTF-8 scalars.
        var lower = [UInt8]()
        lower.reserveCapacity(offset - start)
        for i in start..<offset {
            lower.append(Self.asciiLower(bytes[i]))
        }
        return String(decoding: lower, as: UTF8.self)
    }

    /// Parse an attribute value. Quoted values may contain UTF-8 — the byte
    /// range is decoded to a `String` once at the end, not during scanning.
    private mutating func parseAttributeValue() -> String {
        guard offset < endOffset else { return "" }

        let quote = bytes[offset]
        if quote == UInt8(ascii: "\"") || quote == UInt8(ascii: "'") {
            offset &+= 1
            let start = offset
            while offset < endOffset && bytes[offset] != quote {
                offset &+= 1
            }
            let end = offset
            if offset < endOffset { offset &+= 1 } // consume closing quote
            return String(decoding: bytes[start..<end], as: UTF8.self)
        }

        // Unquoted value
        let start = offset
        while offset < endOffset {
            let b = bytes[offset]
            if Self.isASCIIWhitespace(b) || b == UInt8(ascii: ">") || b == UInt8(ascii: "/") { break }
            offset &+= 1
        }
        return String(decoding: bytes[start..<offset], as: UTF8.self)
    }

    // MARK: - Text Parsing

    /// Scan text until the next `<` and decode the byte range into a `String`
    /// once at the end. Text nodes may contain UTF-8 multi-byte sequences, but
    /// `<` (0x3C) cannot appear inside a UTF-8 continuation byte (all of which
    /// are ≥ 0x80), so byte scanning is safe here.
    private mutating func parseText() -> String {
        let start = offset
        while offset < endOffset && bytes[offset] != UInt8(ascii: "<") {
            offset &+= 1
        }
        if offset == start { return "" }
        let raw = String(decoding: bytes[start..<offset], as: UTF8.self)
        return decodeEntities(raw)
    }

    // MARK: - Skip Helpers

    private mutating func skipComment() {
        guard consume(UInt8(ascii: "<")) else { return }
        guard consume(UInt8(ascii: "!")) else { return }
        guard consume(UInt8(ascii: "-")) else { skipToAfter(UInt8(ascii: ">")); return }
        guard consume(UInt8(ascii: "-")) else { skipToAfter(UInt8(ascii: ">")); return }

        // Find -->
        while offset < endOffset {
            if peekBytes(Self.closeCommentBytes) {
                offset = min(offset &+ 3, endOffset)
                return
            }
            offset &+= 1
        }
    }

    private mutating func skipCDATA() {
        // Skip past ]]>
        while offset < endOffset {
            if peekBytes(Self.closeCDATABytes) {
                offset = min(offset &+ 3, endOffset)
                return
            }
            offset &+= 1
        }
    }

    private mutating func skipDeclaration() {
        skipToAfter(UInt8(ascii: ">"))
    }

    private mutating func skipToAfter(_ b: UInt8) {
        while offset < endOffset {
            if bytes[offset] == b {
                offset &+= 1
                return
            }
            offset &+= 1
        }
    }

    private mutating func skipWhitespace() {
        while offset < endOffset && Self.isASCIIWhitespace(bytes[offset]) {
            offset &+= 1
        }
    }

    // MARK: - Peek / Consume Helpers

    /// Peek the current byte without advancing. Returns `nil` at EOF.
    private func peek() -> UInt8? {
        guard offset < endOffset else { return nil }
        return bytes[offset]
    }

    /// Case-insensitive ASCII comparison of the upcoming bytes against the
    /// given target byte array. No allocation — the target is expected to be
    /// a precomputed static `[UInt8]` (see the `*Bytes` constants above).
    private func peekBytes(_ target: [UInt8]) -> Bool {
        let n = target.count
        guard endOffset &- offset >= n else { return false }
        for i in 0..<n {
            if Self.asciiLower(bytes[offset &+ i]) != Self.asciiLower(target[i]) {
                return false
            }
        }
        return true
    }

    /// Case-insensitive ASCII comparison for a `String` literal. Accepts any
    /// `String` but materializes its UTF-8 once up-front; for hot paths use
    /// one of the cached `*Bytes` constants with `peekBytes(_:)`.
    func peekString(_ s: String) -> Bool {
        var target = [UInt8]()
        target.reserveCapacity(s.utf8.count)
        for b in s.utf8 { target.append(b) }
        return peekBytes(target)
    }

    @discardableResult
    private mutating func consume(_ b: UInt8) -> Bool {
        guard offset < endOffset && bytes[offset] == b else { return false }
        offset &+= 1
        return true
    }

    @discardableResult
    private mutating func consumeBytes(_ target: [UInt8]) -> Bool {
        guard peekBytes(target) else { return false }
        offset = min(offset &+ target.count, endOffset)
        return true
    }

    /// Peek for a case-insensitive `</tag` sequence followed by a non-tag-name
    /// byte (or EOF). Operates on bytes directly, lowercasing each byte on the
    /// fly — no `String` allocation.
    private func peekClosingTag(_ tag: String) -> Bool {
        guard peekBytes(Self.openCloseTagBytes) else { return false }
        var i = offset &+ 2
        // Skip whitespace (HTML allows `</ tag>` — rare but tolerated)
        while i < endOffset && Self.isASCIIWhitespace(bytes[i]) { i &+= 1 }

        // Compare tag name bytes case-insensitively against `tag.utf8`.
        var tagIter = tag.utf8.makeIterator()
        while let expected = tagIter.next() {
            guard i < endOffset else { return false }
            let actual = bytes[i]
            if !Self.isTagNameByte(actual) { return false }
            if Self.asciiLower(actual) != Self.asciiLower(expected) { return false }
            i &+= 1
        }
        // The next byte must NOT be part of a tag name (else it's a longer tag
        // that merely starts with `tag`).
        if i < endOffset && Self.isTagNameByte(bytes[i]) { return false }
        return true
    }

    private mutating func consumeClosingTag(_ tag: String) {
        guard consumeBytes(Self.openCloseTagBytes) else { return }
        skipWhitespace()
        _ = parseTagName()
        skipWhitespace()
        consume(UInt8(ascii: ">"))
    }

    /// Peek the tag name that would start at the current offset, if this is
    /// an opening tag (`<letter...`). Returns `nil` for closing tags, text,
    /// or EOF. Lowercased.
    private func peekOpenTag() -> String? {
        guard offset < endOffset, bytes[offset] == UInt8(ascii: "<") else { return nil }
        let next = offset &+ 1
        guard next < endOffset, bytes[next] != UInt8(ascii: "/") else { return nil }
        guard Self.isASCIILetter(bytes[next]) else { return nil }

        var i = next
        while i < endOffset, Self.isTagNameByte(bytes[i]) {
            i &+= 1
        }
        // Lowercase the ASCII range.
        var lower = [UInt8]()
        lower.reserveCapacity(i - next)
        for j in next..<i {
            lower.append(Self.asciiLower(bytes[j]))
        }
        return String(decoding: lower, as: UTF8.self)
    }

    /// Read raw-text content (inside `<script>`, `<style>`, etc.) until the
    /// matching closing tag. Captures a byte range and decodes to `String`
    /// once at the end — no per-byte String appending.
    private mutating func readUntilClosingTag(_ tag: String) -> String {
        let start = offset
        while offset < endOffset {
            if peekClosingTag(tag) {
                let end = offset
                consumeClosingTag(tag)
                return String(decoding: bytes[start..<end], as: UTF8.self)
            }
            offset &+= 1
        }
        return String(decoding: bytes[start..<offset], as: UTF8.self)
    }

    private func setParents(_ node: HTMLNode, depth: Int) {
        guard depth < HTMLNode.maxDepth else { return }
        for child in node.children {
            child.parent = node
            setParents(child, depth: depth + 1)
        }
    }
}

// MARK: - HTML Entity Decoding

private func decodeEntities(_ text: String) -> String {
    guard text.contains("&") else { return text }

    var result = ""
    result.reserveCapacity(text.count)
    var i = text.startIndex

    while i < text.endIndex {
        if text[i] == "&" {
            let remaining = text[i...]
            if let semicolonIdx = remaining.firstIndex(of: ";"),
               text.distance(from: i, to: semicolonIdx) <= 10 {
                let entity = String(text[i...semicolonIdx])
                if let decoded = decodeEntity(entity) {
                    result.append(decoded)
                    i = text.index(after: semicolonIdx)
                    continue
                }
            }
        }
        result.append(text[i])
        i = text.index(after: i)
    }
    return result
}

private let entityMap: [String: Character] = [
    "&amp;": "&",
    "&lt;": "<",
    "&gt;": ">",
    "&quot;": "\"",
    "&apos;": "'",
    "&nbsp;": "\u{00A0}",
    "&ndash;": "\u{2013}",
    "&mdash;": "\u{2014}",
    "&lsquo;": "\u{2018}",
    "&rsquo;": "\u{2019}",
    "&ldquo;": "\u{201C}",
    "&rdquo;": "\u{201D}",
    "&bull;": "\u{2022}",
    "&hellip;": "\u{2026}",
    "&copy;": "\u{00A9}",
    "&reg;": "\u{00AE}",
    "&trade;": "\u{2122}",
]

private func decodeEntity(_ entity: String) -> Character? {
    if let char = entityMap[entity] {
        return char
    }
    // Numeric entities: &#123; or &#x1F;
    if entity.hasPrefix("&#x") || entity.hasPrefix("&#X") {
        let hex = String(entity.dropFirst(3).dropLast())
        if let code = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(code) {
            return Character(scalar)
        }
    } else if entity.hasPrefix("&#") {
        let dec = String(entity.dropFirst(2).dropLast())
        if let code = UInt32(dec), let scalar = Unicode.Scalar(code) {
            return Character(scalar)
        }
    }
    return nil
}

// MARK: - Metadata Extraction

private struct PageMetadata {
    var title: String?
    var ogTitle: String?
    var description: String?
    var siteName: String?
}

private extension ReadabilityExtractor {

    static func extractMetadata(from document: HTMLNode) -> PageMetadata {
        var meta = PageMetadata()

        visitNodes(document) { node in
            guard case .element(let tag, _) = node.kind else { return }

            switch tag {
            case "title":
                if meta.title == nil {
                    let raw = node.textContent.trimmingCharacters(in: .whitespacesAndNewlines)
                    meta.title = cleanTitle(raw)
                }
            case "meta":
                let property = node.attribute("property")?.lowercased()
                    ?? node.attribute("name")?.lowercased()
                let content = node.attribute("content")

                switch property {
                case "og:title":
                    meta.ogTitle = content
                case "og:site_name":
                    meta.siteName = content
                case "description", "og:description":
                    if meta.description == nil {
                        meta.description = content
                    }
                default:
                    break
                }
            default:
                break
            }
        }

        return meta
    }

    /// Clean a <title> tag value: strip site name suffixes like " | Site Name" or " - Site Name"
    static func cleanTitle(_ raw: String) -> String {
        let separators: [String] = [" | ", " - ", " – ", " — ", " :: ", " : "]
        for sep in separators {
            let parts = raw.components(separatedBy: sep)
            if parts.count >= 2 {
                // The title is usually the longest segment, or the first one
                let first = parts[0].trimmingCharacters(in: .whitespaces)
                let last = parts[parts.count - 1].trimmingCharacters(in: .whitespaces)
                // Use the longer one — the actual title is usually longer than the site name
                if first.count >= last.count && !first.isEmpty {
                    return first
                }
                return last
            }
        }
        return raw
    }

    static func visitNodes(_ node: HTMLNode, _ visitor: (HTMLNode) -> Void) {
        visitor(node)
        for child in node.children {
            visitNodes(child, visitor)
        }
    }
}

// MARK: - Preprocessing

private extension ReadabilityExtractor {

    /// Tags that are always junk and should be removed entirely.
    static let removableTags: Set<String> = [
        "script", "style", "noscript", "nav", "footer", "header",
        "iframe", "object", "embed", "applet", "form"
    ]

    static func preprocess(_ children: inout [HTMLNode]) {
        children.removeAll { node in
            guard case .element(let tag, _) = node.kind else { return false }

            // Remove known junk tags
            if removableTags.contains(tag) { return true }

            // Remove hidden elements
            if isHidden(node) { return true }

            return false
        }

        for child in children {
            if case .element = child.kind {
                preprocess(&child.children)
            }
        }

        // Collapse <br><br> chains into implicit paragraph breaks
        collapseBRChains(&children)
    }

    static func isHidden(_ node: HTMLNode) -> Bool {
        if let style = node.attribute("style")?.lowercased() {
            if style.contains("display:none") || style.contains("display: none") {
                return true
            }
            if style.contains("visibility:hidden") || style.contains("visibility: hidden") {
                return true
            }
        }
        if node.attribute("aria-hidden")?.lowercased() == "true" {
            return true
        }
        if node.attribute("hidden") != nil {
            return true
        }
        return false
    }

    /// Replace sequences of 2+ <br> tags with a paragraph break.
    static func collapseBRChains(_ children: inout [HTMLNode]) {
        var i = 0
        while i < children.count {
            if children[i].tag == "br" {
                // Count consecutive <br> tags (possibly with whitespace-only text nodes between)
                var j = i + 1
                var brCount = 1
                while j < children.count {
                    if children[j].tag == "br" {
                        brCount += 1
                        j += 1
                    } else if case .text(let t) = children[j].kind,
                              t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        j += 1
                    } else {
                        break
                    }
                }
                if brCount >= 2 {
                    // Replace the chain with a double newline text node
                    children.replaceSubrange(i..<j, with: [HTMLNode(kind: .text("\n\n"))])
                }
            }
            i += 1
        }
    }
}

// MARK: - Candidate Scoring

private struct CandidateScore {
    let element: HTMLNode
    var score: Double
}

private extension ReadabilityExtractor {

    /// Block-level tags that are candidates for article containers.
    static let candidateTags: Set<String> = [
        "div", "section", "article", "td", "pre", "blockquote",
        "main", "aside", "details", "figure"
    ]

    /// Positive class/id name patterns.
    static let positivePatterns: [String] = [
        "article", "body", "content", "post", "text", "story",
        "entry", "main", "blog", "page"
    ]

    /// Negative class/id name patterns.
    static let negativePatterns: [String] = [
        "comment", "nav", "sidebar", "footer", "header", "menu",
        "ad", "social", "share", "related", "widget", "promo",
        "sponsor", "popup", "modal", "banner", "cookie", "consent"
    ]

    /// Final score used at winner-selection time. Re-applies the link-density
    /// penalty against the *aggregated* score so containers that accumulated
    /// most of their points from link-heavy children (related-article grids,
    /// tag clouds, navigation lists) can't beat genuine article bodies.
    static func effectiveScore(_ c: CandidateScore) -> Double {
        let d = computeLinkDensity(c.element)
        // Clamp density so a single stray link doesn't zero us out, and a
        // pathological 100%-link container is still strongly penalized.
        let linkDamping = max(0.05, 1.0 - d)

        // Recirc card grids on news sites (Wired, Federal News Network)
        // pattern: `<a><h3>title</h3></a><p>dek</p>` repeated per card.
        // Real article bodies have unlinked section headings ("The AI
        // imperative", "Background", etc.). When most headings inside a
        // candidate are link-wrapped, treat it as a card grid and damp
        // the aggregated score.
        let (linked, total) = countLinkedHeadings(c.element)
        let headingDamping: Double
        if total >= 3 {
            let ratio = Double(linked) / Double(total)
            if ratio > 0.5 {
                // Floor at 0.2 so a borderline article body with a few
                // cross-reference linked headings (round-up posts) stays
                // viable rather than being effectively zeroed out.
                headingDamping = max(0.2, 1.0 - ratio)
            } else {
                headingDamping = 1.0
            }
        } else {
            headingDamping = 1.0
        }

        return c.score * linkDamping * headingDamping
    }

    /// Count `<h1>-<h6>` descendants of `element`, recording how many sit
    /// under an `<a>` ancestor (within `element`'s subtree). Used by
    /// `effectiveScore` to detect recirc card grids.
    static func countLinkedHeadings(_ element: HTMLNode) -> (linked: Int, total: Int) {
        var linked = 0
        var total = 0
        walkHeadings(element, insideLink: false, linked: &linked, total: &total)
        return (linked, total)
    }

    private static let headingTags: Set<String> = ["h1", "h2", "h3", "h4", "h5", "h6"]

    private static func walkHeadings(_ node: HTMLNode, insideLink: Bool, linked: inout Int, total: inout Int) {
        let isLink = node.tag == "a"
        if let tag = node.tag, headingTags.contains(tag) {
            total += 1
            if insideLink { linked += 1 }
        }
        for child in node.children {
            walkHeadings(child, insideLink: insideLink || isLink, linked: &linked, total: &total)
        }
    }

    static func scoreCandidates(node: HTMLNode, candidates: inout [CandidateScore]) {
        guard case .element(let tag, _) = node.kind else { return }

        if candidateTags.contains(tag) {
            let score = scoreElement(node, tag: tag)
            if score > 0 {
                candidates.append(CandidateScore(element: node, score: score))

                // Propagate score upward
                if let parent = node.parent, parent.tag != "document" {
                    if let parentIdx = candidates.firstIndex(where: { $0.element === node.parent }) {
                        candidates[parentIdx].score += score
                    } else {
                        candidates.append(CandidateScore(element: parent, score: score))
                    }

                    // Grandparent gets half
                    if let grandparent = parent.parent, grandparent.tag != "document" {
                        if let gpIdx = candidates.firstIndex(where: { $0.element === grandparent }) {
                            candidates[gpIdx].score += score / 2
                        } else {
                            candidates.append(CandidateScore(element: grandparent, score: score / 2))
                        }
                    }
                }
            }
        }

        for child in node.children {
            scoreCandidates(node: child, candidates: &candidates)
        }
    }

    static func scoreElement(_ element: HTMLNode, tag: String) -> Double {
        let text = element.textContent
        let textLength = text.filter { !$0.isWhitespace }.count

        // Skip elements with very little text
        guard textLength > 25 else { return 0 }

        var score: Double = 0

        // Base score from content length
        score += min(Double(textLength) / 100.0, 3.0)

        // Paragraph count
        let pCount = countDescendants(element, tag: "p")
        score += Double(pCount)

        // Comma count (prose heuristic)
        let commaCount = text.filter { $0 == "," }.count
        score += Double(commaCount)

        // Link density penalty
        let linkDensity = computeLinkDensity(element)
        score *= (1.0 - linkDensity)

        // Tag-based bonuses
        switch tag {
        case "article": score += 20
        case "section": score += 5
        case "div": score += 5
        case "main": score += 15
        case "aside": score -= 10
        case "blockquote": score += 3
        default: break
        }

        // ID/class-based bonuses. Match on word boundaries so that short
        // negative patterns like "ad" don't false-match real article body
        // classes like `readmore_available` or `lead-in-text-callout`. The
        // word-boundary helper is shared with `postProcess`.
        let idClass = ((element.attribute("id") ?? "") + " " +
                       (element.attribute("class") ?? "")).lowercased()

        for pattern in positivePatterns {
            if containsWholeWord(idClass, pattern: pattern) {
                score += 25
                break
            }
        }

        for pattern in negativePatterns {
            if containsWholeWord(idClass, pattern: pattern) {
                score -= 25
                break
            }
        }

        return score
    }

    static func computeLinkDensity(_ element: HTMLNode) -> Double {
        let totalText = element.textContent
        let totalLen = Double(totalText.filter { !$0.isWhitespace }.count)
        guard totalLen > 0 else { return 0 }

        var linkLen: Double = 0
        collectLinkText(element, linkLen: &linkLen)

        return linkLen / totalLen
    }

    static func collectLinkText(_ node: HTMLNode, linkLen: inout Double) {
        if node.tag == "a" {
            let text = node.textContent.filter { !$0.isWhitespace }
            linkLen += Double(text.count)
            return // Don't recurse into links
        }
        for child in node.children {
            collectLinkText(child, linkLen: &linkLen)
        }
    }

    static func countDescendants(_ node: HTMLNode, tag: String) -> Int {
        var count = 0
        for child in node.children {
            if child.tag == tag { count += 1 }
            count += countDescendants(child, tag: tag)
        }
        return count
    }
}

// MARK: - Post-processing

private extension ReadabilityExtractor {

    /// Inline phrasing tags whose content is paragraph text, not a removable block.
    /// Post-processing must never strip these — doing so chews holes in sentences
    /// (e.g. an `<a>` inside a `<p>` has link density 1.0 but is part of the prose).
    static let inlineTags: Set<String> = [
        "a", "span", "em", "strong", "b", "i", "u", "s", "del", "strike",
        "code", "mark", "sub", "sup", "cite", "abbr", "time", "var",
        "small", "big", "q", "kbd", "samp", "ruby", "rt", "rp", "wbr",
        "font", "bdi", "bdo", "dfn", "ins"
    ]

    /// Inline-content containers whose descendants are prose, not sub-blocks.
    /// Recursing post-processing into these risks shredding the paragraph text
    /// (e.g. stripping inline links out of a paragraph).
    static let inlineContentContainers: Set<String> = [
        "p", "h1", "h2", "h3", "h4", "h5", "h6",
        "li", "dt", "dd", "figcaption", "blockquote", "pre", "code", "summary"
    ]

    static func postProcess(_ element: HTMLNode) {
        // Never strip inline-content containers' descendants — their children
        // are prose, not removable blocks.
        if let tag = element.tag, inlineContentContainers.contains(tag) {
            removeEmptyChildren(element)
            return
        }

        // Remove high-link-density children — but only *block-level* children.
        // Inline tags (<a>, <span>, <em>, ...) live inside paragraphs and must
        // not be removed here; they're part of the prose.
        let before = element.children.count
        element.children.removeAll { child in
            guard let tag = child.tag else { return false }

            // Skip inline tags entirely — they belong to the enclosing paragraph.
            if inlineTags.contains(tag) { return false }

            let density = computeLinkDensity(child)
            let text = child.textContent.trimmingCharacters(in: .whitespacesAndNewlines)

            // Remove if it's a short block that's mostly links
            if density > 0.5 && text.count < 200 { return true }

            // Remove known non-content tags that might still be inside
            if ["aside", "nav", "footer", "header"].contains(tag) { return true }

            // Remove by class/id, matching on word boundaries so that short
            // patterns like "ad" don't false-match "lead-in-text-callout" etc.
            let idClass = ((child.attribute("id") ?? "") + " " +
                           (child.attribute("class") ?? "")).lowercased()
            for pattern in negativePatterns {
                if containsWholeWord(idClass, pattern: pattern) && text.count < 300 {
                    return true
                }
            }

            return false
        }
        if element.children.count != before {
            element.invalidateTextContentCache()
        }

        // Recurse. Each recursive call may mutate descendants and invalidate
        // their caches up to (and including) `element` itself.
        for child in element.children {
            if child.tag != nil {
                postProcess(child)
            }
        }

        removeEmptyChildren(element)
    }

    /// Drop element children that collapsed to empty after post-processing —
    /// e.g. a wrapper div whose only child was a removed widget.
    static func removeEmptyChildren(_ element: HTMLNode) {
        let before = element.children.count
        element.children.removeAll { child in
            guard let tag = child.tag else { return false }
            if HTMLParser.selfClosingTags.contains(tag) { return false }
            if tag == "br" || tag == "hr" { return false }
            return child.children.isEmpty &&
                   child.textContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        if element.children.count != before {
            element.invalidateTextContentCache()
        }
    }

    /// Case-insensitive "whole word" check against id/class text. A word is a
    /// run of `[a-z0-9]`; separators are anything else (whitespace, `-`, `_`,
    /// `:`, etc.). This avoids the classic false-positive where `"ad"` matches
    /// every class that happens to contain the letters `a` and `d` in order
    /// (like `lead`, `shadow`, `headline`, `gradient`).
    static func containsWholeWord(_ haystack: String, pattern: String) -> Bool {
        guard !pattern.isEmpty else { return false }
        let h = Array(haystack.unicodeScalars)
        let p = Array(pattern.unicodeScalars)
        if h.count < p.count { return false }
        var i = 0
        while i <= h.count - p.count {
            // Match p at position i, with word boundaries on both sides.
            var match = true
            for j in 0..<p.count where h[i &+ j] != p[j] {
                match = false
                break
            }
            if match {
                let leftOK = (i == 0) || !isWordChar(h[i &- 1])
                let rightEnd = i &+ p.count
                let rightOK = (rightEnd == h.count) || !isWordChar(h[rightEnd])
                if leftOK && rightOK { return true }
            }
            i &+= 1
        }
        return false
    }

    static func isWordChar(_ scalar: Unicode.Scalar) -> Bool {
        let v = scalar.value
        return (v >= 0x30 && v <= 0x39) /* 0-9 */
            || (v >= 0x61 && v <= 0x7A) /* a-z (haystack is lowercased) */
            || (v >= 0x41 && v <= 0x5A) /* A-Z (defensive) */
    }
}

// MARK: - Content Extraction Helpers

private extension ReadabilityExtractor {

    static func findFirstHeading(in node: HTMLNode) -> String? {
        for child in node.children {
            if let tag = child.tag, ["h1", "h2"].contains(tag) {
                let text = child.textContent.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { return text }
            }
            if let found = findFirstHeading(in: child) {
                return found
            }
        }
        return nil
    }

    static func findFirstParagraphText(in node: HTMLNode) -> String? {
        for child in node.children {
            if child.tag == "p" {
                let text = child.textContent.trimmingCharacters(in: .whitespacesAndNewlines)
                if text.count >= 50 { return String(text.prefix(300)) }
            }
            if let found = findFirstParagraphText(in: child) {
                return found
            }
        }
        return nil
    }
}
