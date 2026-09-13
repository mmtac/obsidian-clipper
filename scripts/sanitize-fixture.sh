#!/bin/bash
# Sanitize a captured HTML fixture before committing it.
#
# Strips account-identifying data from authenticated page captures — email
# addresses, user/subscriber IDs in inline JSON, CSRF tokens — while keeping
# article text, JSON-LD blocks, and DOM structure intact for extraction
# tests. Idempotent: running it twice produces the same output.
#
# Usage: scripts/sanitize-fixture.sh Tests/Fixtures/extraction-corpus/<slug>.html

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_ROOT}"

FIXTURE="${1:?Usage: scripts/sanitize-fixture.sh <fixture.html>}"

if [[ ! -f "${FIXTURE}" ]]; then
    echo "error: no such file: ${FIXTURE}" >&2
    exit 1
fi

python3 - "${FIXTURE}" <<'PY'
import re
import sys

path = sys.argv[1]
with open(path, encoding="utf-8", errors="replace") as f:
    html = f.read()

original_len = len(html)

# Email addresses anywhere (page chrome greets logged-in users by email).
html = re.sub(
    r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}",
    "redacted@example.com",
    html,
)

# Common account fields in inline JSON state blobs. Preserves the key so the
# JSON stays parseable; replaces only the value.
ACCOUNT_KEYS = [
    "email", "userID", "user_id", "userId", "subscriberId", "subscriber_id",
    "regi_id", "regiId", "accountId", "account_id", "displayName",
    "display_name", "firstName", "lastName", "givenName", "familyName",
]
for key in ACCOUNT_KEYS:
    html = re.sub(
        rf'("{key}"\s*:\s*)"[^"]*"',
        rf'\g<1>"REDACTED"',
        html,
    )
    html = re.sub(
        rf'("{key}"\s*:\s*)\d+',
        rf"\g<1>0",
        html,
    )

# CSRF tokens in meta tags, hidden inputs, or inline JSON.
html = re.sub(
    r'(name="csrf[^"]*"\s+(?:content|value)=")[^"]*(")',
    r"\g<1>REDACTED\g<2>",
    html,
    flags=re.IGNORECASE,
)
html = re.sub(
    r'("csrf[^"]*"\s*:\s*)"[^"]*"',
    r'\g<1>"REDACTED"',
    html,
    flags=re.IGNORECASE,
)

with open(path, "w", encoding="utf-8") as f:
    f.write(html)

print(f"sanitized {path}: {original_len} -> {len(html)} chars")
PY

# Verify nothing identifying survived. The email pattern above rewrites every
# address to redacted@example.com, so any other address is a miss.
LEFTOVER=$(grep -oE "[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}" "${FIXTURE}" | grep -v "redacted@example.com" | sort -u || true)
if [[ -n "${LEFTOVER}" ]]; then
    echo "warning: possible identifying strings remain:" >&2
    echo "${LEFTOVER}" >&2
    exit 1
fi

echo "OK: ${FIXTURE} sanitized"
