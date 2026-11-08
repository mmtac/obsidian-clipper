# Markdown Clipper for Obsidian — Support

Markdown Clipper saves web pages, text, and images from the iOS Share Sheet into a folder of your choice — typically your Obsidian vault — as clean Markdown notes, with images and on-device text recognition (OCR).

Markdown Clipper for Obsidian is an independent app and is not affiliated with or endorsed by Obsidian or Dynalist Inc. No Obsidian plugin is required.

## Getting started

1. **Install and open Markdown Clipper.**
2. **Pick your vault folder.** Tap the onboarding banner (or **Vault Folder** in Settings) and choose the folder that holds your Obsidian vault:
   - **iCloud Drive:** browse to *iCloud Drive → Obsidian → <your vault>*.
   - **On My iPhone / iPad:** browse to *On My iPhone → Obsidian → <your vault>*.
   - Any other folder in the Files app works too.
3. **Set a target folder** (default `Inbox`). Clips are saved inside it, one subfolder per article.
4. **Choose options:** YAML frontmatter, saving images, and OCR on images can each be turned on or off.

## Enabling the Share Extension

The extension is named **MD Clipper**.

1. Open Safari (or any app with a Share button) and tap **Share**.
2. In the row of app icons, scroll to the end and tap **More**.
3. Turn on **MD Clipper**. Optionally tap **Edit** to move it to Favorites.

## Clipping

- **From Safari:** Share → **MD Clipper**. The page as you see it (including content you're signed in to) is captured.
- **From other apps:** Share a link → **MD Clipper**. The page is downloaded again by the extension.
- **Text and images** can also be shared; images are saved and, if enabled, their text is recognized on-device.

Each clip becomes `<Vault>/<Target>/<Article Title>/<Article Title>.md` with an `images/` subfolder.

## Site Logins (optional)

When you share a link from an app other than Safari, paywalled sites may return only a preview. Site Logins lets you sign in to sites you subscribe to so the extension can fetch the full article.

1. In Markdown Clipper, open **Site Logins**.
2. Tap a site (or add your own) and sign in on the site's own page.
3. Tap **Done**. The row shows how many cookies are stored and when they expire.

Your password is never seen by the app. Only the site's session cookies are kept, in the Keychain on this device, and they are sent only to that site over HTTPS. To log out, swipe left on the site's row and tap **Log Out**. Custom sites can also be removed with **Remove**.

## Troubleshooting

**"MD Clipper" doesn't appear in the Share Sheet**
Scroll to the end of the app row → **More** → enable it. Restarting the device can help after first install.

**"No vault folder configured" or the vault status is red**
Open the app and pick the vault folder again. This refreshes the app's permission to write there (it can expire if the folder was moved or renamed).

**Clipped note is missing in Obsidian**
Check the target folder name in Settings. With iCloud Drive, give it a moment to sync, and make sure Obsidian is opening the same vault folder you picked.

**Article is cut off or shows a paywall**
Share from Safari while signed in, or sign in to the site under **Site Logins**. Some sites block automated downloads entirely.

**Images are missing**
Up to 20 images per clip are saved (50 MB total). SVGs, tracking pixels, and embedded data images are skipped. Some sites refuse image downloads from apps.

**OCR text is missing**
Recognized text is included only when text is a significant part of the image (for example screenshots), so incidental text in photos is skipped. You can turn OCR off in Settings.

**Garbled characters**
Some pages use uncommon text encodings. Please report the URL.

## Contact

Report a problem or ask a question by opening an issue at <https://github.com/aerocristobal/obsidian-clipper/issues>. Please include the iOS version, the app version (shown in **About**), and the URL you were clipping if relevant.

Privacy policy: [privacy.md](privacy.md)
