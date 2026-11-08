import Foundation
import ImageIO
import os
import Vision

/// Downloads images from URLs and performs OCR using Apple's Vision framework.
actor ImageProcessor {

    private static let logger = Logger(subsystem: "com.mmtac.md-clipper", category: "image")

    /// Concurrent in-flight downloads+OCR. Share extensions have a ~50MB RAM
    /// budget and Vision `.accurate` allocates 2–5MB per image; keep this low.
    /// Instance-level (not static) so `reduceConcurrency()` can lower it in
    /// response to a system memory warning without affecting other instances.
    var maxConcurrent = 3

    /// Count of tasks added to the current `withTaskGroup` but not yet drained.
    /// Used to gate refill/seed loops against `maxConcurrent` at runtime so that
    /// a mid-flight memory warning immediately throttles new task creation.
    private var inFlightCount = 0

    /// Lower the concurrency cap to 1. Called from `ShareViewController` when
    /// the system posts `UIApplication.didReceiveMemoryWarningNotification`.
    /// Already-running tasks continue to completion; only *new* tasks seeded
    /// after this call are gated. Idempotent.
    func reduceConcurrency() {
        maxConcurrent = 1
    }

    /// Longest edge (in pixels) before downscaling prior to OCR.
    static let maxOCRDimension = 2048

    /// Minimum fraction of image area that recognized text must cover for
    /// the OCR result to be kept. Below this, the text is judged
    /// incidental — name placards, store signs, license plates in
    /// photos — and discarded. Vision returns bounding boxes in
    /// normalized coordinates so summing `width*height` per observation
    /// yields a coverage fraction directly. Overlapping boxes slightly
    /// over-count, biasing the filter toward keeping borderline cases.
    private static let textCoverageThreshold: CGFloat = 0.10

    /// Hard ceiling on a single Vision OCR request. Vision has no timeout of its
    /// own; a hung request would otherwise hang the whole clip.
    private static let ocrTimeoutSeconds: TimeInterval = 30

    /// Maximum cumulative bytes of image data downloaded per clip. Protects the
    /// extension's ~120MB memory budget from pathological pages with huge images.
    private static let maxCumulativeImageBytes = 50 * 1024 * 1024

    /// Test-only override. When non-nil, takes precedence over `maxCumulativeImageBytes`
    /// so unit tests can exercise cap behavior without downloading tens of MB.
    static var testMaxCumulativeImageBytesOverride: Int? = nil

    private static var effectiveMaxCumulativeBytes: Int {
        testMaxCumulativeImageBytesOverride ?? maxCumulativeImageBytes
    }

    /// Running total of accepted image bytes for this clip.
    private var totalBytesDownloaded: Int = 0

    /// Scratch directory where downloaded / shared image temp files live.
    /// One directory per `ImageProcessor` instance. `cleanup()` removes it wholesale.
    let scratchDirectory: URL

    init() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipper-\(UUID().uuidString)", isDirectory: true)
        self.scratchDirectory = dir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    /// Remove the scratch directory and any temp files within it.
    /// Safe to call multiple times; missing directory is not an error.
    func cleanup() {
        try? FileManager.default.removeItem(at: scratchDirectory)
    }

    /// URLSession configured with a 15-second resource timeout for image downloads.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForResource = 15
        config.timeoutIntervalForRequest = 10
        return URLSession(configuration: config)
    }()

    /// Returns true if the URL uses a scheme safe to fetch over the network.
    /// Rejects file://, javascript:, ftp:, data:, etc. to avoid SSRF / local-file reads.
    static func isFetchableScheme(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    /// Returns true if accepting `bytes` more data keeps the clip under the cumulative cap.
    /// Also rejects any single payload that on its own exceeds the cap.
    func shouldAcceptImageSize(_ bytes: Int) -> Bool {
        let cap = Self.effectiveMaxCumulativeBytes
        if bytes > cap { return false }
        return totalBytesDownloaded + bytes <= cap
    }

    /// Download images from the given URLs and optionally run OCR on each.
    /// `prefix` becomes part of each saved filename to avoid collisions across clips.
    func process(urls: [URL], enableOCR: Bool, prefix: String) async -> [ExtractedImage] {
        Self.logger.debug("process() entered; urls=\(urls.count, privacy: .public) enableOCR=\(enableOCR, privacy: .public) maxConcurrent=\(self.maxConcurrent, privacy: .public)")
        totalBytesDownloaded = 0
        inFlightCount = 0
        let result = await withTaskGroup(of: ExtractedImage?.self) { group in
            var iterator = urls.enumerated().makeIterator()

            // Seed the group up to the current concurrency cap.
            while inFlightCount < maxConcurrent, let (index, url) = iterator.next() {
                inFlightCount += 1
                group.addTask {
                    await self.downloadAndProcess(url: url, index: index, prefix: prefix, enableOCR: enableOCR)
                }
            }

            // Drain results and refill as slots free up — but re-check the cap
            // each iteration so a memory warning mid-flight (which lowers
            // `maxConcurrent` to 1) pauses refills until in-flight drops below.
            var results: [ExtractedImage] = []
            while let result = await group.next() {
                inFlightCount -= 1
                if Task.isCancelled { break }
                if let image = result {
                    results.append(image)
                }
                if inFlightCount < maxConcurrent, let (index, url) = iterator.next() {
                    inFlightCount += 1
                    group.addTask {
                        await self.downloadAndProcess(url: url, index: index, prefix: prefix, enableOCR: enableOCR)
                    }
                }
            }
            return results.sorted { $0.filename < $1.filename }
        }
        Self.logger.debug("process() done; kept=\(result.count, privacy: .public) totalBytes=\(self.totalBytesDownloaded, privacy: .public)")
        return result
    }

    /// Process images shared directly (e.g. from Photos, Screenshots) — no download needed.
    /// Runs OCR if enabled and returns ExtractedImage results.
    /// Uses the same concurrency cap as `process()` to stay within the extension memory budget.
    func processSharedImages(_ imageDataList: [Data], enableOCR: Bool, prefix: String) async -> [ExtractedImage] {
        Self.logger.debug("processSharedImages() entered; count=\(imageDataList.count, privacy: .public) enableOCR=\(enableOCR, privacy: .public)")
        totalBytesDownloaded = 0
        inFlightCount = 0
        // Limit to 10 shared images to stay within the 50MB extension budget
        let limited = Array(imageDataList.prefix(10))

        return await withTaskGroup(of: ExtractedImage?.self) { group in
            var iterator = limited.enumerated().makeIterator()

            // Seed the group up to the current concurrency cap.
            while inFlightCount < maxConcurrent, let (index, data) = iterator.next() {
                inFlightCount += 1
                group.addTask {
                    await self.processSharedImage(data: data, index: index, prefix: prefix, enableOCR: enableOCR)
                }
            }

            // Drain results and refill as slots free up — re-checking the cap
            // each iteration so a mid-flight memory warning throttles new work.
            var results: [ExtractedImage] = []
            while let result = await group.next() {
                inFlightCount -= 1
                if let image = result {
                    results.append(image)
                }
                if inFlightCount < maxConcurrent, let (index, data) = iterator.next() {
                    inFlightCount += 1
                    group.addTask {
                        await self.processSharedImage(data: data, index: index, prefix: prefix, enableOCR: enableOCR)
                    }
                }
            }
            return results.sorted { $0.filename < $1.filename }
        }
    }

    private func processSharedImage(data: Data, index: Int, prefix: String, enableOCR: Bool) async -> ExtractedImage? {
        guard !Task.isCancelled else { return nil }

        // Enforce cumulative size cap. Oversized singles and cap-exceeders are dropped.
        guard shouldAcceptImageSize(data.count) else { return nil }
        totalBytesDownloaded += data.count

        // Determine filename based on header bytes, then stream the data to disk
        // BEFORE running OCR so the original `Data` blob can be freed from the
        // per-task autoreleasepool rather than lingering inside `ExtractedImage`.
        let ext = Self.imageExtension(from: data)
        let filename = "\(prefix)-\(index + 1).\(ext)"
        let destURL = scratchDirectory.appendingPathComponent(filename)

        do {
            try data.write(to: destURL)
        } catch {
            return nil
        }

        // Validate the data is a decodable image and optionally get a downscaled
        // CGImage for OCR. ImageIO thumbnailing decodes straight to the target
        // size, never materializing the full-resolution bitmap.
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              Self.isDecodable(source) else {
            try? FileManager.default.removeItem(at: destURL)
            return nil
        }
        let cgForOCR: CGImage? = enableOCR ? Self.thumbnail(from: source) : nil

        let ocrText: String?
        if let cg = cgForOCR {
            ocrText = await recognizeText(in: cg)
        } else {
            ocrText = nil
        }

        let sourceURL = URL(string: "shared-image://\(filename)") ?? destURL

        return ExtractedImage(
            sourceURL: sourceURL,
            tempFileURL: destURL,
            filename: filename,
            ocrText: ocrText
        )
    }

    /// Determine image format from data header bytes.
    static func imageExtension(from data: Data) -> String {
        guard data.count >= 4 else { return "png" }
        let bytes = [UInt8](data.prefix(4))
        // PNG: 89 50 4E 47
        if bytes[0] == 0x89 && bytes[1] == 0x50 && bytes[2] == 0x4E && bytes[3] == 0x47 {
            return "png"
        }
        // JPEG: FF D8 FF
        if bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF {
            return "jpg"
        }
        // GIF: 47 49 46
        if bytes[0] == 0x47 && bytes[1] == 0x49 && bytes[2] == 0x46 {
            return "gif"
        }
        // WebP: starts with RIFF...WEBP
        if bytes[0] == 0x52 && bytes[1] == 0x49 && bytes[2] == 0x46 && bytes[3] == 0x46 {
            return "webp"
        }
        return "png"
    }

    private func downloadAndProcess(url: URL, index: Int, prefix: String, enableOCR: Bool) async -> ExtractedImage? {
        guard !Task.isCancelled else {
            Self.logger.debug("download[\(index, privacy: .public)] cancelled before start; url=\(url.absoluteString, privacy: .private)")
            return nil
        }

        // Only fetch over http(s). Blocks file://, javascript:, ftp:, data:, etc.
        guard Self.isFetchableScheme(url) else {
            Self.logger.info("download[\(index, privacy: .public)] scheme rejected; url=\(url.absoluteString, privacy: .private)")
            return nil
        }

        Self.logger.debug("download[\(index, privacy: .public)] GET \(url.absoluteString, privacy: .private)")

        // Stream the download straight to a system temp file. This keeps the image
        // bytes out of RAM — only the filesystem URL + URLResponse are held here.
        guard let (downloadedURL, response) = try? await Self.session.download(from: url) else {
            Self.logger.info("download[\(index, privacy: .public)] FAILED (network/timeout); url=\(url.absoluteString, privacy: .private)")
            return nil
        }
        let httpStatus = (response as? HTTPURLResponse)?.statusCode ?? -1
        let loggedMime = (response as? HTTPURLResponse)?.mimeType ?? response.mimeType ?? "nil"
        Self.logger.debug("download[\(index, privacy: .public)] status=\(httpStatus, privacy: .public) mime=\(loggedMime, privacy: .public)")

        guard !Task.isCancelled else {
            try? FileManager.default.removeItem(at: downloadedURL)
            return nil
        }

        // Determine file extension and filename (prefixed to avoid collisions).
        let mimeType = (response as? HTTPURLResponse)?.mimeType ?? response.mimeType
        let ext = fileExtension(for: url, mimeType: mimeType)
        let filename = "\(prefix)-\(index + 1).\(ext)"

        // Move the system temp file into our scratch directory so we control its
        // lifetime (and can clean it up on cancel). Use move-or-copy to survive
        // cross-volume moves, though in practice both dirs live on the same volume.
        let fm = FileManager.default
        let destURL = scratchDirectory.appendingPathComponent(filename)
        // Remove any stale file at the destination (paranoia; should never exist).
        try? fm.removeItem(at: destURL)
        do {
            try fm.moveItem(at: downloadedURL, to: destURL)
        } catch {
            // Fall back to copy then remove; treat total failure as a skip.
            do {
                try fm.copyItem(at: downloadedURL, to: destURL)
                try? fm.removeItem(at: downloadedURL)
            } catch {
                try? fm.removeItem(at: downloadedURL)
                return nil
            }
        }

        // Read the on-disk size for the cumulative cap check. If the cap is
        // exceeded, delete the file and return nil so smaller later images can
        // still get through.
        let fileSize = (try? fm.attributesOfItem(atPath: destURL.path)[.size] as? Int) ?? 0
        guard shouldAcceptImageSize(fileSize) else {
            Self.logger.info("download[\(index, privacy: .public)] size cap REJECTED; bytes=\(fileSize, privacy: .public) totalSoFar=\(self.totalBytesDownloaded, privacy: .public)")
            try? fm.removeItem(at: destURL)
            return nil
        }
        totalBytesDownloaded += fileSize
        Self.logger.debug("download[\(index, privacy: .public)] saved; filename=\(filename, privacy: .public) bytes=\(fileSize, privacy: .public) totalSoFar=\(self.totalBytesDownloaded, privacy: .public)")

        // Verify it's actually an image. Prefer the URLResponse MIME type; if
        // absent, probe the header with ImageIO (no pixel decode).
        let isImageMime = mimeType?.hasPrefix("image/") ?? false
        if !isImageMime {
            let valid = CGImageSourceCreateWithURL(destURL as CFURL, nil).map(Self.isDecodable) ?? false
            guard valid else {
                Self.logger.info("download[\(index, privacy: .public)] MIME-validation FAILED; mime=\(mimeType ?? "nil", privacy: .public)")
                try? fm.removeItem(at: destURL)
                return nil
            }
        }

        // Run OCR if enabled. ImageIO thumbnails decode directly at <= 2048px.
        let ocrText: String?
        if enableOCR {
            let cgForOCR = Self.downscaledCGImage(contentsOf: destURL)
            if let cg = cgForOCR {
                ocrText = await recognizeText(in: cg)
                Self.logger.debug("download[\(index, privacy: .public)] OCR done; recognized=\(ocrText?.count ?? -1, privacy: .public) chars")
            } else {
                Self.logger.debug("download[\(index, privacy: .public)] OCR skipped; cgForOCR=nil")
                ocrText = nil
            }
        } else {
            ocrText = nil
        }

        return ExtractedImage(
            sourceURL: url,
            tempFileURL: destURL,
            filename: filename,
            ocrText: ocrText
        )
    }

    /// Decode an image file to a `CGImage` whose longest edge is at most
    /// `maxOCRDimension`, using ImageIO thumbnailing. Unlike a full UIKit
    /// decode + redraw, this never materializes the full-resolution bitmap
    /// (an 8000×6000 photo would be ~192 MB — past the share extension's
    /// whole memory budget).
    static func downscaledCGImage(contentsOf url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return thumbnail(from: source)
    }

    /// In-memory variant of `downscaledCGImage(contentsOf:)`.
    static func downscaledCGImage(data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return thumbnail(from: source)
    }

    /// True when ImageIO recognizes the container and it holds >= 1 image.
    /// Reads only the header; no pixel decode.
    private static func isDecodable(_ source: CGImageSource) -> Bool {
        CGImageSourceGetType(source) != nil && CGImageSourceGetCount(source) > 0
    }

    private static func thumbnail(from source: CGImageSource) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: maxOCRDimension,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// Perform OCR on a CGImage using VNRecognizeTextRequest. Returns
    /// recognized text only when text appears to be the primary subject
    /// of the image — gauged by `textCoverageThreshold` summed across
    /// observation bounding boxes. Photos with incidental text (name
    /// cards, signage, captions) fall below the threshold and yield nil
    /// so the OCR section in the output isn't polluted with snippets
    /// that aren't useful to the reader.
    private func recognizeText(in image: CGImage) async -> String? {
        // Race the (synchronous, off-actor) Vision request against a hard
        // timeout. The first-resume guard guarantees the continuation resumes
        // exactly once; on timeout the orphaned Vision task is abandoned and
        // its eventual result discarded rather than hanging the clip.
        //
        // The request is created here so the timeout path can `cancel()` it:
        // Vision then aborts `perform` early instead of burning CPU/memory on
        // an abandoned image while the clip moves on.
        let resumed = ResumeOnce()
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let box = UncheckedSendableBox(request)
        return await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            let timeout = Task.detached {
                try? await Task.sleep(for: .seconds(Self.ocrTimeoutSeconds))
                if resumed.tryClaim() {
                    Self.logger.info("OCR TIMEOUT after \(Self.ocrTimeoutSeconds, privacy: .public)s; cancelling request")
                    box.value.cancel()
                    continuation.resume(returning: nil)
                }
            }
            Task.detached(priority: .userInitiated) {
                let text = Self.performOCRSync(request: box.value, on: image)
                timeout.cancel()
                if resumed.tryClaim() {
                    continuation.resume(returning: text)
                }
            }
        }
    }

    /// Carries a non-Sendable Vision request across the OCR/timeout tasks.
    /// `VNRequest.cancel()` may be called from another thread while
    /// `perform` runs; nothing else touches the request concurrently.
    private final class UncheckedSendableBox<T>: @unchecked Sendable {
        let value: T
        init(_ value: T) { self.value = value }
    }

    /// Lock-guarded once flag so the OCR/timeout race resumes its continuation
    /// exactly once.
    private final class ResumeOnce: @unchecked Sendable {
        private let lock = NSLock()
        private var claimed = false
        func tryClaim() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if claimed { return false }
            claimed = true
            return true
        }
    }

    /// Synchronous Vision OCR with the coverage filter. `handler.perform` blocks
    /// the calling thread, so this must run off the actor (see `recognizeText`).
    private static func performOCRSync(request: VNRecognizeTextRequest, on image: CGImage) -> String? {
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            logger.info("OCR perform FAILED: \(error.localizedDescription, privacy: .public)")
            return nil
        }

        guard let observations = request.results else { return nil }

        let coverage = observations.reduce(CGFloat(0)) { acc, obs in
            acc + (obs.boundingBox.width * obs.boundingBox.height)
        }
        let text = observations
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")

        let kept = coverage >= textCoverageThreshold && !text.isEmpty
        logger.debug("OCR coverage=\(Double(coverage), privacy: .public) chars=\(text.count, privacy: .public) threshold=\(Double(textCoverageThreshold), privacy: .public) kept=\(kept, privacy: .public)")

        return kept ? text : nil
    }

    func fileExtension(for url: URL, mimeType: String?) -> String {
        // Try MIME type first
        if let mime = mimeType {
            switch mime {
            case "image/png": return "png"
            case "image/jpeg", "image/jpg": return "jpg"
            case "image/gif": return "gif"
            case "image/webp": return "webp"
            case "image/svg+xml": return "svg"
            default: break
            }
        }

        // Fall back to URL path extension
        let pathExt = url.pathExtension.lowercased()
        if ["png", "jpg", "jpeg", "gif", "webp", "svg"].contains(pathExt) {
            return pathExt == "jpeg" ? "jpg" : pathExt
        }

        return "png" // Safe default
    }
}
