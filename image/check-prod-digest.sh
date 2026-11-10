#!/usr/bin/env bash
# image/check-prod-digest.sh
#
# The digest record is the rollback record. A build that promotes :prod without
# updating it leaves the next rollback pointing at the wrong image, and nothing
# fails. This compares the record with the digest just pushed, so a stale record
# fails the run instead of waiting for someone to notice.
#
# Usage: check-prod-digest.sh <pushed-digest>
# The argument is a bare digest (sha256:...) or a RepoDigest (repo@sha256:...).
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
record="${PROD_DIGEST_FILE:-$here/prod-digest.txt}"
fail() { echo "FAIL: $1" >&2; exit 1; }

[ "$#" -eq 1 ] || fail "usage: check-prod-digest.sh <pushed-digest>"
pushed="${1##*@}"
case "$pushed" in
  sha256:*) ;;
  *) fail "the pushed digest is not a sha256 digest: $1" ;;
esac
printf '%s' "${pushed#sha256:}" | grep -qE '^[0-9a-f]{64}$' \
  || fail "the pushed digest is not 64 hex characters: $1"

[ -s "$record" ] || fail "no digest record at $record"

# PENDING means no build has ever been recorded. Only a build runs this check, so
# PENDING is stale here even though the shape test accepts it for a new repo.
if grep -qx 'sha256:PENDING-FIRST-BUILD' "$record"; then
  fail "the record still says PENDING-FIRST-BUILD but :prod is $pushed"
fi

recorded="$(grep -E '^sha256:[0-9a-f]{64}$' "$record" || true)"
[ -n "$recorded" ] || fail "the record holds no digest"
[ "$recorded" = "$pushed" ] \
  || fail "the record holds $recorded but :prod is $pushed"

echo "the digest record matches the promoted image"
