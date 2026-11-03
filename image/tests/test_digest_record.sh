#!/usr/bin/env bash
# image/tests/test_digest_record.sh
#
# The digest record is the rollback record, so its shape is checked, not assumed.
# The first lines are a comment header; exactly one line must be a real digest.
#
# The unbuilt state is explicit. An earlier version shipped a placeholder of
# sixty-four zeros, which matched this regex, so the guard passed on a repo that
# had never built an image. PENDING is not a digest and never can match, so the
# distinction between "no image yet" and "a real digest" is unambiguous.
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
f="$here/prod-digest.txt"
fail() { echo "FAIL: $1" >&2; exit 1; }

[ -s "$f" ] || fail "digest record is empty"

if grep -qx 'sha256:PENDING-FIRST-BUILD' "$f"; then
  echo "SKIP: no image promoted yet (prod-digest.txt is PENDING)"
  exit 0
fi

count="$(grep -cE '^sha256:[0-9a-f]{64}$' "$f" || true)"
[ "$count" = "1" ] || fail "digest record must hold exactly one digest, found $count"

# Reject the all-zeros sentinel even if it ever comes back: a digest of zeros is
# not a real image, and treating it as one makes rollback silently wrong.
grep -qx "sha256:$(printf '0%.0s' $(seq 64))" "$f" \
  && fail "digest record still holds the all-zeros placeholder"

echo "digest record is well formed"
