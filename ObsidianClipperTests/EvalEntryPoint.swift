import Foundation
@testable import ClipperExtension

/// Eval harness extraction adapter.
///
/// On `main` (post-merge of B + C): JSON-LD fast path runs first; on miss,
/// falls through to the shipped Readability pipeline which now uses the
/// SwiftSoup parser underneath. Output goes to `eval/main/`.
enum EvalEntryPoint {

    struct EvalResult {
        let title: String
        let markdown: String
        let imageMarkerCount: Int?
        let approach: String
    }

    /// Identifier used for eval-output directory naming.
    static let approachName: String = "main"

    static func extract(html: String, baseURL: URL?) -> EvalResult {
        // 1. JSON-LD fast path — short-circuit when the publisher has
        //    embedded the article body as Schema.org structured data.
        if let ld = JSONLDExtractor.tryFastPath(html: html) {
            let output = JSONLDRenderer.render(ld, pageHTML: html, baseURL: baseURL,
                                               maxBytes: ClippingPipeline.maxPipelineHTMLBytes)
            return EvalResult(
                title: ld.title,
                markdown: output.markdown,
                imageMarkerCount: HTMLToMarkdown.findMarkerIndices(in: output.markdown).count,
                approach: approachName
            )
        }

        // 2. Fallback — identical to master pipeline.
        let markerResult = HTMLToMarkdown.replaceImgTagsWithMarkers(html, baseURL: baseURL)
        let markedHTML = markerResult.html
        let readability = ReadabilityExtractor.extract(html: markedHTML, url: baseURL)

        let title: String
        let markdown: String

        if let r = readability {
            let candidate = HTMLToMarkdown.convert(node: r.articleNode)
            if candidate.filter({ !$0.isWhitespace }).count >= 100 {
                markdown = candidate
                title = r.title ?? ""
            } else {
                markdown = HTMLToMarkdown.convert(markedHTML)
                title = r.title ?? ""
            }
        } else {
            markdown = HTMLToMarkdown.convert(markedHTML)
            title = ""
        }

        let cleaned = MarkdownCleanup.trimBoilerplate(markdown)
        return EvalResult(
            title: title,
            markdown: cleaned,
            imageMarkerCount: HTMLToMarkdown.findMarkerIndices(in: cleaned).count,
            approach: approachName
        )
    }
}
