# Markdown Clipper — Architecture

**Version:** 1.0 (shipped) · 1.1 hardening + extraction-quality work merged
**Last updated:** 2026-05-07
**Audience:** developers and reviewers working on the codebase

---

## 1. System overview

Markdown Clipper is a two-target iOS application:

```
┌────────────────────────────────┐     ┌───────────────────────────────────┐
│  ObsidianClipper (main app)    │     │  ClipperExtension (Share Extension)│
│                                │     │                                   │
│  • Onboarding + settings UI    │     │  • Receives shared content        │
│  • Vault folder picker         │     │  • Runs the clipping pipeline     │
│  • About screen                │     │  • Writes to the vault folder     │
└───────────────┬────────────────┘     └───────────────┬───────────────────┘
                │                                      │
                └────────────── App Group ─────────────┘
                      group.com.mmtac.md-clipper
                      (shared UserDefaults,
                       security-scoped bookmark)

                                    │
                                    ▼
                            ┌───────────────┐
                            │  Vault folder │
                            │  (iCloud Drive│
                            │   or local)   │
                            └───────────────┘
```

- The **main app** is a thin SwiftUI settings surface. It never clips — its job is to configure the vault bookmark and toggle clipping options.
- The **share extension** is where all clipping logic lives. It runs in a separate process with a tight memory budget (~120 MB) and must be resilient to being killed by the OS at any time.
- Both targets share settings via an **App Group**. The security-scoped bookmark persisted by the main app is re-resolved by the extension each time it runs.

---

## 2. Targets and modules

### 2.1 `ObsidianClipper/` — main app

| File | Responsibility |
|---|---|
| `ObsidianClipperApp.swift` | `@main` SwiftUI `App` entry. Injects a `ClipperSettings` into the environment. |
| `SettingsView.swift` | Form-based UI with an onboarding banner when no vault is set; shows a green/red vault-reachability indicator. |
| `FolderPickerView.swift` | `UIViewControllerRepresentable` wrapper around `UIDocumentPickerViewController(forOpeningContentTypes: [.folder])`. |
| `AboutView.swift` | Credits + version info. |
| `Assets.xcassets/` | App icon + accent color. |
| `ObsidianClipper.entitlements` | App Group entitlement only. |

### 2.2 `ClipperExtension/` — Share Extension

| File | Responsibility |
|---|---|
| `Info.plist` | Extension manifest. Activation rule matches `public.url`, `public.plain-text`, `public.html`, `public.image`. Declares `Action.js` as `NSExtensionJavaScriptPreprocessingFile`. Has `NSAllowsArbitraryLoads` to allow clipping from HTTP sites. |
| `Action.js` | Runs in Safari's page context; returns `{title, URL, html}` to the extension. |
| `ShareViewController.swift` | Extension principal class. Hosts the SwiftUI UI, owns the clipping `Task`, registers for memory warnings, guarantees single completion. Delegates the actual pipeline to `ClippingPipeline.run(extensionContext:onState:onImageProcessor:)`. |
| `ShareExtensionView.swift` | SwiftUI progress/success/error screen driven by `ShareViewModel`. |
| `ClippingPipeline.swift` | `@MainActor` enum holding the UI-free pipeline orchestrator and the `ClipError` type. Co-located so the test target can compile the pipeline without dragging `ShareViewController` (and its `@Observable` ViewModel) into a test bundle that can't link `SwiftUICore`. |
| `LaunchBeacon.swift` | Idempotent appex-launch signal. First statement of `ShareViewController.viewDidLoad` writes a timestamp + counter to App Group `UserDefaults` and emits an `os_log` notice. Used to diagnose Apple-managed extension-launch failures (e.g. dynamic-link hangs). |
| `WebContentExtractor.swift` | Pulls URL/HTML/text/images out of the `NSExtensionContext`. Handles the Safari `NSExtensionJavaScriptPreprocessingResultsKey` shape via the `com.apple.property-list` UTI (the `public.property-list` UTI string matches nothing on real iOS). Falls back to fetching the page itself if only a URL is present. Handles `<meta charset>` detection. |
| `JSONLDExtractor.swift` | Schema.org Article fast path. Pulls `<script type="application/ld+json">` blocks, walks for `Article` / `NewsArticle` / `BlogPosting` / `ReportageNewsArticle` / `Report` / `LiveBlogPosting` (including `@graph` wrappers and array-shaped types), picks the longest `articleBody`, surfaces the `image` field as URLs, and returns nil for callers to fall through to Readability. |
| `SwiftSoupAdapter.swift` | Translates a SwiftSoup `Document` into the project's bespoke `HTMLNode` tree so all downstream Readability scoring and Markdown conversion work unchanged. The localization point for the parser swap. |
| `ReadabilityExtractor.swift` | Mozilla Readability-inspired DOM scorer. Now backed by `SwiftSoupAdapter.parse` rather than the in-tree `HTMLParser`. Also contains the shared `HTMLParser` and `HTMLNode` types — the byte parser still ships and is used by `HTMLToMarkdown.convert(_ html:)` when no upstream tree exists. |
| `HTMLToMarkdown.swift` | Tree-walking DOM → Markdown renderer. Owns the `[[IMG:N]]` marker injection, marker-survival detection (`findMarkerIndices`), and the marker → `![alt](path)` swap. The `convert(_ html:)` overload uses the in-tree byte parser; `convert(node:)` skips parsing when the caller already has a tree. |
| `ImageProcessor.swift` | Actor. Downloads images to a per-instance scratch directory, runs Vision OCR with a 10% bounding-box coverage filter (drops incidental text like signage), enforces per-clip cumulative size cap, throttles on memory warnings. |
| `FileSaver.swift` | Resolves the security-scoped bookmark, creates the per-article subfolder, moves scratch images into place, writes the `.md`. |
| `ClipResult.swift` | Value type that assembles final Markdown (frontmatter + body + image appendix + OCR appendix). |
| `ClipperExtension.entitlements` | App Group entitlement only. |

### 2.3 `Shared/` — shared between both targets

| File | Responsibility |
|---|---|
| `ClipperSettings.swift` | `@MainActor` `ObservableObject` backed by App Group `UserDefaults`. Exposes the vault bookmark, vault name, target folder, and feature toggles. The bookmark resolution helpers are `nonisolated` and `Sendable`-safe so the extension can call them from any context. |

### 2.4 `ObsidianClipperTests/` — unit tests

| File | Approx. tests | Coverage |
|---|---|---|
| `HTMLToMarkdownTests.swift` | 58 | Converter behavior, marker injection/survival, `srcset` parsing, safety filters |
| `ReadabilityExtractorTests.swift` | 28 | Candidate scoring, title cleaning, inline-link preservation, link-density edge cases, regression fixtures |
| `WebContentExtractorTests.swift` | 35 | Encoding detection, URL-in-text detection, scheme rejection |
| `ImageProcessorTests.swift` | 31 | Magic-byte sniffing, cumulative size cap, scheme rejection, OCR coverage filter |
| `FileSaverTests.swift` | 26 | Filename sanitization incl. Windows reserved names, Unicode |
| `ClipResultTests.swift` | 16 | YAML sanitization, frontmatter emission, image/OCR appendix |
| `JSONLDExtractorTests.swift` | 12 | Single + array + `@graph` shapes, longest-body selection, image-field shapes, entity decoding |
| `ShareViewControllerHarnessTests.swift` | 4 | In-process harness driving `ClippingPipeline.run` end-to-end against a temp vault |
| `PipelineRegressionTests.swift` | 1 (× 11 fixtures) | Corpus-driven regression suite; fails CI on any criterion regression |
| `ExtractionEvalTests.swift` | 1 (eval-only) | Non-failing eval harness; writes per-fixture markdown + summary.json under `eval/<approach>/` |

Plus two helper files that don't carry tests directly:
- `EvalEntryPoint.swift` — eval adapter that routes the corpus through the live pipeline; `approachName` is the eval-output directory key.
- `Support/FakeExtensionContext.swift` — synthetic `NSExtensionContext` subclass with builders for the Safari JS-results shape and URL-only shape, used by the harness suite.

Test target compiles the extension's sources directly via the Sources build phase so `@testable import ClipperExtension` resolves symbols without the test bundle linking `SwiftUICore`.

Total ~210 test methods at time of writing.

---

## 3. The clipping pipeline

Orchestrated by `ClippingPipeline.run`. Production callers (`ShareViewController.performClipping`) supply the real `extensionContext` plus closures that update the view model and retain the active `ImageProcessor` for cancel/cleanup; tests supply a `FakeExtensionContext` and `nil` closures.

```
  LaunchBeacon.emit (first stmt of viewDidLoad)
         │
         ▼
  NSExtensionContext
         │
         ▼
  ┌──────────────────────────┐
  │  WebContentExtractor     │   URL? HTML? plainText? sharedImages?
  │  - detects charset       │
  │  - fetches URL-only shares│
  │  - URL-in-text detection  │
  │  - com.apple.property-list│   ← Safari Action.js carrier
  │    UTI for JS results     │
  └────────────┬─────────────┘
               │ RawContent {title, url, html?, plainText?, sharedImages[]}
               ▼
   isImageOnly?  ──── yes ──→  ImageProcessor.processSharedImages
         │ no                          │
         ▼                             ▼
  ┌──────────────────────────┐
  │  JSONLDExtractor         │   <script type="application/ld+json">
  │  .tryFastPath(html:)     │   Article / NewsArticle / @graph
  │  (≥500 chars articleBody)│   → Result {title, articleBody,
  └────────────┬─────────────┘     articleBodyIsHTML, image URLs}
               │
       HIT ────┴──── MISS
        │              │
        ▼              ▼
  ┌──────────────┐    ┌──────────────────────────┐
  │ Wrap plain   │    │ HTMLToMarkdown           │
  │ text in <p>  │    │ .replaceImgTagsWith      │  Injects [[IMG:N]] markers.
  │ Prepend lead │    │  Markers()               │  Builds markerMap: Int → URL
  │ image (JSON- │    └────────────┬─────────────┘
  │ LD `image`)  │                 │
  │ Mark + conv. │                 ▼
  └──────┬───────┘    ┌──────────────────────────┐
         │            │  ReadabilityExtractor    │   SwiftSoupAdapter parses;
         │            │  .extract(html:url:)     │   Readability scores.
         │            │                          │   Returns articleNode + title.
         │            └────────────┬─────────────┘
         │                         │ if nil OR converted markdown < 100 chars,
         │                         │ fall back to full-HTML conversion.
         │                         ▼
         │            ┌──────────────────────────┐
         │            │  HTMLToMarkdown          │   Tree-walking renderer.
         │            │  .convert(node:) or      │   convert(node:) skips re-parse.
         │            │  .convert(_ html:)       │   convert(_ html:) uses byte parser.
         │            └────────────┬─────────────┘
         └─────────────┬───────────┘
                       │ markdown with [[IMG:N]] markers
                       ▼
  ┌──────────────────────────┐
  │  HTMLToMarkdown          │   Drop URLs whose markers Readability
  │  .findMarkerIndices()    │   stripped, so we don't download
  │  → filter markerMap      │   images that aren't in the article.
  └────────────┬─────────────┘
               │ filtered marker URLs (≤ 20)
               ▼
  ┌──────────────────────────┐
  │  ImageProcessor (actor)  │   Streams to scratch dir;
  │  .process(urls:)         │   runs Vision OCR with 10%
  │  or                      │   coverage filter; enforces
  │  .processSharedImages()  │   50 MB cumulative cap.
  └────────────┬─────────────┘
               │ [ExtractedImage { sourceURL, tempFileURL, filename, ocrText? }]
               ▼
  ┌──────────────────────────┐
  │  HTMLToMarkdown          │
  │  .replaceMarkersWith     │   Swaps [[IMG:N]] → ![alt](images/…).
  │   Images()               │
  └────────────┬─────────────┘
               │ final markdown body
               ▼
  ┌──────────────────────────┐
  │  ClipResult              │   Assembles frontmatter + body +
  │                          │   orphan images appendix + OCR appendix.
  └────────────┬─────────────┘
               ▼
  ┌──────────────────────────┐
  │  FileSaver.save()        │   Resolves bookmark, starts scoped access,
  │                          │   creates per-article folder,
  │                          │   moves scratch images into images/,
  │                          │   writes .md, stops scoped access.
  └────────────┬─────────────┘
               ▼
         success UI → auto-dismiss after 1.5s
```

`Task.checkCancellation()` is called between every stage. On cancel:

1. The clipping task is cancelled.
2. The `ImageProcessor`'s scratch directory is removed asynchronously.
3. `extensionContext.cancelRequest(withError: ClipError.cancelled)` is called.
4. `didComplete` (guarded by `NSLock`) prevents double-completion.

---

## 4. Key design decisions

### 4.1 Why a tree-based HTML → Markdown converter?

The original v1.0 converter used `NSAttributedString(data:options:documentAttributes:)` to parse HTML, then walked the attributed string inspecting font traits, paragraph styles, and `NSTextList` attributes to emit Markdown. In the Share Extension's memory-constrained environment, the HTML importer silently truncated or dropped content on long articles, producing notes that contained only the title and a blockquote link.

**Decision** (commit `9356534`): replace `NSAttributedString` entirely with a pure-Swift tree-walking renderer built on the same `HTMLParser` used by `ReadabilityExtractor`. This eliminated UIKit dependency, removed the silent-truncation failure mode, made the converter deterministic, and allowed unit testing without a UIKit runtime.

### 4.2 Why now use SwiftSoup for parsing (Spike C, merged)?

The original pure-Swift byte-level recursive-descent parser handled the common real-world malformations (implicit closing tags, unquoted attributes, `<br><br>` chains, raw-text `<script>`/`<style>` content) and Story 4.1 made it CJK-friendly via UTF-8 byte-buffer iteration. It worked, but on real-world pages it occasionally truncated or fragmented the tree:

- `fnn-ex-feds` clipped a 948-character body where the actual article was 10961 characters; the byte parser fell off mid-document on a malformation Readability could have scored correctly.
- `fnn-fbi` similarly truncated to 764 characters.

Spike C swapped the parser via `SwiftSoupAdapter`, which translates SwiftSoup's `Document` into the existing `HTMLNode` shape that `ReadabilityExtractor` and `HTMLToMarkdown` already walk. Same scoring, same tree API — just a spec-compliant tree-builder underneath. The post-merge eval flipped `fnn-ex-feds` from 948 → 10961 chars with zero behavioral regressions on the existing 86-test suite. Cost: +5–6 MB universal binary (~+2.5 MB on-device after App Store thinning) and one new SPM dependency (SwiftSoup ≥ 2.7.0).

The byte parser still ships and is still used:

- `HTMLToMarkdown.convert(_ html:)` — the path used when no upstream tree exists (e.g. JSON-LD's wrapped `<p>` body, or the full-HTML fallback when Readability's pick is too narrow).
- The `selfClosingTags` set in `HTMLParser` is still consulted by Readability's preprocessing.

Two parsers coexist deliberately: SwiftSoup gives Readability scoring a correct tree; the byte parser gives the renderer a low-overhead path for the small post-extraction HTML fragments where spec compliance is not the bottleneck.

### 4.2.1 Why a JSON-LD fast path (Spike B, merged)?

When the publisher already declares the article body in `<script type="application/ld+json">` Schema.org `Article` / `NewsArticle` / `BlogPosting` blocks, **the publisher is the authority on what counts as their article body**. There is no scoring gamble. Wired and (per spot-checks) the major newsroom CMSes emit this; in our 11-fixture corpus the fast path fires on Wired and skips on the rest, falling through byte-identically to Readability.

`JSONLDExtractor.tryFastPath`:

1. Pulls every `<script type="application/ld+json">` block (regex on script-tag attributes, permissive on whitespace and quoting).
2. Walks each parsed JSON object recursively, yielding any `@type` matching `Article` / `NewsArticle` / `BlogPosting` / `ReportageNewsArticle` / `Report` / `LiveBlogPosting`. Handles `@graph` wrappers and array-shaped `@type`.
3. Picks the longest `articleBody`. Returns nil if it's < 500 chars (configurable `minBodyChars`).
4. Surfaces `headline`, `description`, `author` (string / `{name}` / array), `publisher.name`, and `image` (string / `{url}` / `{contentUrl}` / array of either).
5. Decides whether `articleBody` is HTML (regex `<[a-zA-Z/]` in the head 200 chars) or plain text.

When the body is plain text (Wired, NYT-style), `ClippingPipeline` wraps it in `<p>` tags and **prepends a synthetic `<img>` tag** built from the JSON-LD `image` field. This re-enters the same marker-injection path, so plain-text articleBody clips still get their hero image. Without this, Wired clips dropped to zero inline images — caught by `min_total_images` floors in the corpus regression suite.

Fast-path hits run ~30–40× faster than Readability on Wired articles (10–13 ms vs 428–475 ms in the eval). Misses fall through unchanged.

### 4.2.2 Why hoist the pipeline out of `ShareViewController` into `ClippingPipeline`?

`ShareViewController` owns a `ShareViewModel` annotated `@Observable @MainActor`. The `@Observable` macro's emitted accessors transitively reference SwiftUI / SwiftUICore type metadata. That's fine in production but causes the test bundle to fail at link time with *"cannot link directly with 'SwiftUICore' because product being built is not an allowed client of it"* whenever a test references the VC.

Hoisting the pipeline into a UI-free `@MainActor enum ClippingPipeline` (in its own file) lets the harness tests (`ShareViewControllerHarnessTests`) drive the full extraction → markdown → save flow in-process against a `FakeExtensionContext` without dragging SwiftUI into the link. Production `ShareViewController.performClipping` is now a thin wrapper that supplies its `extensionContext` and view-model-update closures.

The error type `ClipError` lives in `ClippingPipeline.swift` (not next to the VC) so the test target compiles cleanly without the VC source file.

### 4.2.3 Why a launch beacon?

A class of extension failures is *Apple-managed* — the dynamic linker hangs, the appex is denied, the system silently drops the share-sheet invocation. Symptom: nothing happens when the user taps Share. There's no crash log, no app-side breakpoint, no NSLog. The only way to diagnose this is to know whether the appex's user code ran at all.

`LaunchBeacon.emit` is the first statement of `viewDidLoad`. It writes:

- `last_extension_launch` (ISO8601 timestamp) and `extension_launch_count` (incrementing int) into App Group `UserDefaults`.
- An `os_log notice` under subsystem `com.mmtac.md-clipper.extension`, category `launch`, with the build number.

The Settings screen surfaces both values under "Diagnostics". A stale "Last extension launch" after a Safari share attempt is the diagnostic signal that the appex never reached user code. Idempotent and allocation-light so it can't itself cause a hang.

### 4.3 Why reuse one parse across Readability and Markdown?

Story 2.1 changed `ReadabilityExtractor.extract` to return the winning `HTMLNode` directly (not a serialized HTML string), and `HTMLToMarkdown` gained a `convert(node:)` overload. The old pipeline parsed the HTML twice — once for Readability, once for Markdown — which cost time proportional to article size. The new pipeline parses once and walks the tree.

### 4.4 Why inline image markers?

Before markers, the pipeline batched images at the bottom of each note (`## Images`). This produced notes where a figure and its caption were separated by the full article body. The marker system:

1. `replaceImgTagsWithMarkers(html)` replaces each `<img>` (and `<source>`) with `[[IMG:N]]` as plain text before Readability runs.
2. The markers survive Readability's mutation and the tree-based converter's rendering (they're just text nodes).
3. `replaceMarkersWithImages(markdown, markerToPath)` swaps `[[IMG:N]]` for `![alt](path)` once the images have been downloaded and their final filenames are known.
4. Any marker whose URL didn't download successfully remains in the Markdown as `[[IMG:N]]` — intentionally surfacing the gap rather than silently hiding it.
5. Unreferenced images (e.g. shared directly, not linked in HTML) fall back to the `## Images` appendix.

### 4.5 Why stream images to disk?

Story 4.5 replaced `ExtractedImage.data: Data` with `ExtractedImage.tempFileURL: URL`. Previously the extension held downloaded image bytes in memory until the save step, which combined with Vision's `.accurate` OCR (2–5 MB per image during the request) could push the extension past its budget on image-heavy pages.

Now:
- `URLSession.download(from:)` writes straight to a system temp file.
- `ImageProcessor` moves (or copies on cross-volume) the file into its own scratch directory (`NSTemporaryDirectory() + clipper-<UUID>`).
- `FileSaver.save` uses `FileManager.moveItem` to relocate the file into the vault's `images/` directory.
- OCR opens the file from disk inside an `autoreleasepool`, keeping the `UIImage` and downscaled `CGImage` lifecycles tight.
- On success or cancel, the scratch directory is removed wholesale.

### 4.6 Why throttle concurrency on memory warnings?

Story 4.7: the extension registers for `UIApplication.didReceiveMemoryWarningNotification`. When a warning arrives mid-clip, `ShareViewController` hops onto the image-processor actor and calls `reduceConcurrency()`, which lowers `maxConcurrent` from 3 to 1. Already-running tasks finish normally; only *new* tasks are gated. The refill loops in `process(urls:)` and `processSharedImages` re-check the cap each iteration, so the throttle takes effect immediately. Idle-state warnings are a no-op (processor is nil).

### 4.7 Why penalize link-density at the aggregated score?

The original Readability implementation penalized link-density per-element. On pages where the article body is split across many small sibling containers (e.g. Wired's `ArticlePageChunks` layout, where `BodyWrapper` divs are interleaved with ad slots), a "More from Publisher" related-articles grid could beat the actual body: each summary card had moderate individual score, but once propagated to the grid parent, the sum outscored any single body chunk.

**Fix** (commit `a321bcc`): at winner selection, multiply each candidate's final score by `max(0.05, 1.0 - linkDensity)`. Article bodies (density < 0.1) keep >90% of their score; link-card grids (density > 0.6) lose half or more. Single stray links can't zero out a real candidate thanks to the clamp.

### 4.8 Why preserve inline tags inside paragraphs during post-processing?

Before commit `818185a`, `postProcess` recursively scanned every descendant and removed any child with `linkDensity > 0.5 && text.count < 200`. Recursing into a `<p>` meant every inline `<a>` (density 1.0, short text) was treated as a removable high-link-density block, leaving mid-sentence gaps.

**Fix**: introduce an `inlineTags` set (`a, span, em, strong, b, i, u, s, code, mark, sub, sup, cite, abbr, time, ...`) that is skipped during removal, and an `inlineContentContainers` set (`p, h1-h6, li, blockquote, pre, figcaption, ...`) that short-circuits the recursion. Additionally, negative class/id patterns (`"ad"`, `"nav"`, etc.) are matched on word boundaries so `"lead-in-text-callout"` no longer false-matches `"ad"`.

### 4.9 Why per-article subfolders?

Commit `af5be09`: each clip lives in its own folder (`<Vault>/<Target>/<Title>/`). This means a clip is **movable as a unit** — drag it in Obsidian to reorganize and the images come along. It also sidesteps filename collisions between images from different clips (the short hash prefix still exists as belt-and-braces).

### 4.10 Why a tight security model at ingress?

All URL-producing paths reject non-`http(s)` schemes:

- `WebContentExtractor.fetchHTML` and `isAllowedScheme`
- `ImageProcessor.isFetchableScheme`
- `HTMLToMarkdown.replaceImgTagsWithMarkers` and `extractImageURLs`
- `HTMLToMarkdown`'s link renderer strips `javascript:`, `data:`, `vbscript:` and percent-encodes parentheses in safe URLs

This prevents SSRF-style tricks where a malicious page's `src="file:///etc/passwd"` or `src="javascript:…"` could coerce the extension into reading local files or embedding active content.

### 4.10.1 Why an OCR coverage filter?

Apple Vision is happy to recognize the license plate in a street photo, the name on a placard in a meeting photo, the deli sign behind two people having lunch. None of those help a vault reader; they fill the OCR appendix with snippets that are, at best, irrelevant.

`ImageProcessor.recognizeText(in:)` sums each `VNRecognizedTextObservation`'s normalized bounding-box area (`width * height`) into a coverage fraction. If the fraction is below `textCoverageThreshold = 0.10` — i.e. the recognized text covers less than 10% of the image — we discard the result and emit nil instead of a string. Overlapping boxes slightly over-count, biasing the filter toward keeping borderline cases.

For a screenshot of an article, a slide, a tweet, a code snippet, or any document where text *is* the subject, coverage is well above 10%. For a photo where text is incidental, it's well below. The threshold is logged on every OCR call (`[Clipper.image] OCR coverage=… kept=…`) so we can tune it from real-world clips if needed.

### 4.11 Why YAML value sanitization?

`ClipResult.toMarkdown` normalizes title whitespace (collapsing newlines/tabs/CR into single spaces) and escapes backslashes, double quotes, newlines, CR, and tabs in YAML values. Without this, a page whose `<title>` contained a literal newline could break the frontmatter and silently corrupt subsequent YAML keys.

---

## 5. Concurrency model

The codebase is strict-Sendable clean.

### 5.1 Actor boundaries

| Type | Isolation |
|---|---|
| `ClipperSettings` | `@MainActor` (all property access on main). `resolveVaultURL()` and `resolveVaultBookmark(_:)` are `nonisolated static`. |
| `ClipperSettings.ResolvedVault` | `Sendable` struct. |
| `ClipResult`, `ExtractedImage` | `Sendable` struct. |
| `FileSaver.SaveConfig` | `Sendable` struct; extracts values from `ClipperSettings` on `@MainActor` and can be passed to the `nonisolated` `FileSaver.save`. |
| `ImageProcessor` | `actor`. All mutable state (`maxConcurrent`, `inFlightCount`, `totalBytesDownloaded`, `scratchDirectory`) is actor-isolated. |
| `ShareViewModel` | `@Observable @MainActor`. |
| `ShareViewController` | `final class` (UIKit, main). |
| `HTMLNode` | `@unchecked Sendable`. Rationale: the tree is built synchronously by either `HTMLParser.parse()` or `SwiftSoupAdapter.parse(html:)` (the SwiftSoup path post-processes `setParents` before returning), all mutation (`preprocess`, `postProcess`) completes on the calling actor before the tree is handed off for scoring, and the `_cachedTextContent` memoization field is only written during sequential tree traversal. No cross-actor concurrent mutation occurs. |

### 5.2 Completion / cancel safety

`ShareViewController` guards the extension's completion with an `NSLock` around `didComplete`. `trySetComplete()` atomically checks-and-sets the flag so success and cancel paths can both race to complete but only one wins. On cancel:

- `clippingTask.cancel()` is called.
- The `imageProcessor`'s scratch directory is scheduled for removal in a detached task.
- `extensionContext.cancelRequest` tears down the extension.

### 5.3 Memory-warning handler

The memory-warning observer is a block-based `NotificationCenter` observer, which means its token must be explicitly retained and released. `ShareViewController` keeps the token in `memoryWarningObserver` and removes it in `deinit`.

### 5.4 OCR continuation safety

`ImageProcessor.recognizeText(in:)` uses `withCheckedContinuation`. The original implementation had a double-resume bug (commit `dc69b72`): both the error path and the observations path could call `continuation.resume` if `request.results` was both nil and had an error. The fix guards the entire observations branch with `guard error == nil, let observations = ... as? [VNRecognizedTextObservation]` so exactly one resume happens.

---

## 6. Memory strategy

The Share Extension has a ~120 MB resident memory cap. Violating it results in immediate OS termination. Mitigations:

1. **Stream image downloads to disk.** `URLSession.download` + `moveItem` to scratch directory. No in-memory `Data` blob.
2. **Per-instance scratch directory.** Cleaned up wholesale on success or cancel.
3. **Cumulative image cap.** 50 MB per clip (test-overridable). Oversized singles and cap-exceeders are dropped gracefully — smaller later images still process.
4. **Vision input downscaling.** Images with a longest edge > 2048 px are resized before OCR. `UIGraphicsImageRenderer` with `format.scale = 1` guarantees we downscale to pixel units, not points.
5. **Autoreleasepools around UIKit intermediaries.** `UIImage(contentsOfFile:)` and `CGImage` creation sit inside `autoreleasepool` so they are released at the end of each task rather than piling up until the actor quiesces.
6. **Scoped HTML strings.** `ShareViewController.performClipping()` wraps the large `markedHTML` string in a `do` block so ARC releases it before image processing starts.
7. **Detached article tree from document.** `ReadabilityExtractor` nils the winner's `parent` pointer so ARC can release the rest of the document tree.
8. **`textContent` memoization with invalidation.** `HTMLNode._cachedTextContent` avoids O(n²) recomputation during scoring; cache is invalidated up the parent chain on mutation.
9. **UTF-8 byte-buffer HTML parser** (still used by `HTMLToMarkdown.convert(_ html:)`). Story 4.1 replaced the `String.Index` walker with `ContiguousArray<UInt8>` + `Int` offsets. No per-`peekString` allocation; text/attribute byte ranges are decoded to `String` only once at emission.
10. **JSON-LD fast path bypasses Readability scoring** for a meaningful slice of clips (Wired et al.), avoiding the SwiftSoup tree-builder cost entirely on those pages (10–13 ms vs 300+ ms).
11. **Marker-survival filter before download.** `HTMLToMarkdown.findMarkerIndices(in:)` returns the `[[IMG:N]]` markers still present in the *converted* markdown. URLs whose markers Readability stripped are dropped before the image processor seeds downloads, so we don't fetch images that aren't part of the chosen article subtree.
12. **Memory-warning throttle.** Drops image-processing concurrency from 3 to 1 when iOS posts a warning.
13. **20-image cap per clip.** Hard limit in `ClippingPipeline.run` (filtered marker URLs are sliced to `prefix(20)`).
14. **10-image cap for shared images.** Hard limit in `processSharedImages`.
15. **2 MB HTML cap.** `HTMLToMarkdown.convert` truncates overlong HTML rather than attempting to parse pathological documents.

---

## 7. Security boundaries

| Boundary | Enforcement |
|---|---|
| Fetching external URLs | Only `http(s)`. Rejected in `WebContentExtractor.isAllowedScheme` and `ImageProcessor.isFetchableScheme`. |
| Links rendered into Markdown | `javascript:`, `data:`, `vbscript:` schemes stripped (text-only fallback). Parentheses percent-encoded. |
| Image URLs in HTML | `data:` URLs rejected; tracking pixels and SVGs skipped by heuristic. |
| YAML frontmatter | Values are double-quoted and escape backslash, double-quote, `\n`, `\r`, `\t`. Title whitespace is collapsed so control characters can't break YAML. |
| Filename injection | `sanitizeFilename` removes `/:*?"<>|\`, collapses dashes, strips leading/trailing dots, caps at 200 chars, suffixes Windows-reserved names with `_`. |
| Vault file I/O | Bracketed by `startAccessingSecurityScopedResource` / `stopAccessingSecurityScopedResource`. Stale bookmarks are refreshed in-scope. |
| User-agent | Fixed mobile Safari string. No identifying data. |

---

## 8. Testing strategy

### 8.1 Unit tests

~210 tests across 10 files under `ObsidianClipperTests/`. Runs against the `iPhone 16` simulator via `xcodebuild -scheme ObsidianClipper test`. The test target compiles the extension's sources directly (configured via the test target's Sources build phase) so `@testable import ClipperExtension` resolves symbols without dragging `SwiftUICore` into the test bundle's link.

The `ShareViewController.swift` source file is intentionally **not** in the test target's compile list — its `@Observable` view model would force a `SwiftUICore` link the test bundle can't satisfy. The pipeline orchestrator (`ClippingPipeline.swift`) and its `ClipError` are co-located so they compile cleanly into tests.

### 8.2 Regression fixtures

`ReadabilityExtractorTests` contains self-contained regression fixtures for real layouts that once produced bad output:

- Wired `ArticlePageChunks` — must pick the chunked body, not the related-articles grid.
- Wired horror-movie review — must not pick the `SummaryCollectionGridItems` sidebar.
- Slate, Electrek — typical `<article>` / `<main>` wrappers.
- Inline-link preservation — `<p>` with inline `<a>` must not have its links stripped.
- Negative-pattern word-boundary check — `"lead-in-text-callout"` must not false-match `"ad"`.

### 8.3 Corpus-driven regression suite

`PipelineRegressionTests` runs the full `EvalEntryPoint.extract` pipeline (JSON-LD fast path → SwiftSoup-backed Readability → markdown converter) against every `.html` fixture in `Tests/Fixtures/extraction-corpus/` and asserts each fixture's `*.expected.json` criteria:

- `title_contains` — title needle (case-insensitive)
- `must_contain` / `must_not_contain` — markdown-body substring requirements (typically nav/recirc bleed-through canaries)
- `min_body_chars` — non-whitespace character floor
- `min_total_images` / `max_total_images` — surviving `[[IMG:N]]` marker count bounds (`min_total_images` caught the JSON-LD plain-text-body image regression)
- structural sanity — markdown must not contain `<p>`, `<div>`, `<script`, `<style`

Failures inside a fixture are accumulated, not fast-failed, so a single broken fixture does not mask others. Each fixture is wrapped in `XCTContext.runActivity` for grouping in Xcode.

The corpus fixtures (11 at time of writing) cover long-form articles (Wired, Electrek, FNN), feed-style indexes (Hacker News, Daring Fireball), heavy front pages (The Verge), and the canonical baseline (`example.com`).

### 8.4 In-process harness suite

`ShareViewControllerHarnessTests` drives `ClippingPipeline.run` end-to-end with a `FakeExtensionContext` and a temp-directory vault, asserting the pipeline produces the expected `.md` file in the right per-article subfolder. This catches regressions in:

- `WebContentExtractor.extract(from:)` against the Safari `NSExtensionJavaScriptPreprocessingResultsKey` shape (the `com.apple.property-list` UTI fix).
- Pipeline branch selection (JSON-LD vs Readability) and marker filtering.
- `FileSaver` integration with a security-scoped bookmark.
- Cancellation mechanics.

It does *not* catch Apple-managed extension-launch failures (dynamic-link hangs, signing rejections); those need real Safari + XCUITest.

### 8.5 Eval harness

`ExtractionEvalTests` is non-failing — it runs the corpus through `EvalEntryPoint.extract`, scores against the same criteria as `PipelineRegressionTests`, and writes `eval/<approach>/<fixture>.md` + `eval/<approach>/summary.json`. The `approach` key (`EvalEntryPoint.approachName`) defaults to `"main"` on this branch; spike branches override it (`master`, `jsonld-fastpath`, `swiftsoup`, etc.) so each branch's output sits side-by-side under `eval/`.

`eval/comparison.md` is the cross-branch comparison matrix that informed the merge decision; `eval/recommendation.md` documents the rationale.

### 8.6 Manual testing

Required for:

- Actual Share Sheet integration (can't be exercised in XCTest).
- Memory-pressure behavior on device (can be simulated but best verified on-device).
- Security-scoped bookmark lifecycle across app kills and iOS restarts.
- iCloud Drive sync timing.

---

## 9. Build and run

See `CLAUDE.md` for canonical commands. Summary:

```bash
# Build both targets
xcodebuild -scheme ObsidianClipper \
  -destination 'platform=iOS Simulator,name=iPhone 16' build

# Run tests
xcodebuild -scheme ObsidianClipper \
  -destination 'platform=iOS Simulator,name=iPhone 16' test
```

The main app scheme `ObsidianClipper.xcscheme` is checked in with a configured test action so Xcode Cloud and local runs share the same configuration.

---

## 10. Outstanding architectural risks

| Risk | Mitigation / status |
|---|---|
| **SwiftSoup is now in the share-extension link.** Any dynamic-link or initialization hang in SwiftSoup would manifest as the appex never reaching user code. | `LaunchBeacon` makes this observable: a stale `last_extension_launch` after a Safari share-sheet attempt is the diagnostic signal. The branch `debug/revert-swiftsoup-from-extension` exists as a documented escape hatch. |
| **The byte-level HTML parser** still ships and is still used for the markdown-renderer path (`HTMLToMarkdown.convert(_ html:)`). It is not spec-compliant. | The parser handles the common real-world patterns, and the renderer's working set is small post-extraction HTML where edge cases are rare. Edge cases captured as regression tests when they surface. |
| **Readability scoring is a heuristic.** Some layouts may still lose to recirc widgets. | The 100-char Markdown threshold triggers a full-HTML fallback when Readability's pick is clearly too narrow. The corpus regression suite captures known-bad layouts (`electrek-bluetti`, `fnn-fbi` recirc bleed) so silent regressions break CI. |
| **JSON-LD fast path is publisher-dependent.** Coverage on a wider corpus is unmeasured; only Wired hits in the current 11 fixtures. | Free fall-through on misses (byte-identical to Readability). `min_body_chars = 500` guard avoids the case where JSON-LD has a stub body. |
| **OCR coverage threshold is hard-coded** at 0.10 (10%). Different image styles may need different thresholds. | Threshold is logged on every OCR call so we can tune from real-world clips. Tracked separately. |
| **Vision OCR latency on long pages with many images** can push total clip time toward the user-perceptible limit. | Concurrency cap of 3; cumulative image cap of 50 MB; downscale-before-OCR; 20-image hard cap; coverage filter discards before string allocation downstream. |
| **Security-scoped bookmark staleness across iCloud Drive reorgs.** | `FileSaver.save` detects staleness and schedules an in-scope refresh; next clip picks up the new bookmark. |
| **Strict-Sendable drift** as new Swift concurrency warnings are introduced in future Xcode releases. | Build settings keep strict concurrency on; the CI build fails on new warnings. |
| **`@unchecked Sendable` on `HTMLNode`** is a load-bearing assumption — any future code that shares a node across actors concurrently would violate it. | Documented at the declaration site. Code review should flag any cross-actor HTMLNode use. |
| **Recirc/related bleed-through** still survives extraction on `electrek-bluetti` and `fnn-fbi` (corpus 4/6 → 4/11 with the larger corpus). Tracked in `eval/recommendation.md`. | Planned fix: targeted post-processing strip for `class*="recirc"` / `class*="related"` / `class*="trending"` subtrees plus phrase-prefixed paragraphs (`Subscribe to`, `Follow us on`). ~30 LOC. |

---

## 11. Glossary

- **App Group** — iOS mechanism for sharing data (UserDefaults, files) between a main app and its extensions. Here: `group.com.mmtac.md-clipper`.
- **Security-scoped bookmark** — an opaque `Data` blob from `URL.bookmarkData()` that encodes file-system access permission granted by the user via the document picker. Must be re-resolved and bracketed by `startAccessingSecurityScopedResource` on each use.
- **Readability** — Mozilla's open-source article-extraction algorithm. We ship an independent Swift reimplementation inspired by it, not a port. The scorer now runs on a SwiftSoup-parsed DOM via `SwiftSoupAdapter`.
- **JSON-LD / Schema.org Article fast path** — `JSONLDExtractor.tryFastPath`. Pulls `<script type="application/ld+json">` blocks looking for `Article` / `NewsArticle` / `BlogPosting` (and `@graph`-wrapped variants), and uses the publisher's own `articleBody` when ≥ 500 chars. Skips Readability scoring entirely on hits; falls through unchanged on misses.
- **Marker / `[[IMG:N]]`** — placeholder text injected in place of `<img>` tags before extraction, swapped back for `![alt](path)` after images are downloaded. Survives HTML mutation because it's a plain text node. Markers stripped by Readability are detected via `findMarkerIndices` and the corresponding URLs are filtered out before download.
- **Marker survival** — the act of detecting which `[[IMG:N]]` markers are still present in the post-conversion markdown, so we only download images that are actually in the chosen article subtree.
- **`SwiftSoupAdapter`** — bridge that converts a SwiftSoup `Document` into the existing `HTMLNode` tree, localizing the parser swap so downstream Readability + markdown code is unchanged.
- **`ClippingPipeline`** — UI-free `@MainActor` enum that holds the actual extraction → markdown → save flow plus the `ClipError` type. Production drives it from `ShareViewController`; tests drive it from a `FakeExtensionContext`.
- **`LaunchBeacon`** — idempotent appex-launch signal. First statement of `ShareViewController.viewDidLoad` writes a timestamp + counter to App Group `UserDefaults` and emits an `os_log notice`. Surfaced in the Settings → Diagnostics row.
- **Scratch directory** — a per-`ImageProcessor` temporary directory under `NSTemporaryDirectory()`. Holds downloaded and shared images until `FileSaver` moves them into the vault.
- **OCR coverage filter** — the area-fraction check in `ImageProcessor.recognizeText(in:)` that drops Vision results when recognized text covers less than 10% of the image, so incidental text (signage, license plates) doesn't fill the OCR section.
- **Action.js** — Safari JavaScript preprocessing file that captures the live page DOM and hands it to the extension. Carrier UTI is `com.apple.property-list` (the `public.property-list` UTI string matches nothing on real iOS).
- **Extraction corpus** — `Tests/Fixtures/extraction-corpus/`. 11 real-world page fixtures (HTML + `.url` + `.expected.json`) used by `PipelineRegressionTests` (failing) and `ExtractionEvalTests` (eval-only).
