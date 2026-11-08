# Privacy Policy — Obsidian Clipper

**Effective date:** 2026-11-08

Obsidian Clipper ("the app") is an iOS app and Share Extension that saves web pages you choose into a folder on your device (typically your Obsidian vault) as Markdown files. This policy explains, in plain language, what the app does and does not do with your information.

Obsidian Clipper is an independent app and is not affiliated with or endorsed by Obsidian or Dynalist Inc.

## The short version

- **We collect no data.** The app has no accounts, no analytics, no telemetry, no advertising, no crash-reporting SDKs, and no server of its own.
- **Everything stays on your device.** Your settings, clipped notes, images, and any site sign-in sessions are stored only on your device (and in whatever folder you choose, such as iCloud Drive).
- **No tracking.** The app does not track you across apps or websites and does not share anything with third parties.

## Data collected by the developer

None. The developer never receives any information from the app — not your clips, not the pages you visit, not your settings, not usage statistics.

## Data stored on your device

The app keeps the following on your device only, so it can work:

| What | Where | Why |
|---|---|---|
| Settings (vault name, target folder name, frontmatter / images / OCR toggles, list of custom sites you added) | App Group storage on the device, shared between the app and its Share Extension | So the Share Extension uses the settings you chose |
| A bookmark to the vault folder you picked | App Group storage on the device | So the extension can write into that folder later without asking again |
| Simple diagnostics (e.g. when the extension last launched, recent clip outcomes) | App Group storage on the device | Shown to you in the app to help troubleshoot; never sent anywhere |
| Site Logins session cookies (only if you use Site Logins) | The iOS Keychain on this device; not synced via iCloud Keychain | So the extension can fetch articles you are subscribed to |
| Your clipped notes and images | The folder you picked (e.g. your Obsidian vault in iCloud Drive or On My iPhone) | That is the purpose of the app |

If your chosen folder is in iCloud Drive, Apple syncs it under your own iCloud account and Apple's privacy policy applies to that sync. The developer has no access to it.

Deleting the app removes its settings and diagnostics. Clipped notes stay in your folder until you delete them. You can remove Site Logins cookies at any time by logging out of a site in the app.

## Site Logins

Site Logins is optional. If you use it, you sign in to a publisher's website (for example, a newspaper you subscribe to) inside an in-app web view, on that publisher's own sign-in page. The app does not see or store your password. After you sign in, the site's session cookies are saved in the Keychain on your device. When the Share Extension re-downloads a page you shared, it sends those cookies **only** to the matching site and **only** over HTTPS. They are never sent to the developer or anyone else.

## Network requests

The app and its Share Extension make network requests only to:

- the web page you chose to share, and
- the images referenced by that page,

plus, if you use Site Logins, the publisher's website while you sign in. These requests go directly from your device to those websites, which will see your IP address and the request just as if you had opened the page in a browser. Their own privacy policies apply to those requests.

## Text recognition (OCR)

Text recognition on images uses Apple's on-device Vision framework. Images are not uploaded anywhere for processing.

## Children

The app does not collect any personal information from anyone, including children.

## Changes to this policy

If this policy changes, the updated version will be published at the same location with a new effective date.

## Contact

Questions or concerns: open an issue at <https://github.com/aerocristobal/obsidian-clipper/issues>.
