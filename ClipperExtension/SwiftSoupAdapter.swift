import Foundation
import SwiftSoup

/// Bridges SwiftSoup's HTML5-conformant parser to the existing `HTMLNode`
/// tree used by `ReadabilityExtractor` and `HTMLToMarkdown`.
///
/// This is the spike-C parser swap: SwiftSoup parses the HTML, then we
/// translate its DOM into the project's bespoke `HTMLNode` so that all
/// downstream scoring and markdown conversion work unchanged.
///
/// Why an adapter rather than a direct migration: `HTMLNode` is the DOM
/// type that the entire Readability pipeline + `HTMLToMarkdown` walks.
/// Replacing it would touch hundreds of lines and conflate the parser-
/// swap with a tree-API rewrite. The adapter localizes the change.
enum SwiftSoupAdapter {

    /// Parse `html` with SwiftSoup, then convert the result into the
    /// project's `HTMLNode` tree. Returns `nil` only if the parse itself
    /// throws (rare — SwiftSoup is tolerant).
    ///
    /// The returned root is an `HTMLNode` element with tag `"document"`,
    /// matching the byte parser's contract. Parent pointers are wired up
    /// before return so `node.parent` works for the rest of the pipeline.
    static func parse(html: String) -> HTMLNode? {
        do {
            let document = try SwiftSoup.parse(html)
            // Walk SwiftSoup's children of <#document> directly so the
            // returned root mirrors the byte parser's `document` element
            // (whose children are <html>, comments, etc., NOT a single
            // wrapper). SwiftSoup's `Document` is an `Element` whose
            // children are typically `<html>`.
            var hitDepthCap = false
            let children = convertChildren(of: document, depth: 0, hitDepthCap: &hitDepthCap)
            let root = HTMLNode(
                kind: .element(tag: "document", attributes: []),
                children: children
            )
            setParents(root, depth: 0)
            if hitDepthCap {
                dismantle(document)
            }
            return root
        } catch {
            return nil
        }
    }

    // MARK: - Conversion

    /// `depth` is the nesting depth of `node`. Past `HTMLNode.maxDepth` we
    /// silently stop descending (the subtree is dropped) so pathological
    /// nesting can't overflow the stack in this or any downstream walker.
    private static func convertChildren(of node: Node, depth: Int, hitDepthCap: inout Bool) -> [HTMLNode] {
        guard depth < HTMLNode.maxDepth else {
            if !node.getChildNodes().isEmpty { hitDepthCap = true }
            return []
        }
        var result: [HTMLNode] = []
        result.reserveCapacity(node.getChildNodes().count)
        for child in node.getChildNodes() {
            if let converted = convert(node: child, depth: depth + 1, hitDepthCap: &hitDepthCap) {
                result.append(converted)
            }
        }
        return result
    }

    /// Convert a single SwiftSoup `Node`. Returns `nil` for node types we
    /// don't surface (Comment, DocumentType, XmlDeclaration) — the existing
    /// byte parser drops these as well.
    private static func convert(node: Node, depth: Int, hitDepthCap: inout Bool) -> HTMLNode? {
        if let element = node as? Element {
            // Skip the synthetic `#root` if it ever appears as a child;
            // its children are what we want.
            let tag = element.tagNameNormal() // already lowercased
            let attrs: [(name: String, value: String)] = {
                guard let attributes = element.getAttributes() else { return [] }
                var out: [(name: String, value: String)] = []
                out.reserveCapacity(attributes.size())
                for attr in attributes {
                    out.append((name: attr.getKey().lowercased(), value: attr.getValue()))
                }
                return out
            }()

            let children = convertChildren(of: element, depth: depth, hitDepthCap: &hitDepthCap)
            return HTMLNode(
                kind: .element(tag: tag, attributes: attrs),
                children: children
            )
        }

        if let text = node as? TextNode {
            // `getWholeText()` returns the raw text exactly as it sits in
            // the DOM (entity-decoded by SwiftSoup, whitespace preserved).
            // The shipped pipeline collapses whitespace at render time
            // (see `HTMLToMarkdown.collapseWhitespace`), so we mirror the
            // byte parser's behavior of handing off raw text here.
            return HTMLNode(kind: .text(text.getWholeText()))
        }

        if let data = node as? DataNode {
            // `<script>` / `<style>` raw-text content. The byte parser
            // attaches a single child text node containing the raw body;
            // we preserve that shape so anything that walks `<script>`
            // children (rare, but present in a few tests) sees the same
            // structure.
            return HTMLNode(kind: .text(data.getWholeData()))
        }

        // Comments, doctypes, XML declarations: drop them, matching the
        // byte parser's `skipComment`/`skipDeclaration` behavior.
        return nil
    }

    /// SwiftSoup releases its DOM recursively (each element's deinit releases
    /// its children), which overflows the stack on pathologically deep pages
    /// even though parsing itself is iterative. Detach every node from its
    /// parent iteratively first, so each node's eventual deinit is shallow.
    /// Only run when the depth cap was hit — normal pages skip the cost.
    ///
    /// Top-down, last-child-first: by the time a node's children are removed
    /// the node itself is already detached, so SwiftSoup's ancestor-walking
    /// dirty-marking stays O(1) per removal and the whole pass is linear.
    private static func dismantle(_ root: Node) {
        var detached: [Node] = []
        var queue: [Node] = [root]
        while let node = queue.popLast() {
            let children = node.getChildNodes()
            for child in children.reversed() {
                try? child.remove()
            }
            queue.append(contentsOf: children)
            detached.append(contentsOf: children)
        }
        // `detached` holds every node, each now childless and parentless;
        // releasing it frees them one at a time with no recursion.
    }

    /// Wire up parent pointers across the converted tree. `HTMLNode.parent`
    /// is `weak`, so this is the standard one-shot post-build pass.
    private static func setParents(_ node: HTMLNode, depth: Int) {
        guard depth < HTMLNode.maxDepth else { return }
        for child in node.children {
            child.parent = node
            setParents(child, depth: depth + 1)
        }
    }
}
