# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Markdown Clipper is an iOS app + Share Extension that clips web pages to an Obsidian vault as clean Markdown notes with image extraction and OCR. It requires no Obsidian plugins — it writes `.md` files directly to the vault folder via iCloud Drive / Files.

## Build & Test Commands

```bash
# Build the main app (includes both targets)
xcodebuild -scheme ObsidianClipper -destination 'platform=iOS Simulator,name=iPhone 16' build

# Run all tests
xcodebuild -scheme ObsidianClipper -destination 'platform=iOS Simulator,name=iPhone 16' test

# Run a single test class
xcodebuild -scheme ObsidianClipper -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:ObsidianClipperTests/HTMLToMarkdownTests test

# Run a single test method
xcodebuild -scheme ObsidianClipper -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:ObsidianClipperTests/HTMLToMarkdownTests/testBoldConversion test
```

Open the project: `open ObsidianClipper.xcodeproj`

## Architecture

**Two targets sharing one settings store:**

- **ObsidianClipper** (main app) — SwiftUI settings UI and onboarding. No clipping logic lives here.
- **ClipperExtension** (Share Extension) — all clipping logic. This is where the real work happens.
- **Shared/** — `ClipperSettings` bridges both targets via App Group (`group.com.mmtac.md-clipper`) UserDefaults.

**Clipping pipeline** (all in `ClipperExtension/`, orchestrated by `ShareViewController.performClipping()`):

1. `WebContentExtractor` — pulls URL/HTML/text/images from `NSExtensionContext` input items
2. `HTMLToMarkdown.replaceImgTagsWithMarkers()` — injects `[[IMG:N]]` markers before Readability strips them
3. `ReadabilityExtractor` — isolates article content from full page HTML (falls back to full HTML if extraction is too short, <100 chars)
4. `HTMLToMarkdown.convert()` — tree-based HTML-to-Markdown conversion using `SwiftSoup`
5. `ImageProcessor` — downloads images (with srcset/lazy-load support) + Vision OCR
6. `HTMLToMarkdown.replaceMarkersWithImages()` — swaps `[[IMG:N]]` markers back to inline `![](images/...)` paths
7. `ClipResult` — assembles final Markdown with frontmatter, body, image refs, OCR sections
8. `FileSaver` — writes `.md` + images to vault, creates per-article subfolder under target folder

**Safari JavaScript preprocessing:** `Action.js` runs in Safari's context to capture the live DOM (including authenticated/dynamic content) before the extension loads. Other apps share a URL that gets re-fetched.

## Key Concurrency Patterns

- `ClipperSettings` is `@MainActor`-isolated with `nonisolated` accessors for bookmark resolution (thread-safe read path)
- `ShareViewModel` uses `@Observable` (iOS 17+ Observation framework), not `@ObservableObject`
- `ShareViewController` uses `NSLock` to guard `didComplete` for double-completion prevention
- `Task.checkCancellation()` is called between pipeline stages so user cancel works promptly
- Images are limited to 20 per clip to avoid memory pressure in the extension's constrained environment

## Share Extension Constraints

- Share Extensions have strict memory limits (~120MB). Large intermediate strings are scoped in `do` blocks so ARC releases them before image processing.
- Security-scoped bookmarks are required to access the vault folder. Callers must bracket file I/O with `startAccessingSecurityScopedResource()` / `stopAccessingSecurityScopedResource()`.
- The extension auto-dismisses 1.5s after success.

## Motes

This project uses motes for all planning, memory, and task tracking. Knowledge is stored in `.memory/`.

Lifecycle hooks automate `mote prime` (session start/resume/compaction) and `mote session-end` (session stop) — do not run these manually.

**See `~/.claude/CLAUDE.md` for the full motes workflow** (task tracking, retrieval, capture, maintenance).

**Do NOT use** markdown files, TodoWrite, TaskCreate, or external issue trackers for tracking work.
