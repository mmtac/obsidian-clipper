import XCTest

/// Drives the installed MD Clipper app, Safari and Files to capture App Store screenshots.
/// Screenshots and accessibility dumps are written straight to the host scratch folder.
final class ShotsTests: XCTestCase {

    static let out = (ProcessInfo.processInfo.environment["SHOTS_OUT"] ?? NSTemporaryDirectory() + "shots") + "/" + (UIDevice.current.userInterfaceIdiom == .pad ? "ipad-13" : "iphone-6.9")
    let clipper = XCUIApplication(bundleIdentifier: "com.mmtac.md-clipper")
    let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
    let files = XCUIApplication(bundleIdentifier: "com.apple.DocumentsApp")
    let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")

    override func setUp() {
        continueAfterFailure = false
        try? FileManager.default.createDirectory(atPath: Self.out, withIntermediateDirectories: true)
    }

    // MARK: helpers

    func shot(_ name: String) {
        sleep(1)
        let png = XCUIScreen.main.screenshot().pngRepresentation
        FileManager.default.createFile(atPath: "\(Self.out)/\(name).png", contents: png)
    }

    func dump(_ app: XCUIApplication, _ name: String) {
        try? app.debugDescription.write(toFile: "\(Self.out)/\(name).txt", atomically: true, encoding: .utf8)
    }

    /// First hittable element whose label or identifier matches any of `labels`.
    func find(_ app: XCUIApplication, _ labels: [String], timeout: TimeInterval = 8) -> XCUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            for label in labels {
                let pred = NSPredicate(format: "label == %@ OR identifier == %@", label, label)
                let matches = app.descendants(matching: .any).matching(pred)
                for i in 0..<min(matches.count, 6) {
                    let e = matches.element(boundBy: i)
                    if e.exists && e.isHittable { return e }
                }
            }
            usleep(400_000)
        } while Date() < deadline
        return nil
    }

    @discardableResult
    func tap(_ app: XCUIApplication, _ labels: [String], step: String, timeout: TimeInterval = 8) -> Bool {
        if let e = find(app, labels, timeout: timeout) { e.tap(); return true }
        dump(app, "FAIL-\(step)")
        XCTFail("Could not find \(labels) at step \(step)")
        return false
    }

    // MARK: steps

    func test01_selectVault() {
        clipper.terminate()
        XCUIDevice.shared.press(.home)
        clipper.launch()
        tap(clipper, ["Select Vault Folder"], step: "open-picker")
        sleep(2)
        dump(clipper, "picker-1")
        if !clipper.cells["Obsidian Vault, Folder"].waitForExistence(timeout: 3) {
            tap(clipper, ["On My iPhone", "On My iPad"], step: "on-my-iphone")
        }
        let folder = clipper.cells["Obsidian Vault, Folder"]
        XCTAssertTrue(folder.waitForExistence(timeout: 8))
        folder.tap()
        sleep(3)
        dump(clipper, "picker-2")
        XCTAssertTrue(clipper.staticTexts["Inbox"].firstMatch.waitForExistence(timeout: 5),
                      "picker did not open the vault folder")
        tap(clipper, ["Open"], step: "open")
        sleep(2)
        dump(clipper, "settings-after")
        shot("app-settings")
    }

    func test02_siteLogins() {
        clipper.terminate()
        XCUIDevice.shared.press(.home)
        clipper.launch()
        if find(clipper, ["Site Logins"], timeout: 2) == nil { clipper.swipeUp() }
        tap(clipper, ["Site Logins"], step: "site-logins")
        sleep(2)
        shot("app-site-logins")
        clipper.navigationBars.buttons.element(boundBy: 0).tap()
    }

    func test03_shareFromSafari() {
        safari.terminate()
        XCUIDevice.shared.press(.home)
        safari.open(URL(string: "http://localhost:8765/")!)
        XCTAssertTrue(safari.staticTexts["Why Plain Text Notes Outlast Every App"].waitForExistence(timeout: 20))
        sleep(2)
        shot("safari-article")
        dump(safari, "safari")
        if find(safari, ["ShareButton"], timeout: 2) == nil {
            tap(safari, ["MoreMenuButton"], step: "more-menu")
            sleep(1)
            dump(safari, "more-menu")
        }
        tap(safari, ["ShareButton", "Share"], step: "share")
        sleep(2)
        dump(safari, "share-sheet")
        shot("share-sheet")
        tap(safari, ["MD Clipper"], step: "pick-extension")
        // The sheet auto-dismisses 1.5 s after success: capture as soon as it appears.
        var captured = false
        let deadline = Date().addingTimeInterval(40)
        while Date() < deadline {
            if safari.staticTexts["Saved to Obsidian"].exists || springboard.staticTexts["Saved to Obsidian"].exists {
                let png = XCUIScreen.main.screenshot().pngRepresentation
                FileManager.default.createFile(atPath: "\(Self.out)/extension-result.png", contents: png)
                captured = true
                break
            }
            usleep(100_000)
        }
        XCTAssertTrue(captured, "extension did not report success")
    }

    func test04_noteInFiles() {
        files.terminate()
        XCUIDevice.shared.press(.home)
        files.launch()
        sleep(2)
        dump(files, "files-1")
        if find(files, ["Obsidian Vault, Folder", "Obsidian Vault"], timeout: 3) == nil {
            _ = find(files, ["Browse"], timeout: 3)?.tap()
            sleep(1)
            tap(files, ["On My iPhone", "On My iPad"], step: "files-on-my-iphone")
        }
        tap(files, ["Obsidian Vault, Folder", "Obsidian Vault"], step: "files-vault")
        sleep(1)
        tap(files, ["Inbox, Folder", "Inbox"], step: "files-inbox")
        sleep(1)
        tap(files, ["Why Plain Text Notes Outlast Every App, Folder", "Why Plain Text Notes Outlast Every App"], step: "files-clip-folder")
        sleep(1)
        shot("files-clip-folder")
        let note = files.cells.matching(NSPredicate(format: "identifier BEGINSWITH 'Why Plain Text Notes Outlast Every App, md' OR label BEGINSWITH 'Why Plain Text Notes Outlast Every App'")).firstMatch
        dump(files, "files-folder")
        XCTAssertTrue(note.waitForExistence(timeout: 5))
        note.tap()
        sleep(3)
        dump(files, "files-note")
        shot("files-note")
    }
}
