import Foundation
import os

/// Saves the clipped markdown note and images to the Obsidian vault folder
/// using security-scoped bookmarks for file access.
enum FileSaver {

    private static let logger = Logger(subsystem: "com.mmtac.md-clipper", category: "save")

    /// Maximum UTF-8 byte length of a sanitized title. APFS/HFS+ cap a single
    /// path component at 255 *bytes* (not characters — a CJK character is 3
    /// bytes, many emoji 4+). 200 leaves room for the `-<timestamp>` re-clip
    /// suffix (11 bytes) and the `.md` extension.
    static let maxTitleBytes = 200

    /// Sendable configuration extracted from ClipperSettings for use across actor boundaries.
    struct SaveConfig: Sendable {
        let targetFolder: String
        let includeFrontmatter: Bool
        let vaultBookmark: Data?

        @MainActor
        init(from settings: ClipperSettings) {
            self.targetFolder = settings.targetFolder
            self.includeFrontmatter = settings.includeFrontmatter
            self.vaultBookmark = settings.vaultBookmark
        }

        /// Direct initializer for testing and non-MainActor contexts.
        init(targetFolder: String, includeFrontmatter: Bool, vaultBookmark: Data?) {
            self.targetFolder = targetFolder
            self.includeFrontmatter = includeFrontmatter
            self.vaultBookmark = vaultBookmark
        }
    }

    enum SaveError: LocalizedError {
        case noVaultConfigured
        case bookmarkResolutionFailed
        case accessDenied
        case writeFailed(String)

        var errorDescription: String? {
            switch self {
            case .noVaultConfigured:
                return "No vault folder configured. Open Markdown Clipper and select your vault folder."
            case .bookmarkResolutionFailed:
                return "Could not access the vault folder. Please re-select it in settings."
            case .accessDenied:
                return "Permission denied. Please re-select the vault folder in Markdown Clipper settings."
            case .writeFailed(let detail):
                return "Failed to write files: \(detail)"
            }
        }
    }

    /// Save a ClipResult to the configured Obsidian vault.
    /// Returns the URL of the saved markdown file.
    @discardableResult
    static func save(_ result: ClipResult, config: SaveConfig) throws -> URL {
        // Resolve the vault folder from the bookmark
        guard config.vaultBookmark != nil else {
            throw SaveError.noVaultConfigured
        }

        // resolveVaultURL is nonisolated — safe to call from any context
        let settings = ClipperSettings.resolveVaultBookmark(config.vaultBookmark)
        guard let resolved = settings else {
            throw SaveError.bookmarkResolutionFailed
        }
        let vaultURL = resolved.url

        // Start security-scoped access — must wrap ALL file I/O below.
        guard vaultURL.startAccessingSecurityScopedResource() else {
            throw SaveError.accessDenied
        }
        defer { vaultURL.stopAccessingSecurityScopedResource() }

        // If the bookmark is stale, refresh it synchronously while scoped access is
        // still held — `bookmarkData()` needs live access to the URL. A detached
        // task here could run after the `defer` releases the scope and silently
        // fail, leaving the stale bookmark to rot across clips.
        if resolved.isStale {
            if let fresh = try? vaultURL.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
                ClipperSettings.persistVaultBookmark(fresh)
            } else {
                logger.error("stale bookmark refresh FAILED; will retry on next save")
            }
        }

        let fm = FileManager.default

        // Build the target folder path
        let targetFolder = config.targetFolder.isEmpty ? "" : config.targetFolder
        let targetDir: URL
        if targetFolder.isEmpty {
            targetDir = vaultURL
        } else {
            targetDir = vaultURL.appendingPathComponent(targetFolder, isDirectory: true)
        }

        // Create target folder if needed
        if !fm.fileExists(atPath: targetDir.path) {
            try fm.createDirectory(at: targetDir, withIntermediateDirectories: true)
        }

        // Sanitize the title for use as a folder/filename
        let safeTitle = sanitizeFilename(result.title)

        // Create a per-article subfolder to keep each clip self-contained
        var articleDir = targetDir.appendingPathComponent(safeTitle, isDirectory: true)

        // If a subfolder with the same name already exists (re-clip), append timestamp
        if fm.fileExists(atPath: articleDir.path) {
            let timestamp = Int(Date().timeIntervalSince1970)
            articleDir = targetDir.appendingPathComponent("\(safeTitle)-\(timestamp)", isDirectory: true)
        }

        try fm.createDirectory(at: articleDir, withIntermediateDirectories: true)

        // Save images if any
        var imageReferences: [String: String] = [:] // sourceURL -> relative markdown path
        if !result.images.isEmpty {
            let imagesDir = articleDir.appendingPathComponent("images", isDirectory: true)
            if !fm.fileExists(atPath: imagesDir.path) {
                try fm.createDirectory(at: imagesDir, withIntermediateDirectories: true)
            }

            for image in result.images {
                let imageURL = imagesDir.appendingPathComponent(image.filename)
                do {
                    // Move the scratch temp file into place. Falls back to
                    // copy+delete for cross-volume cases (e.g. if scratch lives
                    // on a different mount than the vault).
                    do {
                        try fm.moveItem(at: image.tempFileURL, to: imageURL)
                    } catch {
                        try fm.copyItem(at: image.tempFileURL, to: imageURL)
                        try? fm.removeItem(at: image.tempFileURL)
                    }
                    imageReferences[image.sourceURL.absoluteString] = "images/\(image.filename)"
                } catch {
                    // Non-fatal: skip this image
                    continue
                }
            }
        }

        // Generate markdown with local image references
        let markdown = result.toMarkdown(
            includeFrontmatter: config.includeFrontmatter,
            imageReferences: imageReferences
        )

        // Write the markdown file inside the article subfolder
        let mdFilename = "\(safeTitle).md"
        let finalURL = articleDir.appendingPathComponent(mdFilename)

        guard let mdData = markdown.data(using: .utf8) else {
            throw SaveError.writeFailed("Could not encode markdown as UTF-8")
        }

        do {
            try mdData.write(to: finalURL)
        } catch {
            throw SaveError.writeFailed(error.localizedDescription)
        }

        return finalURL
    }

    /// Windows reserved filenames that are not valid on NTFS/FAT.
    private static let windowsReservedNames: Set<String> = [
        "CON", "PRN", "AUX", "NUL",
        "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9",
        "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9"
    ]

    /// Remove characters that are invalid in filenames.
    static func sanitizeFilename(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:*?\"<>|\\")
        var sanitized = name.components(separatedBy: invalid).joined(separator: "-")
        // Collapse multiple dashes
        sanitized = sanitized.replacingOccurrences(of: "-{2,}", with: "-", options: .regularExpression)
        // Trim dashes and whitespace
        sanitized = sanitized.trimmingCharacters(in: .whitespacesAndNewlines)
        sanitized = sanitized.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        // Strip leading dots (prevents hidden files on macOS/Linux)
        while sanitized.hasPrefix(".") {
            sanitized = String(sanitized.dropFirst())
        }
        // Strip trailing dots (invalid on Windows)
        while sanitized.hasSuffix(".") {
            sanitized = String(sanitized.dropLast())
        }
        // Limit length in UTF-8 bytes (filesystem limit is 255 bytes per
        // component). Trim whole Characters so we never split a grapheme.
        if sanitized.utf8.count > maxTitleBytes {
            var trimmed = ""
            var bytes = 0
            for ch in sanitized {
                let n = ch.utf8.count
                if bytes + n > maxTitleBytes { break }
                bytes += n
                trimmed.append(ch)
            }
            sanitized = trimmed
            // Truncation may leave a trailing dot/space/dash; re-trim.
            sanitized = sanitized.trimmingCharacters(in: .whitespacesAndNewlines)
            while let last = sanitized.last, last == "." || last == "-" {
                sanitized.removeLast()
            }
        }
        // Handle empty result
        if sanitized.isEmpty {
            return "Untitled"
        }
        // Handle Windows reserved names (case-insensitive)
        if windowsReservedNames.contains(sanitized.uppercased()) {
            sanitized = sanitized + "_"
        }
        return sanitized
    }
}
