#!/usr/bin/env bash
# image/tests/test_digest_record.sh
# The digest record is the rollback record, so its shape is checked, not assumed.
# The first line is a comment header and the second is the digest, so only lines
# matching the digest format are counted, and every other line is ignored.
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
f="$here/prod-digest.txt"
fail() { echo "FAIL: $1" >&2; exit 1; }
[ -s "$f" ] || fail "digest record is empty"
count="$(grep -cE '^sha256:[0-9a-f]{64}$' "$f" || true)"
[ "$count" = "1" ] || fail "digest record must hold exactly one digest, found $count"
echo "digest record is well formed"
