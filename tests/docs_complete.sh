#!/usr/bin/env bash
# A doc set that omits the recovery path is incomplete. This asserts the files
# exist and that each operational topic is actually written down somewhere.
#
# It checks presence, not prose quality: a topic mentioned in passing passes.
# That is deliberate, because the alternative is a test that encodes wording.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL: $1" >&2; exit 1; }

for f in README.md CHANGELOG.md docs/runbook.md docs/vendoring.md; do
  [ -s "$root/$f" ] || fail "missing or empty: $f"
done

for topic in restore rollback tailnet snapshot vendoring; do
  grep -riq "$topic" "$root/docs" "$root/README.md" || fail "no documentation for: $topic"
done

# The idle contract must state what is NOT protected, or an operator will be
# surprised when the box stops under a connected client.
grep -riq "not protected" "$root/README.md" || fail "README does not state what the idle gate does not protect"

echo "docs complete"
