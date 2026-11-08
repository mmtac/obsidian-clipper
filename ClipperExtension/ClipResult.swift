import Foundation
import UIKit

/// Represents a single extracted image from the web page.
struct ExtractedImage: Sendable {
    /// The original URL of the image.
    let sourceURL: URL
    /// Absolute path to a temp file containing the image bytes.
    /// `FileSaver` moves this file into place; the file is owned by the
    /// `ImageProcessor`'s scratch directory and is cleaned up on cancel.
    let tempFileURL: URL
    /// A sanitized filename (e.g. "image-1.png").
    let filename: String
    /// OCR-recognized text, if any.
    var ocrText: String?
}

/// The result of clipping a web page.
struct ClipResult: Sendable {
    /// The page title.
    let title: String
    /// The original page URL.
    let sourceURL: URL?
    /// The article body converted to Markdown.
    let markdownBody: String
    /// Extracted images.
    let images: [ExtractedImage]
    /// The date the clip was created.
    let clippedDate: Date

    /// Assemble the final Markdown file content, including optional YAML frontmatter.
    /// `imageReferences` maps source URL strings to local relative paths (e.g. "images/abc-1.png").
    func toMarkdown(includeFrontmatter: Bool, imageReferences: [String: String] = [:]) -> String {
        var parts: [String] = []

        // Normalize whitespace in the title so control characters (newlines, tabs)
        // cannot break the H1 heading or source line, and cannot inject YAML keys
        // once escaped into the frontmatter.
        let displayTitle = Self.normalizeTitleWhitespace(title)

        if includeFrontmatter {
            var fm = "---\n"
            fm += "title: \"\(Self.sanitizeYAMLValue(displayTitle))\"\n"
            if let url = sourceURL {
                fm += "source: \"\(url.absoluteString)\"\n"
            }
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withFullDate]
            fm += "clipped: \(formatter.string(from: clippedDate))\n"
            fm += "type: article\n"
            fm += "---\n"
            parts.append(fm)
        }

        parts.append("# \(displayTitle)\n")

        if let url = sourceURL {
            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "yyyy-MM-dd"
            let dateStr = dateFormatter.string(from: clippedDate)
            parts.append("> [Source](\(url.absoluteString)) — Clipped \(dateStr)\n")
        }

        parts.append(markdownBody)

        // Append any unreferenced images as a fallback section.
        // Images that were placed inline via markers are already in the body.
        let unreferencedImages = images.filter { image in
            guard let localPath = imageReferences[image.sourceURL.absoluteString] else { return false }
            // Check if this image path already appears inline in the markdown body
            return !markdownBody.contains(localPath)
        }
        if !unreferencedImages.isEmpty {
            parts.append("\n## Images\n")
            for image in unreferencedImages {
                if let localPath = imageReferences[image.sourceURL.absoluteString] {
                    let name = (localPath as NSString).lastPathComponent
                    let alt = (name as NSString).deletingPathExtension
                    parts.append("![\(alt)](\(localPath))\n")
                }
            }
        }

        // Append OCR text blocks for images that had recognized text
        let ocrImages = images.compactMap { img -> (filename: String, text: String)? in
            guard let text = img.ocrText, !text.isEmpty else { return nil }
            return (img.filename, text)
        }
        if !ocrImages.isEmpty {
            parts.append("\n---\n")
            parts.append("## Extracted Text (OCR)\n")
            for img in ocrImages {
                parts.append("### \(img.filename)\n")
                parts.append("> \(img.text.replacingOccurrences(of: "\n", with: "\n> "))\n")
            }
        }

        return parts.joined(separator: "\n")
    }

    /// Collapse runs of whitespace (including newlines and tabs) into single spaces
    /// so the title renders cleanly in headings and cannot break a single-line YAML value.
    private static func normalizeTitleWhitespace(_ value: String) -> String {
        var result = ""
        result.reserveCapacity(value.count)
        var lastWasSpace = false
        for char in value {
            if char.isWhitespace {
                if !lastWasSpace {
                    result.append(" ")
                    lastWasSpace = true
                }
            } else {
                result.append(char)
                lastWasSpace = false
            }
        }
        return result.trimmingCharacters(in: .whitespaces)
    }

    /// Sanitize a string for use as a YAML double-quoted value.
    /// Escapes backslashes, double quotes, and replaces newlines/control chars.
    private static func sanitizeYAMLValue(_ value: String) -> String {
        var result = value
        result = result.replacingOccurrences(of: "\\", with: "\\\\")
        result = result.replacingOccurrences(of: "\"", with: "\\\"")
        result = result.replacingOccurrences(of: "\n", with: "\\n")
        result = result.replacingOccurrences(of: "\r", with: "\\r")
        result = result.replacingOccurrences(of: "\t", with: "\\t")
        return result
    }
}
