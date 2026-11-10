#!/usr/bin/env bash
# image/write-prod-digest.sh
#
# Replace the digest line in prod-digest.txt and keep the comment header. The
# record is rewritten every time :prod moves, so the header must survive.
#
# Usage: write-prod-digest.sh <digest>
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
record="${PROD_DIGEST_FILE:-$here/prod-digest.txt}"
fail() { echo "FAIL: $1" >&2; exit 1; }

[ "$#" -eq 1 ] || fail "usage: write-prod-digest.sh <digest>"
digest="${1##*@}"
case "$digest" in
  sha256:*) ;;
  *) fail "not a sha256 digest: $1" ;;
esac
printf '%s' "${digest#sha256:}" | grep -qE '^[0-9a-f]{64}$' \
  || fail "not 64 hex characters: $1"
[ -s "$record" ] || fail "no digest record at $record"

# Build the new text in memory first, then replace the record atomically. Every
# digest line after the first is dropped; the header is kept.
new="$(awk -v d="$digest" '
  /^sha256:/ { if (!done) { print d; done = 1 }; next }
  { print }
  END { if (!done) print d }
' "$record")" || fail "could not rewrite $record"
printf '%s\n' "$new" > "$record.new"
mv "$record.new" "$record"

echo "recorded $digest"
