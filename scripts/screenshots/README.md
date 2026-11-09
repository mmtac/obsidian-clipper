# App Store screenshot harness

A throwaway UI-test project that drives the **installed** MD Clipper app, Safari and Files in a simulator. It captures the App Store screenshots in `docs/app-store/screenshots/`. It isn't part of the main Xcode project.

## Run

1. **Build the app and install it** on the simulator (Release config, so the debug UI is hidden):
   ```bash
   xcodebuild -project ObsidianClipper.xcodeproj -scheme ObsidianClipper -configuration Release \
     -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -derivedDataPath /tmp/dd-shots build
   xcrun simctl install "iPhone 17 Pro Max" /tmp/dd-shots/Build/Products/Release-iphonesimulator/ObsidianClipper.app
   xcrun simctl status_bar "iPhone 17 Pro Max" override --time 9:41 --batteryState charged --batteryLevel 100
   ```
2. **Seed a vault folder** in the simulator's "On My iPhone" storage:
   ```bash
   G=$(xcrun simctl get_app_container "iPhone 17 Pro Max" com.apple.DocumentsApp groups | grep LocalStorage | awk '{print $2}')
   mkdir -p "$G/File Provider Storage/Obsidian Vault/Inbox" "$G/File Provider Storage/Obsidian Vault/Projects"
   ```
3. **Serve the sample article.** It's our own content, so it carries no third-party rights:
   ```bash
   (cd scripts/screenshots/sample-site && python3 -m http.server 8765 --bind 127.0.0.1) &
   ```
4. **Run the harness:**
   ```bash
   cd scripts/screenshots && xcodegen generate
   TEST_RUNNER_SHOTS_OUT=$PWD/out xcodebuild -project Shots.xcodeproj -scheme ShotsHost \
     -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' test
   ```

For the 13" iPad, repeat with `iPad Pro 13-inch (M5)`. Output goes to `out/iphone-6.9/` or `out/ipad-13/`.

If Safari reports "has not loaded accessibility", re-run. The harness quits Safari first to avoid this, but it can still happen occasionally.
