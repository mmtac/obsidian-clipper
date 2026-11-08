# Obsidian Clipper

An iOS app + Share Extension that clips web pages, text, and images into your [Obsidian](https://obsidian.md) vault as clean Markdown notes — with image extraction and OCR. No Obsidian plugin required.

> **Status:** v1.0 shipped, v1.1 hardening + extraction-quality work merged (JSON-LD fast path, SwiftSoup parser, OCR relevance filter, in-process harness tests). See [docs/PRD.md](docs/PRD.md) and [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the full picture.

> **Not affiliated with Obsidian.** Obsidian Clipper is an independent app and is not affiliated with or endorsed by Obsidian or Dynalist Inc. "Obsidian" is used only to describe compatibility with Obsidian vaults.

---

## What it does

- **Share from anywhere.** The extension shows up in every iOS app's Share Sheet, not just Safari.
- **Capture the live page.** In Safari, a JavaScript preprocessing file (`Action.js`) hands the extension the live DOM — authenticated content and dynamically loaded content included.
- **Take the publisher's word for it when offered.** A JSON-LD fast path checks for Schema.org `Article` / `NewsArticle` blocks and uses the publisher-declared `articleBody` directly when present (Wired, NYT-style sites). Skips the scoring gamble entirely.
- **Fall through to Readability.** When JSON-LD doesn't fire, a Mozilla Readability–inspired scorer running on a SwiftSoup-parsed DOM picks the main content, excluding navigation, ads, sidebars, cookie banners, and related-articles grids.
- **Convert to Markdown.** A pure-Swift tree-walking renderer emits headings, lists, code blocks, blockquotes, tables, links, and inline images.
- **Pull in images.** `srcset`, `data-src`, `data-lazy-src`, `data-original`, and `<picture><source>` are all parsed. Plain-text JSON-LD bodies get their publisher-declared lead image prepended so screenshots aren't dropped. Images are streamed to disk to keep the extension under iOS's memory cap.
- **OCR screenshots — when text is the subject.** Apple Vision (`VNRecognizeTextRequest`) extracts text from images and appends it as a blockquote. A coverage threshold drops OCR output when text is incidental (license plates, signage, name placards in a photo) so the OCR section doesn't fill with noise.
- **Self-contained clips.** Each clip becomes a folder: `<Vault>/<Target>/<Article Title>/` with its own `images/` subfolder — move it in Obsidian and the images go with it.
- **Privacy-first.** Everything runs on-device. No server, no analytics, no telemetry.

---

## Site Logins

Some publishers (NYT, Wired, The Verge, or any site you add yourself) only serve the full article to signed-in subscribers. When you share a link from an app other than Safari, the extension has to re-fetch the page, and without your session it would get the paywalled version.

**Site Logins** lets you sign in to those sites once, inside the app, using a standard in-app web view and your own subscription credentials:

- The app never sees or stores your password — you type it directly into the publisher's own sign-in page.
- After sign-in, only the site's session cookies are kept, in the iOS **Keychain on this device** (shared between the app and its Share Extension via the App Group access group; not synced to iCloud).
- When the extension re-fetches a page, it attaches those cookies **only** to requests for the matching domain, and **only over HTTPS**.
- Nothing is sent to the developer or any third party. You can log out of a site (deleting its cookies) at any time by swiping its row on the Site Logins screen.

Sharing from Safari doesn't need Site Logins — `Action.js` already captures the page as you see it.

---

## Feature list

### Clipping pipeline

- **Share Extension** activated on URLs, plain text, HTML, and images.
- **URL-in-text detection** — shares from X/Twitter, Reddit, Messages often arrive as plain text containing a URL; the extension auto-detects and fetches the page.
- **Character encoding detection** — uses Content-Type `charset=`, falls back to HTML `<meta charset>`, then UTF-8. Supports UTF-8, ISO-8859-1/2/15, Windows-1251/1252, ASCII, UTF-16, Shift_JIS, EUC-JP.
- **JSON-LD / Schema.org `articleBody` fast path** — when the publisher embeds an `Article` / `NewsArticle` / `BlogPosting` block with a substantial body (≥500 chars), the pipeline short-circuits Readability and uses the publisher's canonical body. ~30–40× faster than Readability on the hits, byte-identical fall-through on misses.
- **Lead-image injection for plain-text bodies** — when JSON-LD provides plain prose (no inline `<img>` markup), the publisher-declared `image` URL is prepended as an `<img>` tag so the marker pipeline picks it up identically.
- **Readability-style article extraction** (fall-through) with link-density penalties at both per-element and aggregated scope. Runs on a SwiftSoup-parsed DOM via the `SwiftSoupAdapter` bridge — same scoring, same `HTMLNode` tree shape, but a spec-compliant tree-builder underneath.
- **Tree-based HTML → Markdown converter** that walks an `HTMLNode` tree and emits Markdown. The converter still ships the legacy pure-Swift UTF-8 byte parser as the path used when no upstream tree exists; Readability now hands its winning subtree directly to the converter so most clips parse the document only once.
- **Inline image placement** via `[[IMG:N]]` markers injected before extraction runs and swapped for `![alt](path)` after downloads complete. Markers that didn't survive extraction are filtered out before download to avoid pulling images that weren't part of the chosen article subtree.
- **OCR relevance filter** — Vision text observation bounding boxes are summed; results below a 10% area-coverage threshold are dropped so the OCR section only contains text that's actually the subject of the image.
- **YAML frontmatter** with sanitized values (escapes newlines, quotes, backslashes, tabs; collapses title whitespace to prevent YAML key injection).
- **Per-article subfolders** with a Unix-timestamp suffix on re-clip.
- **Sanitized filenames** — invalid characters replaced, Windows-reserved names (`CON`, `NUL`, `COM1-9`, `LPT1-9`) suffixed, leading/trailing dots stripped, length capped at 200 chars.
- **Launch beacon** — first statement of `viewDidLoad` writes a timestamp + counter to App Group `UserDefaults` and the unified system log. The Settings screen surfaces "Last extension launch" + "Total launches" so the user can confirm the appex is actually starting (vs. failing to dynamic-link).

### Markdown conversion

| Element | Markdown output |
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
| `<a href>` | `[text](url)` — `javascript:`, `data:`, `vbscript:` stripped, parens percent-encoded |
| `<img>` | `![alt](path)` placed inline at original position |
| `<br><br>` chains | paragraph break |
| `<hr>` | `---` |

### Safety and hardening

- **HTTP(S)-only** at every network ingress. `file://`, `javascript:`, `ftp:`, `data:` rejected.
- **Dangerous link schemes** stripped from Markdown output.
- **Memory-warning throttling** — `UIApplication.didReceiveMemoryWarningNotification` drops the image processor's concurrency cap from 3 to 1 mid-clip.
- **Streamed image downloads** — bytes go straight to a per-clip scratch directory on disk, never held in memory.
- **50 MB cumulative image cap** per clip with a per-image oversize check; smaller later images still process if an earlier one was too big.
- **Vision input downscaling** — images with a longest edge > 2048 px are resized before OCR.
- **Per-task autoreleasepools** around UIKit/CGImage intermediaries.
- **Security-scoped bookmarks** with in-scope stale refresh.
- **Task cancellation** checked between every pipeline stage.
- **Strict-Sendable clean** — `@MainActor` isolation on settings, `actor`-isolated image processor, `Sendable` value types crossing actor boundaries.
- **Double-completion guard** on the extension context (`NSLock` around `didComplete`).
- **~210 unit tests** across 10 test files, plus an 11-fixture extraction-corpus regression suite that runs the full pipeline against real-world HTML (`PipelineRegressionTests`).

---

## Requirements

- iOS 17.0+
- Xcode 15.4+
- An Obsidian vault synced via iCloud Drive (or stored locally in Files)
- One Swift Package dependency: [SwiftSoup](https://github.com/scinfu/SwiftSoup) (≥ 2.7.0). Resolved automatically by Xcode on first open.

---

## Setup

### 1. Clone and open

```bash
git clone https://github.com/aerocristobal/obsidian-clipper.git
cd obsidian-clipper
open ObsidianClipper.xcodeproj
```

### 2. Configure the App Group

Both targets need the same App Group so settings flow between them:

1. Select the **ObsidianClipper** target → Signing & Capabilities → + Capability → **App Groups**
2. Add `group.com.obsidian.clipper`
3. Repeat for the **ClipperExtension** target
4. Update bundle identifiers to match your development team

### 3. Build and run

1. Select your device or simulator (iPhone 16 recommended)
2. Build the **ObsidianClipper** scheme (builds both targets)
3. On first launch, follow the onboarding banner to pick your vault folder

### 4. Enable the Share Extension

It appears automatically. If it doesn't:

1. Open any app → tap Share
2. Scroll right in the Share Sheet → tap **More**
3. Enable **Clip to Obsidian**

---

## Sharing from any app

The extension works from any iOS app with a Share button. What you get depends on what the source shares:

| Source app | What's shared | What Obsidian Clipper does |
|---|---|---|
| **Safari** | Full page DOM via JavaScript preprocessing | Readability extraction + Markdown + images + OCR |
| **X/Twitter, Reddit, Mastodon, news apps** | URL | Fetches the page, extracts the article, saves Markdown |
| **Messages, Notes** | URL or plain text | Auto-detects URLs in text and fetches the page; plain text saved as-is |
| **Mail** | URL | Fetches and clips the linked page |
| **RSS readers** | URL or HTML | Uses provided HTML when available, else fetches from URL |
| **Photos, Screenshots** | Image(s) | Saves images with OCR-extracted text |

---

## Build and test

```bash
# Build (both targets)
xcodebuild -scheme ObsidianClipper \
  -destination 'platform=iOS Simulator,name=iPhone 16' build

# Run all tests
xcodebuild -scheme ObsidianClipper \
  -destination 'platform=iOS Simulator,name=iPhone 16' test

# Run a single test class
xcodebuild -scheme ObsidianClipper \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:ObsidianClipperTests/HTMLToMarkdownTests test

# Run a single test method
xcodebuild -scheme ObsidianClipper \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:ObsidianClipperTests/HTMLToMarkdownTests/testBoldConversion test
```

---

## Project layout

```
obsidian-clipper/
├── ObsidianClipper/              # Main app target (settings, onboarding)
│   ├── ObsidianClipperApp.swift
│   ├── SettingsView.swift        # Settings form + onboarding banner + vault status + diagnostics
│   ├── FolderPickerView.swift    # UIDocumentPicker wrapper
│   ├── AboutView.swift
│   ├── ObsidianClipper.entitlements
│   └── Assets.xcassets/
│
├── ClipperExtension/             # Share Extension (the real work)
│   ├── ShareViewController.swift     # Entry point; owns clipping Task, memory warnings, cancel
│   ├── ShareExtensionView.swift      # SwiftUI progress/success/error view
│   ├── ClippingPipeline.swift        # @MainActor enum: UI-free pipeline orchestrator + ClipError
│   ├── LaunchBeacon.swift            # Idempotent App Group + os_log launch signal
│   ├── WebContentExtractor.swift     # URL/HTML/text/image extraction, charset detection
│   ├── JSONLDExtractor.swift         # Schema.org Article / NewsArticle fast path
│   ├── SwiftSoupAdapter.swift        # SwiftSoup → HTMLNode tree bridge
│   ├── ReadabilityExtractor.swift    # DOM scorer, HTMLParser, HTMLNode
│   ├── HTMLToMarkdown.swift          # Tree-walking renderer, [[IMG:N]] markers
│   ├── ImageProcessor.swift          # Actor: download + OCR (with coverage filter) + scratch dir
│   ├── FileSaver.swift               # Per-article subfolder writer, bookmark refresh
│   ├── ClipResult.swift              # Frontmatter + body + appendix assembly
│   ├── Action.js                     # Safari JS preprocessing
│   ├── Info.plist                    # Activation rule, ATS, JS preprocessing ref
│   └── ClipperExtension.entitlements
│
├── Shared/
│   └── ClipperSettings.swift     # @MainActor App Group UserDefaults
│
├── ObsidianClipperTests/         # ~210 unit tests across 10 files
│   ├── HTMLToMarkdownTests.swift
│   ├── ReadabilityExtractorTests.swift
│   ├── WebContentExtractorTests.swift
│   ├── ImageProcessorTests.swift
│   ├── FileSaverTests.swift
│   ├── ClipResultTests.swift
│   ├── JSONLDExtractorTests.swift
│   ├── ShareViewControllerHarnessTests.swift   # in-process pipeline harness
│   ├── PipelineRegressionTests.swift           # corpus-driven regression suite
│   ├── ExtractionEvalTests.swift               # non-failing eval harness
│   ├── EvalEntryPoint.swift                    # eval adapter (helper, not a test class)
│   └── Support/FakeExtensionContext.swift      # synthetic NSExtensionContext for harness tests
│
├── Tests/Fixtures/extraction-corpus/   # 11 real-world fixtures (HTML + .url + .expected.json)
│
├── eval/                         # Per-approach eval output (master / B / C / main)
│   ├── comparison.md             # A/B/C extraction-spike comparison + post-merge result
│   ├── recommendation.md         # Decision rationale (B+C merged, A deferred)
│   └── {master,jsonld-fastpath,swiftsoup,main}/  # Per-branch markdown + summary.json
│
├── docs/
│   ├── PRD.md                    # Product requirements, user stories, success metrics
│   └── ARCHITECTURE.md           # Pipeline, design decisions, concurrency, memory, security
│
├── CLAUDE.md                     # Guidance for Claude Code when working in this repo
└── README.md
```

---

## Clipping pipeline

```
Share Sheet input
  → LaunchBeacon.emit           (App Group timestamp + os_log signal — observability)
  → WebContentExtractor         (URL / HTML / text / images; charset detection; URL-in-text)
  → JSONLDExtractor.tryFastPath (Schema.org Article block? short-circuit Readability)
       │ HIT  → wrap plain-text body in <p>; prepend lead image; mark; convert
       │ MISS → fall through ↓
  → HTMLToMarkdown.replaceImgTagsWithMarkers   ([[IMG:N]] markers injected into HTML)
  → ReadabilityExtractor (SwiftSoupAdapter)    (parse + score; pick article subtree)
       │ if winning subtree < 100 chars → fall back to full-HTML conversion
  → HTMLToMarkdown.convert      (tree-walking Markdown renderer)
  → marker-survival filter      (drop URLs whose markers Readability stripped)
  → ImageProcessor              (stream-to-disk downloads + Vision OCR + coverage filter)
  → HTMLToMarkdown.replaceMarkersWithImages    (swap surviving markers for ![alt](path))
  → ClipResult                  (frontmatter + body + orphan images + OCR appendix)
  → FileSaver                   (scoped-resource access + per-article subfolder + write .md)
```

The pipeline lives in `ClippingPipeline.swift` as a UI-free `@MainActor` enum so the in-process harness tests can drive the full flow without pulling SwiftUICore into the test bundle. `Task.checkCancellation()` runs between every stage. On cancel, the image processor's scratch directory is removed and the extension context is cancelled cleanly.

---

## Safari JavaScript preprocessing

`Action.js` runs in Safari's page context before the extension loads and returns:

- `document.title`
- `window.location.href`
- `document.documentElement.outerHTML`

This captures the page the user actually sees — including content behind login walls, post-JavaScript hydration, and the real URL after any redirects. Without Action.js, the extension would have to re-fetch the URL and could get a different page (mobile redirects, paywall, rate limit).

---

## Output format

A clip produces:

```
Inbox/
└── Article Title/
    ├── Article Title.md
    └── images/
        ├── 3f2a-1.png
        └── 3f2a-2.jpg
```

Where the `.md` looks like:

```markdown
---
title: "Article Title"
source: "https://example.com/article"
clipped: 2026-04-16
type: article
---

# Article Title

> [Source](https://example.com/article) — Clipped 2026-04-16

Article body in clean Markdown with inline images...

![3f2a-1](images/3f2a-1.png)

...more paragraphs...

## Images

<!-- only populated for orphaned/unreferenced images -->

---

## Extracted Text (OCR)

### 3f2a-1.png

> Recognized text from the image via Apple Vision...
```

---

## Settings

| Setting | Description | Default |
|---|---|---|
| Vault Name | Display name of your Obsidian vault | _(empty)_ |
| Target Folder | Subfolder within the vault for clips | `Inbox` |
| Vault Folder | Root folder of the vault (picked via Files) | _(not set)_ |
| YAML Frontmatter | Include metadata block at top of each note | On |
| Save Images | Download images to an `images/` subfolder | On |
| OCR on Images | Run Vision text recognition on downloaded images | On |

---

## Troubleshooting

**Extension doesn't appear in the Share Sheet**
- Make sure both targets build successfully.
- On device: Settings → General → VPN & Device Management → trust your dev certificate.
- Scroll right in the Share Sheet → More → enable **Clip to Obsidian**.

**"No vault folder configured" error**
- Open Obsidian Clipper; the onboarding banner walks you through picking a vault folder.
- If the vault status dot is red, the bookmark is stale — re-pick the folder.

**Images not downloading**
- Some sites block non-browser user agents; the extension sends a mobile Safari UA but sites may still refuse.
- Per clip: 20 images max, 50 MB cumulative cap, 15-second per-image timeout.
- `.svg`, `data:` URLs, and tracking pixels are skipped intentionally.

**OCR returns no text**
- Vision works best on printed/rendered text. Photographs of objects and diagrams may not yield useful output.
- Even when Vision recognizes text, results are dropped if the recognized text covers less than ~10% of the image area. This intentionally suppresses incidental text (signage, license plates, name placards) from filling the OCR appendix.

**Settings shows "Last extension launch: Never"**
- The share extension hasn't reached user code yet. If you've shared from Safari and this still says "Never", something is preventing the appex from starting (typically dynamic-link or signing). Check the unified system log filtered by subsystem `com.obsidian.clipper.extension`.

**Content is garbled**
- Charset detection tries Content-Type → `<meta charset>` → UTF-8 fallback.
- If a page uses an unsupported encoding, it falls back to UTF-8 and may show mojibake.

**Extension captures different content than what you see**
- For best results share from Safari; Action.js captures the live DOM.
- Shares from other apps provide a URL that's re-fetched, which may hit a mobile redirect, paywall, or different cache.

**Extension crashes on large pages / image-heavy pages**
- The 2 MB HTML cap, 50 MB cumulative image cap, 20-image cap, Vision downscaling, and memory-warning throttle all exist to keep the extension under iOS's ~120 MB budget. File a report with the URL and a description of what you were clipping if you hit a crash despite these guards.

---

## Documentation

- [docs/PRD.md](docs/PRD.md) — Product requirements, user stories (BDD), success metrics, release history.
- [docs/privacy.md](docs/privacy.md) — Privacy policy.
- [docs/support.md](docs/support.md) — User setup and troubleshooting guide.
- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — Pipeline, module responsibilities, concurrency model, memory strategy, security boundaries, key design decisions.
- [eval/comparison.md](eval/comparison.md) — A/B/C extraction-spike comparison matrix, per-fixture timings, post-merge result.
- [eval/recommendation.md](eval/recommendation.md) — Decision rationale for the B+C merge and the deferred Spike A.
- [CLAUDE.md](CLAUDE.md) — Build/test commands and conventions for Claude Code when working in this repo.

---

## License

[MIT](LICENSE)
