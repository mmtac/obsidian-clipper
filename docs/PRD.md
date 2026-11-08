# Markdown Clipper — Product Requirements Document

**Version:** 1.0 (shipped) · 1.1 hardening in progress
**Last updated:** 2026-04-16
**Status:** Active

---

## 1. Executive summary

Markdown Clipper is an iOS app that saves web pages, shared text, and images into an [Obsidian](https://obsidian.md) vault as clean Markdown notes. It ships with a system Share Extension that accepts content from Safari and any other app with a Share button, then produces a self-contained per-article folder containing the Markdown note and any extracted images.

The app writes `.md` files directly into the user's vault folder via iCloud Drive or local Files storage — **no Obsidian plugin, server, or account is required**.

---

## 2. Problem statement

Obsidian users who read on iPhone and iPad have no first-party way to capture web content into their vault. Existing options have significant drawbacks:

| Option | Limitation |
|---|---|
| Copy/paste into Obsidian mobile | Loses structure, images, and authenticated content |
| Desktop browser extensions | Not available on iOS |
| Third-party clippers that require a server | Privacy concern, extra cost, offline-unfriendly |
| Read-later apps (Pocket, Readwise) | Content lives outside the vault; still needs export |

A user reading an article behind a login wall on their phone should be able to tap **Share → MD Clipper** and end up with a clean, linked, searchable Markdown note in their vault — within seconds, with no network hop to a third-party service.

---

## 3. Goals and non-goals

### 3.1 Goals

1. **One-tap capture from anywhere.** The Share Extension appears in every iOS app's Share Sheet, not just Safari.
2. **Clean Markdown output.** The saved note should look like a hand-written Markdown note, not a blob of converted HTML.
3. **Preserve authenticated content.** Articles behind login walls must be captured as the user sees them.
4. **Self-contained clips.** Each clip is a folder containing its own `.md` and `images/` subfolder, so a note plus its images move as a unit.
5. **Privacy by construction.** Clipping happens on-device. No external server sees the content.
6. **Survive the Share Extension's memory budget.** iOS Share Extensions are capped near ~120 MB; clipping must not crash on long articles or image-heavy pages.

### 3.2 Non-goals

- **Full Obsidian-plugin parity.** We do not implement wikilinks, backlinks, templates, tag parsing, or anything beyond producing a Markdown file on disk.
- **Cloud sync or multi-device state.** The vault's existing sync layer (iCloud Drive, Obsidian Sync, Syncthing, etc.) handles device synchronization.
- **A note-editing surface.** The app itself only exposes settings; clipping happens entirely in the extension.
- **A macOS / iPadOS-first product.** iPad is supported incidentally via iOS compatibility. There is no Mac Catalyst or dedicated macOS build.
- **Automatic article categorization, tagging, or AI summarization.** Out of scope for v1.x.

---

## 4. Users and usage

### 4.1 Personas

- **Primary — "Vault-first reader."** Heavy Obsidian user, curates a personal knowledge vault, reads long-form articles on iPhone throughout the day, wants everything they read to flow into the vault's Inbox folder for later review.
- **Secondary — "OCR archivist."** Screenshots things (tweets, slide decks, physical documents) and wants the text content extracted and saved alongside the image for later search.

### 4.2 Usage patterns

- Share from Safari while reading an article → Markdown note with images lands in `Vault/Inbox/<Article Title>/`.
- Share a URL from Twitter/X, Reddit, Messages → extension fetches the page and produces a note.
- Share a screenshot from Photos → image saved with OCR-extracted text as a blockquote inside the `.md`.

---

## 5. Feature set

### 5.1 Shipped (v1.0)

#### F-1 — Share Extension in every app
Available from Safari, Messages, Mail, Photos, X/Twitter, Reddit, Mastodon, and any other app that surfaces a Share button.
- Activation rule matches on `public.url`, `public.plain-text`, `public.html`, `public.image`.

#### F-2 — Safari DOM capture via Action.js
Safari's JavaScript preprocessing hook runs in the page context and hands the Share Extension the live `document.documentElement.outerHTML`, `document.title`, and `window.location.href`. This preserves authenticated sessions and post-JavaScript content.

#### F-3 — Readability-style article extraction
A Mozilla Readability–inspired scorer walks the parsed DOM, assigns scores to candidate containers based on paragraph count, comma count, text length, and class/id patterns, penalizes link-density, and picks the highest-scoring subtree as the article body. Navigation, sidebars, ads, related-articles grids, and cookie banners are excluded.

#### F-4 — Tree-based HTML → Markdown conversion
Pure-Swift DOM walker emits Markdown for:

| Element | Markdown |
|---|---|
| `<h1>`–`<h6>` | `#` through `######` |
| `<strong>`, `<b>` | `**text**` |
| `<em>`, `<i>` | `_text_` |
| `<s>`, `<del>`, `<strike>` | `~~text~~` |
| `<code>` (inline) | `` `text` `` |
| `<pre>` / `<pre><code>` | fenced code block |
| `<ul>`, `<ol>`, `<li>` | nested `- ` / `1. ` with 2-space indent |
| `<blockquote>` | line-prefixed `> ` |
| `<table>` | Markdown table syntax |
| `<a href>` | `[text](url)` — `javascript:`, `data:`, `vbscript:` schemes stripped |
| `<img>` | `![alt](path)` placed inline at original position |
| `<br><br>` chains | paragraph break |

#### F-5 — Image extraction
- Parses `src`, `data-src`, `data-lazy-src`, `data-original`, and `srcset` attributes.
- Parses `<picture><source>` elements.
- Picks the largest candidate from `srcset`.
- Deduplicates by absolute URL.
- Limits to 20 images per clip.
- Rejects `data:` URLs, tracking-pixel URLs, and SVGs.
- Streams downloads directly to a per-clip scratch directory on disk (no in-memory `Data` blobs).
- 15-second per-image resource timeout; 10-second request timeout.

#### F-6 — OCR via Apple Vision
- `VNRecognizeTextRequest` with `recognitionLevel = .accurate` and language correction on.
- Images are downscaled so the longest edge is ≤ 2048 px before OCR to keep memory under the extension's budget.
- Recognized text appears as a blockquote under an `## Extracted Text (OCR)` heading in the `.md`.

#### F-7 — Inline image placement
Image tags are replaced with `[[IMG:N]]` markers before Readability extraction, so downloaded images land at their original document positions — not batched at the bottom of the note. Unreferenced or orphaned images fall back to an `## Images` appendix.

#### F-8 — Per-article subfolders
Each clip writes to `<Vault>/<TargetFolder>/<Sanitized Article Title>/` containing:

```
Article Title.md
images/
  ├── <shortHash>-1.png
  └── <shortHash>-2.jpg
```

- Filename-invalid characters replaced with `-`.
- Windows-reserved names (`CON`, `NUL`, `COM1`, etc.) suffixed with `_`.
- Leading/trailing dots stripped.
- Length capped at 200 characters.
- Re-clip of an existing title appends a Unix timestamp to the folder name.

#### F-9 — YAML frontmatter (optional, default on)
```yaml
---
title: "Article Title"
source: "https://example.com/article"
clipped: 2026-04-16
type: article
---
```
Values are sanitized against YAML injection — double quotes, backslashes, newlines, carriage returns, and tabs are escaped.

#### F-10 — Image-only shares
Photos, Screenshots, and any directly shared image → saved to the vault with OCR applied. Title defaults to `Clipped Image — <YYYY-MM-DD HH.mm>`.

#### F-11 — URL-in-text detection
Apps that share a URL as plain text (X/Twitter, Reddit, Messages) are handled via `NSDataDetector`: the first `http(s)` URL is detected and fetched.

#### F-12 — Character encoding detection
1. Content-Type `charset=` header.
2. HTML `<meta charset>` / `<meta http-equiv="Content-Type">` parsed from the first 1 KB of body bytes.
3. Fallback to UTF-8.

Supported encodings: UTF-8, ISO-8859-1, ISO-8859-2, ISO-8859-15, Windows-1251, Windows-1252, ASCII, UTF-16, Shift_JIS, EUC-JP.

#### F-13 — First-launch onboarding
When `vaultBookmark` is unset, the settings screen shows a banner guiding the user to pick their vault folder. A green/red status indicator next to the vault path reflects whether the bookmark still resolves.

#### F-14 — Security-scoped bookmarks
The vault folder is stored as a security-scoped bookmark so the Share Extension can write to it across launches. The bookmark is automatically refreshed (while scoped access is held) when it becomes stale.

### 5.2 In progress (v1.1 hardening)

Per the motes-tracked v1.1 epic, landed on `main` at time of writing:

- **Story 1.2** — `<meta charset>` fallback in `WebContentExtractor` ✅
- **Story 1.3** — stale security-scoped bookmark refresh via detached `@MainActor` task ✅
- **Story 2.1** — pass DOM tree from Readability to Markdown (removes redundant reparse) ✅
- **Story 2.2** — marker injection now captures `<source>`/`srcset` URLs in a single pass ✅
- **Story 3.1** — reject non-`http(s)` URL schemes across all ingress points ✅
- **Story 3.2** — 50 MB cumulative image-size cap with per-image oversize guard ✅
- **Story 4.1** — HTMLParser converted to UTF-8 byte-buffer iteration (CJK perf) ✅
- **Story 4.4** — `HTMLNode.textContent` memoized with parent-chain invalidation ✅
- **Story 4.5** — stream images to disk instead of in-memory `Data` ✅
- **Story 4.7** — throttle image processor concurrency on memory warnings ✅
- **Story 6.2** — `HTMLNode` annotated `@unchecked Sendable` under strict concurrency ✅

**Outstanding / deferred** — see `.memory/` motes for exact status; notable items include a 2x-CJK benchmark for Story 4.1 AC #4 and additional end-to-end Readability accuracy tests.

---

## 6. User stories (BDD)

### 6.1 Story — Capture an article from Safari

**In order to** preserve an article I'm reading for later reference
**As a** vault-first reader
**I want** to save the live page as a clean Markdown note with its images

**Scenarios:**

```gherkin
Scenario: Clip an article from Safari
  Given the vault is configured and accessible
  And I am reading an article in Safari
  When I tap Share and select "MD Clipper"
  Then a note titled "<article title>" is saved to Vault/Inbox/<article title>/
  And the note contains the article body as Markdown
  And images appear inline at their original positions
  And the frontmatter includes the source URL and clip date

Scenario: Clip an article behind a login wall
  Given I am logged into a paywalled site in Safari
  When I tap Share → MD Clipper
  Then the saved Markdown contains the authenticated content I could see
  And no second fetch to the origin is made

Scenario: Re-clip an article with the same title
  Given "Vault/Inbox/Example Article/Example Article.md" already exists
  When I clip a page titled "Example Article"
  Then a new folder "Example Article-<unix-timestamp>" is created
  And the original clip is untouched
```

### 6.2 Story — Share a URL from a non-Safari app

**In order to** save something I received in a message or social feed
**As a** vault-first reader
**I want** MD Clipper to handle URLs shared as plain text

```gherkin
Scenario: URL shared as plain text
  Given I have a message containing "Check this out: https://example.com/post"
  When I tap Share → MD Clipper on that message
  Then the extension detects the URL
  And fetches the page
  And saves a Markdown note for that page
```

### 6.3 Story — Clip a screenshot

**In order to** keep the text content of things I screenshot
**As an** OCR archivist
**I want** screenshots to land in the vault with their text extracted

```gherkin
Scenario: Share a screenshot from Photos
  Given a screenshot containing readable text
  When I tap Share → MD Clipper in Photos
  Then the image is saved under Vault/Inbox/Clipped Image — <date>/images/
  And the recognized text appears as a blockquote in the note
```

### 6.4 Story — Operate within the memory budget

**In order to** clip long articles and image-heavy pages without crashes
**As a** vault-first reader
**I want** the extension to throttle itself under memory pressure

```gherkin
Scenario: System memory warning mid-clip
  Given the extension is downloading and OCR-ing images
  When iOS posts UIApplication.didReceiveMemoryWarningNotification
  Then the image processor drops its concurrency cap to 1
  And already-running tasks complete normally
  And already-produced images are preserved in the final note

Scenario: Extremely large cumulative image payload
  Given a page whose images total > 50 MB
  When images are downloaded
  Then individual images over 50 MB are skipped
  And after the cumulative cap is reached, further images are skipped
  And the note is still saved with whatever images fit under the cap
```

### 6.5 Story — Cancel mid-clip

**In order to** recover if a page is taking too long
**As a** vault-first reader
**I want** the Cancel button to stop the clip and clean up

```gherkin
Scenario: Cancel during image download
  Given the extension is processing a page
  When I tap Cancel
  Then no .md file is written
  And the image scratch directory is removed
  And the extension dismisses
```

### 6.6 Story — First launch onboarding

**In order to** get the extension to work the first time
**As a** new user
**I want** the app to tell me exactly what to do

```gherkin
Scenario: No vault configured
  Given I have never picked a vault folder
  When I open the Markdown Clipper app
  Then an orange onboarding banner is shown
  And tapping "Select Vault Folder" opens the document picker
  And after picking a folder, the banner is replaced with the normal settings
```

---

## 7. Quality attributes / non-functional requirements

| Attribute | Requirement |
|---|---|
| **Memory** | Peak resident memory during a clip must stay under ~120 MB (the Share Extension cap). Memory warnings must be handled gracefully. |
| **Concurrency** | All shared state is `@MainActor` or `actor`-isolated. `ClipperSettings` is `@MainActor` with `nonisolated` bookmark accessors. Strict-Sendable build-clean. |
| **Security** | Non-`http(s)` URL schemes are rejected at every ingress. `javascript:`, `data:`, `vbscript:` links are stripped from output. YAML values are escaped. The user-agent is a standard mobile Safari string. Security-scoped bookmarks bracket all file I/O. |
| **Performance** | HTML parsing is UTF-8 byte-buffer based (no `String.Index` iteration). `textContent` is memoized per-node. Typical article clips complete in < 3 seconds on an iPhone 14 on Wi-Fi. |
| **Reliability** | Double-completion of the extension context is prevented by `NSLock`. Task cancellation is checked between every pipeline stage. The Vision OCR continuation is guaranteed to resume exactly once. |
| **Privacy** | All processing is on-device. No analytics, no crash reporting to third parties, no outbound network calls except fetching the page itself (for URL-only shares) and its images. |
| **Accessibility** | The settings and share UIs use standard SwiftUI controls with automatic Dynamic Type and VoiceOver support. |
| **Localization** | English only in v1.x. Content encoding supports major Western European and East Asian charsets. |

---

## 8. Constraints

- **iOS 17.0+.** Uses the Observation framework (`@Observable`), new SwiftUI APIs, and modern Vision APIs.
- **Xcode 15.4+.**
- **Share Extension memory cap** (~120 MB resident). Dictates the streaming-to-disk image pipeline, the 20-image clip limit, and Vision downscaling.
- **App Group** (`group.com.mmtac.md-clipper`) required for settings to flow between main app and extension.
- **NSAllowsArbitraryLoads = true** in the extension's `Info.plist`, because users legitimately clip from HTTP sites behind corporate VPNs and the extension is a user-initiated fetcher, not a background network component.
- **Vault must be picked via UIDocumentPickerViewController.** iOS does not grant sandboxed apps arbitrary file-system access; the user's folder choice is the only way in.

---

## 9. Success metrics

Because Markdown Clipper is a no-telemetry app, success metrics are observed indirectly:

- **Crash-free clips.** Zero reports of the extension being terminated by the OOM killer on articles that are not pathologically large.
- **Article-body accuracy.** The Readability output captures the full article body on a curated regression set (Wired, Slate, Electrek, NYTimes-style layouts, GitHub READMEs, MDN pages, Substack posts, Markdown-rendered blogs). Tracked by `ReadabilityExtractorTests`.
- **Conversion fidelity.** The Markdown output renders correctly in Obsidian with preserved headings, lists, code blocks, tables, and inline images. Tracked by `HTMLToMarkdownTests`.
- **Time-to-save.** Median clip completes in under 3 seconds for a typical news article on Wi-Fi (observed locally during testing; no telemetry).

---

## 10. Open questions / future work

- **Should we expose the 100-char Readability fallback threshold as a setting?** Some users may prefer the raw page over a too-narrow Readability subtree.
- **PDF clip support.** Currently not in scope — PDFs shared from Files skip the pipeline.
- **Multi-page archive support** (e.g. paginated articles with "next page" links). Out of scope for v1.x.
- **Saving as a single file vs. per-article subfolder.** Currently always per-folder; some users have asked for a toggle.
- **Tag / category suggestions.** Would require on-device ML or heuristics and careful scoping to remain privacy-pure.
- **A CJK benchmark** closing AC #4 of Story 4.1 — landed the UTF-8 byte-buffer parser but has not yet been measured end-to-end against the previous `String.Index` implementation.

---

## 11. Release history

| Version | Date | Notes |
|---|---|---|
| v1.0 | 2026-04-14 | Initial ship: Share Extension, HTML → Markdown, image extraction, OCR, security-scoped bookmarks. |
| v1.0.x (unnumbered) | 2026-04-14 → 15 | Bug-fix wave: entitlements, bookmarks, OCR double-resume, auto-dismiss race, encoding detection, `srcset`/lazy-load, Action.js, `@Observable` migration, Sendable compliance, first test suite. |
| v1.0.y (unnumbered) | 2026-04-15 → 16 | Feature wave: Readability extractor, image-only shares, URL-in-text detection, per-article subfolders, inline image markers, app icon, share-from-any-app. |
| **v1.1 (in progress)** | 2026-04-16 onward | Hardening epic: tree-based converter, streaming images, memory warning throttling, cumulative size cap, UTF-8 byte-buffer parser, link-density penalty at aggregated score, inline-link preservation inside paragraphs. |

---

## 12. References

- Architecture: `docs/ARCHITECTURE.md`
- Motes knowledge graph: `.memory/` (task tracking, design decisions, lessons)
- Project instructions for Claude Code: `CLAUDE.md`
- Source: `ObsidianClipper/` (main app), `ClipperExtension/` (share extension), `Shared/` (settings), `ObsidianClipperTests/` (unit tests)
