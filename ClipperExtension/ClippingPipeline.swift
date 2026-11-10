import Foundation
import CryptoKit
import os

// MARK: - Errors

/// Errors thrown by the clipping pipeline. Co-located with the pipeline so
/// the test target can compile the pipeline + its errors without dragging
/// in `ShareViewController` (which transitively requires SwiftUICore link
/// access that test bundles don't have).
enum ClipError: LocalizedError {
    case noContent
    case fetchFailed(String)
    case cancelled
    case paywalled
    case thinContent

    var errorDescription: String? {
        switch self {
        case .noContent:
            return "Could not extract content from the shared item. Try sharing a URL, text, or image."
        case .fetchFailed(let detail):
            return "Couldn't fetch the page — \(detail) Try opening it in Safari and sharing from there."
        case .cancelled:
            return "Clipping was cancelled."
        case .paywalled:
            return "This looks like a paywall or login wall — only a preview was captured. Log in under Settings → Site Logins in the Markdown Clipper app, or open the page in Safari and share from there."
        case .thinContent:
            return "Couldn't extract meaningful content from this page. Try opening it in Safari and sharing from there."
        }
    }
}

/// Pure-pipeline entry point for the share extension's clipping flow.
///
/// Why this is a free enum and not a method on `ShareViewController`:
/// `ShareViewController` owns a `ShareViewModel` whose `@Observable` macro
/// transitively pulls in SwiftUI/SwiftUICore type metadata. That's fine in
/// production but causes the test bundle to fail at link time with
/// "cannot link directly with 'SwiftUICore' because product being built is
/// not an allowed client of it" whenever a test references the VC. Lifting
/// the pipeline to a UI-free type keeps the harness tests linkable.
///
/// Production callers (`ShareViewController.performClipping`) supply the
/// real `extensionContext` plus closures that update the view model and
/// retain the active `ImageProcessor` for cancel/cleanup. Tests supply a
/// `FakeExtensionContext` and ignore the closures — they care about the
/// pipeline output (a `.md` file in the configured vault), not the
/// progress UI.
///
/// Isolation: `run` orchestrates on the main actor (settings, share-sheet
/// input, progress callbacks), but every CPU/IO-heavy stage — JSON-LD
/// parsing, marker injection, Readability, Markdown conversion, the quality
/// gate, and the vault write — runs off the main thread via `offMain`, one
/// awaited hop per stage, with `Task.checkCancellation()` between stages.
@MainActor
enum ClippingPipeline {

    private nonisolated static let logger = Logger(subsystem: "com.mmtac.md-clipper", category: "pipeline")

    /// Cap on HTML handed to marker injection / Readability / conversion.
    /// Bounds every parse path regardless of the share source.
    nonisolated static let maxPipelineHTMLBytes = 1_536 * 1024 // 1.5 MB

    /// Stack size for the worker threads that run parse/convert stages.
    /// Secondary threads default to 512 KB; the recursive tree builders and
    /// walkers are depth-capped at `HTMLNode.maxDepth`, and this headroom
    /// keeps that cap comfortably safe (including SwiftSoup's own recursive
    /// teardown of very deep DOMs).
    private nonisolated static let workerStackSize = 16 * 1024 * 1024

    /// Run `work` on a dedicated large-stack thread and await its result.
    /// Cancellation is checked before and after: an in-flight stage runs to
    /// completion (stages are bounded), then the next check throws.
    nonisolated static func offMain<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try Task.checkCancellation()
        let value: T = try await withCheckedThrowingContinuation { continuation in
            let thread = Thread {
                do {
                    continuation.resume(returning: try work())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            thread.stackSize = workerStackSize
            thread.qualityOfService = .userInitiated
            thread.name = "com.mmtac.md-clipper.pipeline"
            thread.start()
        }
        try Task.checkCancellation()
        return value
    }

    /// Output of the HTML → Markdown extraction stages.
    private struct Extraction: Sendable {
        var markdownBody: String
        var markerMap: [Int: URL]
        var route: String
        var title: String?
    }

    /// Run the full extraction → markdown → save flow.
    ///
    /// - Parameters:
    ///   - extensionContext: the share-sheet input. Production passes
    ///     `self.extensionContext`; tests pass a `FakeExtensionContext`.
    ///   - onState: progress callback. Production binds to
    ///     `viewModel.state = .loading(_:)`. Tests typically pass `nil`.
    ///   - onImageProcessor: invoked when the pipeline allocates an
    ///     `ImageProcessor`, so a UI host can hold the reference for
    ///     cancellation/cleanup. Tests typically pass `nil`.
    /// - Returns: the article title (used by the VC for the success label).
    /// - Throws: `ClipError.noContent` when the share input is empty;
    ///   `FileSaver.SaveError` when the vault write fails;
    ///   `CancellationError` when the surrounding Task is cancelled.
    static func run(
        extensionContext: NSExtensionContext?,
        onState: ((String) -> Void)? = nil,
        onImageProcessor: ((ImageProcessor?) -> Void)? = nil
    ) async throws -> String {
        let settings = ClipperSettings()
        let saveConfig = FileSaver.SaveConfig(from: settings)
        let clipStart = Date()

        onState?("Extracting content…")

        guard let context = extensionContext,
              let rawContent = await WebContentExtractor.extract(from: context) else {
            throw ClipError.noContent
        }

        try Task.checkCancellation()

        // When an explicitly-shared URL's fetch failed, the page is what the user
        // wanted and we don't have it. Any accompanying plain text is share-sheet
        // metadata (a title, a snippet, the URL itself) — not the article — so
        // surface the named cause instead of silently writing a stub note.
        //
        // Two cases still proceed: shares that carry their own images, and URLs
        // merely *detected* inside a larger plain-text share (urlFromPlainText) —
        // there the text is the payload worth keeping even if the link won't fetch.
        if rawContent.html == nil,
           let fetchError = rawContent.fetchErrorDescription,
           rawContent.sharedImages.isEmpty,
           !rawContent.urlFromPlainText {
            recordDiagnostics(rawContent, route: "none", markdownBody: "", outcome: "fetchFailed", since: clipStart)
            throw ClipError.fetchFailed(fetchError)
        }

        let isImageOnly = rawContent.html == nil
            && rawContent.url == nil
            && !rawContent.sharedImages.isEmpty

        var articleTitle = rawContent.title
        var markdownBody: String
        var markerMap: [Int: URL] = [:]
        var extractionRoute = "none"

        if isImageOnly {
            onState?("Processing images…")
            markdownBody = ""
            extractionRoute = "imageOnly"
        } else if let html = rawContent.html {
            onState?("Extracting article…")
            let extraction = try await extractMarkdown(html: html, baseURL: rawContent.url)
            markdownBody = extraction.markdownBody
            markerMap = extraction.markerMap
            extractionRoute = extraction.route
            if let title = extraction.title, !title.isEmpty {
                articleTitle = title
            }
        } else if let plain = rawContent.plainText {
            onState?("Saving text…")
            markdownBody = plain
            extractionRoute = "plainText"
        } else {
            markdownBody = ""
        }

        try Task.checkCancellation()

        // Quality gate: a URL-backed clip whose extraction produced almost
        // nothing is a failed capture (paywall shell, login wall, consent
        // page). Surface a named error and write nothing — never a stub note.
        // Image-only clips and text-primary shares are exempt: their payload
        // isn't the page.
        if !isImageOnly,
           rawContent.url != nil,
           !rawContent.urlFromPlainText,
           let html = rawContent.html {
            let body = markdownBody
            let verdict = try await offMain { ContentQualityGate.evaluate(markdown: body, html: html) }
            switch verdict {
            case .pass:
                break
            case .paywalled:
                recordDiagnostics(rawContent, route: extractionRoute, markdownBody: markdownBody, outcome: "paywalled", since: clipStart)
                throw ClipError.paywalled
            case .thinContent:
                recordDiagnostics(rawContent, route: extractionRoute, markdownBody: markdownBody, outcome: "thinContent", since: clipStart)
                throw ClipError.thinContent
            }
        }

        var images: [ExtractedImage] = []
        let prefix = Self.shortHash(title: rawContent.title, url: rawContent.url)

        if isImageOnly {
            onState?("Running OCR…")
            let processor = ImageProcessor()
            onImageProcessor?(processor)
            images = await processor.processSharedImages(
                rawContent.sharedImages,
                enableOCR: settings.enableOCR,
                prefix: prefix
            )
        } else if settings.saveImages, rawContent.html != nil {
            onState?("Processing images…")

            let surviving = HTMLToMarkdown.findMarkerIndices(in: markdownBody)
            let filteredMarkerMap = markerMap.filter { surviving.contains($0.key) }
            let limitedURLs = Array(filteredMarkerMap.values.prefix(20))
            logger.debug("image-block: markerMap=\(markerMap.count, privacy: .public) surviving=\(surviving.count, privacy: .public) filtered=\(filteredMarkerMap.count, privacy: .public) limited(<=20)=\(limitedURLs.count, privacy: .public)")

            let processor = ImageProcessor()
            onImageProcessor?(processor)
            images = await processor.process(urls: limitedURLs, enableOCR: settings.enableOCR, prefix: prefix)

            var urlToPath: [String: String] = [:]
            for image in images {
                urlToPath[image.sourceURL.absoluteString] = "images/\(image.filename)"
            }

            var markerToPath: [Int: String] = [:]
            for (index, url) in filteredMarkerMap {
                if let path = urlToPath[url.absoluteString] {
                    markerToPath[index] = path
                }
            }
            logger.debug("image-block: downloaded=\(images.count, privacy: .public) urlToPath=\(urlToPath.count, privacy: .public) markerToPath=\(markerToPath.count, privacy: .public)")
            let inlineResult = HTMLToMarkdown.replaceMarkersWithImages(markdownBody, markerToPath: markerToPath)
            markdownBody = inlineResult.markdown
        } else if settings.saveImages {
            logger.debug("image-block: SKIPPED (saveImages=true but no html)")
        } else {
            logger.debug("image-block: SKIPPED (saveImages=false)")
        }

        try Task.checkCancellation()

        let clipResult = ClipResult(
            title: articleTitle,
            sourceURL: rawContent.url,
            markdownBody: markdownBody,
            images: images,
            clippedDate: Date()
        )

        onState?("Saving to vault…")
        // Last cancellation point: once the write starts it runs to
        // completion so a cancel can't leave a half-written note.
        try Task.checkCancellation()
        _ = try await offMain { try FileSaver.save(clipResult, config: saveConfig) }

        recordDiagnostics(rawContent, route: extractionRoute, markdownBody: markdownBody, outcome: "saved", since: clipStart)

        // Note: the caller is responsible for cleaning up the
        // `ImageProcessor` it received via `onImageProcessor`. Production
        // (`ShareViewController`) does this in `done()` / `cancel()`.

        // Return the title the note was actually saved under (JSON-LD
        // headline / Readability title may have replaced the share title).
        return articleTitle
    }

    /// HTML → Markdown: JSON-LD fast path, else marker injection →
    /// Readability → conversion (falling back to full-page conversion when
    /// Readability yields too little). Each stage runs off the main actor.
    private nonisolated static func extractMarkdown(html: String, baseURL: URL?) async throws -> Extraction {
        if let ld = try await offMain({ JSONLDExtractor.tryFastPath(html: html) }) {
            logger.debug("JSON-LD fast path HIT; isHTML=\(ld.articleBodyIsHTML, privacy: .public) body_len=\(ld.articleBody.count, privacy: .public) imageURLs=\(ld.imageURLs.count, privacy: .public)")
            return try await offMain {
                // JSON-LD decides which paragraphs are the article; for
                // plain-text bodies the page DOM supplies links, subheads and
                // any opening paragraph the structured data omits. HTML bodies
                // pass straight through. The publisher-declared lead image is
                // injected as a marker so the downloader treats it like any
                // inline image.
                let output = JSONLDRenderer.render(ld, pageHTML: html, baseURL: baseURL,
                                                   maxBytes: maxPipelineHTMLBytes)
                logger.debug("JSON-LD path: markerMap=\(output.markerMap.count, privacy: .public) markdown_len=\(output.markdown.count, privacy: .public)")
                return Extraction(
                    markdownBody: output.markdown,
                    markerMap: output.markerMap,
                    route: "jsonld",
                    title: ld.title.isEmpty ? nil : ld.title
                )
            }
        }

        logger.debug("JSON-LD fast path MISS; falling through to Readability")
        let markerResult = try await offMain {
            let bounded = HTMLToMarkdown.truncateUTF8(html, maxBytes: maxPipelineHTMLBytes)
            return HTMLToMarkdown.replaceImgTagsWithMarkers(bounded, baseURL: baseURL)
        }
        let markedHTML = markerResult.html

        return try await offMain {
            if let result = ReadabilityExtractor.extract(html: markedHTML, url: baseURL) {
                let candidate = HTMLToMarkdown.convert(node: result.articleNode)
                if candidate.filter({ !$0.isWhitespace }).count >= 100 {
                    return Extraction(markdownBody: MarkdownCleanup.trimBoilerplate(candidate),
                                      markerMap: markerResult.markerMap,
                                      route: "readability", title: result.title)
                }
            }
            return Extraction(markdownBody: MarkdownCleanup.trimBoilerplate(HTMLToMarkdown.convert(markedHTML)),
                              markerMap: markerResult.markerMap, route: "fullPage", title: nil)
        }
    }

    // MARK: - Helpers

    private static func recordDiagnostics(
        _ rawContent: WebContentExtractor.RawContent,
        route: String,
        markdownBody: String,
        outcome: String,
        since start: Date
    ) {
        ClipDiagnostics.record(ClipRecord(
            date: Date(),
            host: rawContent.url?.host,
            source: rawContent.captureSource,
            htmlChars: rawContent.html?.count,
            route: route,
            markdownChars: markdownBody.filter { !$0.isWhitespace }.count,
            outcome: outcome,
            elapsedMs: Int(Date().timeIntervalSince(start) * 1000)
        ))
    }

    /// Short hex hash identifying a single clip; used as an image filename
    /// prefix so two clips with the same inferred indices do not overwrite
    /// each other.
    private static func shortHash(title: String, url: URL?) -> String {
        let seed = "\(title)|\(url?.absoluteString ?? "")|\(Date().timeIntervalSince1970)"
        let digest = SHA256.hash(data: Data(seed.utf8))
        return digest.prefix(4).map { String(format: "%02x", $0) }.joined()
    }
}
