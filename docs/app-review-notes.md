# App Review Notes — Obsidian Clipper 1.0

*Paste the relevant parts into App Store Connect → App Review Information → Notes.*

## What the app does

Obsidian Clipper is a utility with a Share Extension ("Clip to Obsidian") that saves a web page, text, or image shared from any app into a folder the user picks in the Files app (typically their Obsidian notes vault) as a Markdown file, with images downloaded alongside and optional on-device OCR (Apple Vision). The main app only contains settings, folder selection, optional Site Logins, and About.

There is no account, no sign-in to our service, no server, no analytics, and no in-app purchase. No demo account is required.

Obsidian Clipper is an independent app and is **not affiliated with or endorsed by Obsidian or Dynalist Inc.** The name describes compatibility: it writes plain Markdown files that the Obsidian app (and any other Markdown editor) can open. The About screen and the description state this.

## How to test

1. Install and open the app.
2. Tap the onboarding banner / **Vault Folder** and pick any folder in Files (for example, create a folder named "Test Vault" under *On My iPhone*). Leave Target Folder as `Inbox`.
3. Open Safari and load any article (e.g. https://en.wikipedia.org/wiki/Markdown).
4. Tap **Share** → **Clip to Obsidian** (if not visible: scroll the app row to the end → **More** → enable it).
5. The extension shows progress and then "Saved". It closes automatically.
6. Open the Files app → *Test Vault/Inbox/<Article Title>/* to see the `.md` note and an `images/` folder.

Sharing a link from another app (e.g. Notes or Messages) works the same way; the extension downloads the page.

## App Transport Security exception (Share Extension)

The Share Extension's Info.plist sets `NSAllowsArbitraryLoads = YES`. Justification: the extension's sole purpose is to download whatever web page the user explicitly shares, plus the images that page references. These are arbitrary third-party sites chosen by the user, and a meaningful share of pages and especially image CDNs on the open web are still served over plain HTTP. Without the exception, clipping those pages or their images would fail. Mitigations:

- Requests are made only in response to an explicit user share, to the shared page and its images.
- Only `http` and `https` URLs are accepted; `file:`, `javascript:`, `data:`, `ftp:` etc. are rejected.
- Site Logins cookies are attached **only** to HTTPS requests to the matching domain, never over HTTP.
- The main app does not have an ATS exception.

## Site Logins

Optional feature for users who subscribe to paywalled publications (presets: NYT, Wired, The Verge; users can add their own site). The user opens the publisher's own sign-in page in an in-app `WKWebView` and signs in with **their own subscription credentials**. The app does not read or store passwords. After sign-in, only the site's session cookies are saved in the iOS Keychain on the device (App Group access group shared with the extension, not synced to iCloud). The extension sends them only to the matching domain over HTTPS when re-downloading a shared page. **Nothing is sent to the developer or any third party.** Users can log out of a site (deleting its cookies) by swiping its row.

This does not bypass paywalls: it only lets the user's existing, paid session be used for pages they personally save, equivalent to sharing from Safari while signed in.

## Privacy

- Privacy manifest included in both the app and the extension; no tracking, no collected data types.
- App Privacy "nutrition label": **Data Not Collected**.
- Privacy policy: see `docs/privacy.md` (hosted URL supplied in App Store Connect).
