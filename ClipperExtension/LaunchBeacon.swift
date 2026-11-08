import Foundation
import os

/// Idempotent launch beacon for the share extension. Emits a signal both to
/// the unified system log (`log stream`-observable) and to App Group
/// `UserDefaults` (main-app-observable) every time the appex hits user code.
///
/// The point of this is observability for *Apple-managed* extension launch
/// failures — specifically the SwiftSoup-link hang that motivated branch
/// `debug/revert-swiftsoup-from-extension`. If the dynamic linker fails or
/// the appex never reaches user code, neither the os_log entry nor the
/// timestamp write happens, and the absence of an updated `last_extension_launch`
/// after a Safari share-sheet attempt is the diagnostic signal.
///
/// Call site: very first statement of `ShareViewController.viewDidLoad`.
enum LaunchBeacon {

    /// App Group `UserDefaults` keys.
    enum Keys {
        static let lastLaunch = "last_extension_launch"
        static let launchCount = "extension_launch_count"
    }

    private static let log = Logger(
        subsystem: "com.mmtac.md-clipper.extension",
        category: "launch"
    )

    /// Record that the appex reached user code. Idempotent: each call simply
    /// overwrites the timestamp and increments the counter — no allocation
    /// churn, no failure modes that can themselves cause a hang.
    static func emit() {
        let defaults = UserDefaults(suiteName: ClipperSettings.suiteName) ?? .standard
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let nextCount = defaults.integer(forKey: Keys.launchCount) + 1
        defaults.set(timestamp, forKey: Keys.lastLaunch)
        defaults.set(nextCount, forKey: Keys.launchCount)

        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        log.notice("appex launched: count=\(nextCount, privacy: .public) build=\(build, privacy: .public)")
    }
}
