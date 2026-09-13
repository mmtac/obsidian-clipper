# Capturing extraction-corpus fixtures

Fixtures live in `Tests/Fixtures/extraction-corpus/` as triples:

- `<slug>.html` — the captured page DOM
- `<slug>.url` — the original URL (one line)
- `<slug>.expected.json` — pass/fail criteria (see existing fixtures for the schema; add `"expect_failure": "paywalled"` for shells that must be rejected by the quality gate)

Discovery is automatic (tests glob `*.html`), so no Xcode project changes are
needed when adding fixtures.

## Anonymous captures (paywall shells, public pages)

Fetch with the same User-Agent the extension uses, so the fixture matches what
`WebContentExtractor.fetchHTML` actually receives:

```bash
UA="Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
curl -sL -A "$UA" "https://www.nytimes.com/..." -o Tests/Fixtures/extraction-corpus/nyt-anon-shell-<slug>.html
echo "https://www.nytimes.com/..." > Tests/Fixtures/extraction-corpus/nyt-anon-shell-<slug>.url
```

## Authenticated captures (NYT, Wired, The Verge)

1. Fetch credentials from 1Password: `op item get "<item name>" --fields username,password`
   (never write credentials to disk).
2. Log in to the site in Chrome (manually or via browser automation).
3. Capture the rendered DOM from the article page — in DevTools or via
   automation: `document.documentElement.outerHTML`.
4. Save as `<site>-authenticated-<slug>.html` + sibling `.url` file.
5. **Sanitize before committing** — strips emails, account IDs, CSRF tokens:

   ```bash
   scripts/sanitize-fixture.sh Tests/Fixtures/extraction-corpus/<slug>.html
   ```

6. Write `<slug>.expected.json` by hand: pick `must_contain` needles from the
   article body (phrases that only appear in the full text, ideally from the
   final paragraphs — they prove the capture wasn't truncated), and set
   `min_body_chars` comfortably below the actual extracted length.

Verify: run the corpus suites.

```bash
xcodebuild -scheme ObsidianClipper -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:ObsidianClipperTests/PipelineRegressionTests \
  -only-testing:ObsidianClipperTests/ContentQualityGateTests test
```
