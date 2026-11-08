import Foundation
import os

/// Why persisting the chosen vault folder failed. Surfaced to the user by the
/// settings screen so a bad pick is never silently ignored.
enum VaultBookmarkError: LocalizedError {
    /// iOS refused security-scoped access to the picked folder.
    case accessDenied
    /// Access was granted but iOS could not create a bookmark for the folder.
    case bookmarkFailed(underlying: Error)

    var errorDescription: String? {
        switch self {
        case .accessDenied:
            return "Couldn't access that folder."
        case .bookmarkFailed:
            return "Couldn't remember that folder."
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .accessDenied:
            return "iOS didn't grant access to the selected folder. Make sure it's downloaded and available in the Files app, then tap Select Vault Folder and choose it again."
        case .bookmarkFailed(let underlying):
            return "iOS couldn't save a reference to the folder (\(underlying.localizedDescription)). Tap Select Vault Folder and choose it again, or pick a folder in iCloud Drive or On My iPhone."
        }
    }
}

/// Shared settings accessible by both the main app and the share extension.
/// Uses an App Group (suite name) so both targets read/write the same UserDefaults.
///
/// Isolated to `@MainActor` for strict Sendable compliance — all property
/// access happens on the main thread, matching SwiftUI's expectation.
@MainActor
final class ClipperSettings: ObservableObject {

    nonisolated static let suiteName = "group.com.mmtac.md-clipper"

    nonisolated static let logger = Logger(subsystem: "com.mmtac.md-clipper", category: "settings")

    /// The App Group defaults shared with the extension. Falls back to
    /// `.standard` so the app still runs, but logs an error: a missing App
    /// Group means the extension will never see these settings.
    nonisolated static func sharedDefaults() -> UserDefaults {
        if let defaults = UserDefaults(suiteName: suiteName) {
            return defaults
        }
        logger.error("App Group \(suiteName, privacy: .public) unavailable; falling back to standard UserDefaults. The share extension will not see these settings — check the App Group entitlement.")
        return .standard
    }

    private let defaults: UserDefaults

    /// The folder inside the vault where clipped notes are saved (e.g. "Inbox").
    @Published var targetFolder: String {
        didSet { defaults.set(targetFolder, forKey: Keys.targetFolder) }
    }

    /// Security-scoped bookmark data for the chosen vault folder.
    /// Persisted so the share extension can re-resolve the URL without a new picker.
    @Published var vaultBookmark: Data? {
        didSet { defaults.set(vaultBookmark, forKey: Keys.vaultBookmark) }
    }

    /// Whether to run OCR on images and include the recognized text in the note.
    @Published var enableOCR: Bool {
        didSet { defaults.set(enableOCR, forKey: Keys.enableOCR) }
    }

    /// Whether to download and save images locally into an images/ subfolder.
    @Published var saveImages: Bool {
        didSet { defaults.set(saveImages, forKey: Keys.saveImages) }
    }

    /// Whether to include YAML frontmatter in the generated markdown.
    @Published var includeFrontmatter: Bool {
        didSet { defaults.set(includeFrontmatter, forKey: Keys.includeFrontmatter) }
    }

    init() {
        let defaults = Self.sharedDefaults()
        self.defaults = defaults
        self.targetFolder = defaults.string(forKey: Keys.targetFolder) ?? "Inbox"
        self.vaultBookmark = defaults.data(forKey: Keys.vaultBookmark)
        self.enableOCR = defaults.object(forKey: Keys.enableOCR) as? Bool ?? true
        self.saveImages = defaults.object(forKey: Keys.saveImages) as? Bool ?? true
        self.includeFrontmatter = defaults.object(forKey: Keys.includeFrontmatter) as? Bool ?? true
    }

    struct ResolvedVault: Sendable {
        let url: URL
        let isStale: Bool
    }

    /// Resolve the vault folder URL from the persisted bookmark.
    /// The returned URL is NOT yet under security scope — callers must wrap
    /// their own `startAccessingSecurityScopedResource` / stop pair around
    /// any file I/O. If `isStale` is true, the caller should refresh the
    /// bookmark via `refreshBookmark(for:)` *while holding* scoped access.
    nonisolated func resolveVaultURL() -> ResolvedVault? {
        let defaults = Self.sharedDefaults()
        guard let bookmark = defaults.data(forKey: Keys.vaultBookmark) else { return nil }
        return Self.resolveVaultBookmark(bookmark)
    }

    /// Resolve a vault bookmark from raw bookmark data. This is nonisolated and Sendable-safe.
    nonisolated static func resolveVaultBookmark(_ bookmark: Data?) -> ResolvedVault? {
        guard let bookmark else { return nil }
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: bookmark,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else { return nil }
        return ResolvedVault(url: url, isStale: isStale)
    }

    /// Persist fresh bookmark data directly to the App Group defaults.
    /// Nonisolated and thread-safe (UserDefaults is internally synchronized) so the
    /// share extension can refresh a stale bookmark while still holding scoped
    /// access, without hopping to the MainActor after the scope is released.
    nonisolated static func persistVaultBookmark(_ data: Data) {
        sharedDefaults().set(data, forKey: Keys.vaultBookmark)
    }

    /// Re-persist a bookmark for a URL the caller already holds scoped access to.
    func refreshBookmark(for url: URL) {
        do {
            vaultBookmark = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        } catch {
            Self.logger.error("Stale vault bookmark refresh failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Persist a folder URL as a security-scoped bookmark.
    /// Throws `VaultBookmarkError` when iOS denies access to the folder or
    /// cannot create a bookmark, so the caller can tell the user.
    func saveVaultBookmark(for url: URL) throws {
        guard url.startAccessingSecurityScopedResource() else {
            Self.logger.error("Vault folder pick: startAccessingSecurityScopedResource returned false")
            throw VaultBookmarkError.accessDenied
        }
        defer { url.stopAccessingSecurityScopedResource() }
        do {
            vaultBookmark = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        } catch {
            Self.logger.error("Vault folder pick: bookmarkData failed: \(error.localizedDescription, privacy: .public)")
            throw VaultBookmarkError.bookmarkFailed(underlying: error)
        }
    }

    private enum Keys {
        static let targetFolder = "target_folder"
        static let vaultBookmark = "vault_bookmark"
        static let enableOCR = "enable_ocr"
        static let saveImages = "save_images"
        static let includeFrontmatter = "include_frontmatter"
    }
}
