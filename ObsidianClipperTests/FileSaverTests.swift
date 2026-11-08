import XCTest
@testable import ClipperExtension

final class FileSaverTests: XCTestCase {

    // MARK: - sanitizeFilename

    func testSanitizeBasicFilename() {
        let result = FileSaver.sanitizeFilename("My Article Title")
        XCTAssertEqual(result, "My Article Title")
    }

    func testSanitizeRemovesInvalidCharacters() {
        let result = FileSaver.sanitizeFilename("Title: With / Invalid * Chars?")
        XCTAssertFalse(result.contains(":"), "Should remove colons")
        XCTAssertFalse(result.contains("/"), "Should remove slashes")
        XCTAssertFalse(result.contains("*"), "Should remove asterisks")
        XCTAssertFalse(result.contains("?"), "Should remove question marks")
    }

    func testSanitizeCollapsesDashes() {
        let result = FileSaver.sanitizeFilename("A:::B")
        XCTAssertFalse(result.contains("---"), "Should collapse multiple dashes")
    }

    func testSanitizeLongName() {
        let longTitle = String(repeating: "A", count: 300)
        let result = FileSaver.sanitizeFilename(longTitle)
        XCTAssertLessThanOrEqual(result.count, 200, "Should truncate to 200 chars")
    }

    func testSanitizeEmptyName() {
        let result = FileSaver.sanitizeFilename("")
        XCTAssertEqual(result, "Untitled")
    }

    func testSanitizeOnlyInvalidChars() {
        let result = FileSaver.sanitizeFilename(":::**??")
        XCTAssertEqual(result, "Untitled")
    }

    func testSanitizeTrimsWhitespace() {
        let result = FileSaver.sanitizeFilename("  Title  ")
        XCTAssertEqual(result, "Title")
    }

    func testSanitizeTrimsDashes() {
        let result = FileSaver.sanitizeFilename("--Title--")
        XCTAssertEqual(result, "Title")
    }

    func testSanitizeBackslash() {
        let result = FileSaver.sanitizeFilename("Path\\To\\File")
        XCTAssertFalse(result.contains("\\"), "Should remove backslashes")
    }

    func testSanitizeAngleBrackets() {
        let result = FileSaver.sanitizeFilename("<script>alert</script>")
        XCTAssertFalse(result.contains("<"), "Should remove angle brackets")
        XCTAssertFalse(result.contains(">"), "Should remove angle brackets")
    }

    func testSanitizePipeCharacter() {
        let result = FileSaver.sanitizeFilename("Title | Subtitle")
        XCTAssertFalse(result.contains("|"), "Should remove pipe characters")
    }

    func testSanitizeQuotes() {
        let result = FileSaver.sanitizeFilename("\"Quoted\" Title")
        XCTAssertFalse(result.contains("\""), "Should remove double quotes")
    }

    func testSanitizeUnicode() {
        let result = FileSaver.sanitizeFilename("Cafe Resume")
        XCTAssertEqual(result, "Cafe Resume")
    }

    func testSanitizeSpecialCharCombo() {
        let result = FileSaver.sanitizeFilename("A/B:C*D?E\"F<G>H|I\\J")
        XCTAssertFalse(result.isEmpty, "Should produce non-empty result")
        XCTAssertTrue(result.contains("A"), "Should preserve valid characters")
        XCTAssertTrue(result.contains("J"), "Should preserve valid characters")
    }

    func testSanitizeSingleDot() {
        let result = FileSaver.sanitizeFilename(".")
        XCTAssertEqual(result, "Untitled", "Single dot should become Untitled")
    }

    func testSanitizeLeadingDots() {
        let result = FileSaver.sanitizeFilename(".hidden-article")
        XCTAssertFalse(result.hasPrefix("."), "Should not start with a dot")
        XCTAssertTrue(result.contains("hidden"), "Should preserve the rest of the name")
    }

    func testSanitizeTrailingDots() {
        let result = FileSaver.sanitizeFilename("Article...")
        XCTAssertFalse(result.hasSuffix("."), "Should not end with dots")
        XCTAssertTrue(result.hasPrefix("Article"), "Should preserve the name")
    }

    func testSanitizeWindowsReservedCON() {
        let result = FileSaver.sanitizeFilename("CON")
        XCTAssertNotEqual(result, "CON", "Should not be a bare Windows reserved name")
    }

    func testSanitizeWindowsReservedNUL() {
        let result = FileSaver.sanitizeFilename("NUL")
        XCTAssertNotEqual(result, "NUL", "Should not be a bare Windows reserved name")
    }

    func testSanitizeWindowsReservedCaseInsensitive() {
        let result = FileSaver.sanitizeFilename("con")
        XCTAssertNotEqual(result.uppercased(), "CON", "Reserved name check should be case-insensitive")
    }

    func testSanitizeWindowsReservedCOM1() {
        let result = FileSaver.sanitizeFilename("COM1")
        XCTAssertNotEqual(result, "COM1", "Should not be a bare Windows reserved name")
    }

    func testSanitizeDotsOnly() {
        let result = FileSaver.sanitizeFilename("...")
        XCTAssertEqual(result, "Untitled", "Only dots should become Untitled")
    }

    // MARK: - FileSaver.save

    func testSaveThrowsNoVaultConfigured() {
        let result = ClipResult(
            title: "Test",
            sourceURL: URL(string: "https://example.com"),
            markdownBody: "Body",
            images: [],
            clippedDate: Date()
        )
        let config = FileSaver.SaveConfig(
            targetFolder: "Inbox",
            includeFrontmatter: true,
            vaultBookmark: nil
        )
        XCTAssertThrowsError(try FileSaver.save(result, config: config)) { error in
            XCTAssertTrue(error is FileSaver.SaveError)
            if let saveError = error as? FileSaver.SaveError {
                switch saveError {
                case .noVaultConfigured:
                    break // expected
                default:
                    XCTFail("Expected noVaultConfigured, got \(saveError)")
                }
            }
        }
    }

    func testSaveThrowsBookmarkResolutionFailed() {
        let result = ClipResult(
            title: "Test",
            sourceURL: URL(string: "https://example.com"),
            markdownBody: "Body",
            images: [],
            clippedDate: Date()
        )
        // Pass invalid bookmark data that can't be resolved
        let config = FileSaver.SaveConfig(
            targetFolder: "Inbox",
            includeFrontmatter: true,
            vaultBookmark: Data([0x00, 0x01, 0x02])
        )
        XCTAssertThrowsError(try FileSaver.save(result, config: config)) { error in
            XCTAssertTrue(error is FileSaver.SaveError, "Should throw SaveError, got: \(error)")
        }
    }

    // MARK: - Stale bookmark refresh

    @MainActor
    func testRefreshBookmarkUpdatesPersistedBookmark() throws {
        // Create a temp directory — refreshing a bookmark for a real URL should
        // produce persisted bookmark data that resolves cleanly and is not stale.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipper-refresh-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let settings = ClipperSettings()
        let before = settings.vaultBookmark

        // Refresh should persist a fresh bookmark for the URL.
        settings.refreshBookmark(for: tmp)
        let after = settings.vaultBookmark
        XCTAssertNotNil(after, "refreshBookmark should persist bookmark data for a valid URL")
        XCTAssertNotEqual(before, after, "refreshBookmark should replace the persisted bookmark")

        // Resolving the fresh bookmark should yield a non-stale vault.
        let resolved = ClipperSettings.resolveVaultBookmark(after)
        XCTAssertNotNil(resolved, "Freshly persisted bookmark should resolve")
        XCTAssertFalse(resolved?.isStale ?? true, "Freshly persisted bookmark should not be stale")

        // Restore the prior bookmark so this test doesn't bleed into other tests
        // that share the App Group UserDefaults.
        settings.vaultBookmark = before
    }

    @MainActor
    func testRefreshBookmarkForInvalidURLLeavesBookmarkUnchanged() {
        let settings = ClipperSettings()
        let before = settings.vaultBookmark
        // A path that does not exist — bookmarkData should fail and refresh should silently no-op.
        let bogus = URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString)/vault")
        settings.refreshBookmark(for: bogus)
        XCTAssertEqual(settings.vaultBookmark, before, "Failed refresh should not clear or corrupt existing bookmark")
    }

    @MainActor
    func testPersistVaultBookmarkRoundTrip() throws {
        // The nonisolated persist path is what FileSaver uses to refresh a stale
        // bookmark synchronously while scoped access is held.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipper-persist-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let settings = ClipperSettings()
        let before = settings.vaultBookmark
        defer { settings.vaultBookmark = before }

        let data = try tmp.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        ClipperSettings.persistVaultBookmark(data)

        let persisted = UserDefaults(suiteName: ClipperSettings.suiteName)?.data(forKey: "vault_bookmark")
        XCTAssertEqual(persisted, data, "persistVaultBookmark should write the App Group defaults directly")

        let resolved = ClipperSettings.resolveVaultBookmark(persisted)
        XCTAssertNotNil(resolved, "Persisted bookmark should resolve")
        XCTAssertFalse(resolved?.isStale ?? true, "Persisted bookmark should not be stale")
    }

    // MARK: - Byte-length limits (filesystem caps components at 255 bytes)

    func testSanitizeLongCJKTitleIsByteBounded() {
        let title = String(repeating: "日本語のタイトル", count: 25) // 200 chars, 600 bytes
        let result = FileSaver.sanitizeFilename(title)
        XCTAssertLessThanOrEqual(result.utf8.count, FileSaver.maxTitleBytes)
        XCTAssertFalse(result.isEmpty)
        XCTAssertTrue(title.hasPrefix(result), "Truncation should keep a prefix on Character boundaries")
    }

    func testSanitizeEmojiTitleDoesNotSplitGraphemes() {
        let family = "👨‍👩‍👧‍👦" // 25 UTF-8 bytes, one Character
        let title = String(repeating: family, count: 20)
        let result = FileSaver.sanitizeFilename(title)
        XCTAssertLessThanOrEqual(result.utf8.count, FileSaver.maxTitleBytes)
        XCTAssertEqual(result.count, FileSaver.maxTitleBytes / family.utf8.count)
        XCTAssertTrue(result.allSatisfy { $0 == Character(family) })
    }

    @MainActor
    func testSaveWithLongCJKTitleProducesBoundedNames() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipper-cjk-save-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let bookmark = try tmp.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        let config = FileSaver.SaveConfig(targetFolder: "Inbox", includeFrontmatter: true, vaultBookmark: bookmark)
        let title = String(repeating: "東京都の新しい記事タイトル", count: 16) // 208 chars
        let clip = ClipResult(
            title: title,
            sourceURL: URL(string: "https://example.jp/a"),
            markdownBody: "本文",
            images: [],
            clippedDate: Date()
        )

        // Save twice so the second hits the "-<timestamp>" re-clip suffix path.
        let first = try FileSaver.save(clip, config: config)
        let second = try FileSaver.save(clip, config: config)
        for url in [first, second] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
            XCTAssertLessThanOrEqual(url.lastPathComponent.utf8.count, 255)
            XCTAssertLessThanOrEqual(url.deletingLastPathComponent().lastPathComponent.utf8.count, 255)
        }
        XCTAssertNotEqual(first.deletingLastPathComponent(), second.deletingLastPathComponent())
    }
}
