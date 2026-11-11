#!/usr/bin/env bash
# tests/test_gate_cwd.sh
#
# The gate resolved its suites, its script find and its linter pin from $PWD, so
# it only worked from the repo root. This runs the same gate twice, once from the
# root and once from a throwaway directory, and requires the same suite lines and
# a pass from both. Identical suite lines are what rule out a cwd run that found
# a subset, and a failure in a suite that still read $PWD.
#
# The child run skips this suite through VERIFY_INNER=1, or the two calls would
# recurse. The gate prints that skip so it never disappears quietly, and the last
# check fails if a workflow ever sets the variable and skips the suite in CI.
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
gate="$here/tests/verify.sh"
fail() { echo "FAIL: $1" >&2; exit 1; }

[ -x "$gate" ] || fail "no executable gate at $gate"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

from() { # $1 directory to run in, $2 log path
  if ! (cd "$1" && VERIFY_INNER=1 "$gate") >"$2" 2>&1; then
    cat "$2" >&2
    fail "the gate failed when run from $1"
  fi
  grep -qx 'VERIFY: all suites pass' "$2" \
    || fail "the gate did not report a pass when run from $1"
  grep -q '^== shellcheck (' "$2" \
    || fail "the gate did not reach the lint step when run from $1"
  if grep -q '^   FAILED' "$2"; then
    fail "the gate reported a failed suite when run from $1"
  fi
}

from "$here" "$tmp/root.log"
from "$tmp" "$tmp/outside.log"

grep '^== ' "$tmp/root.log" >"$tmp/root.suites"
grep '^== ' "$tmp/outside.log" >"$tmp/outside.suites"
cmp -s "$tmp/root.suites" "$tmp/outside.suites" \
  || fail "the gate ran different suites outside the repo"

# A pass with no suites prints the same final line, so require the work.
runs="$(wc -l <"$tmp/outside.suites")"
[ "$runs" -ge 10 ] \
  || fail "the gate ran only $runs suites from another directory"

if grep -rq 'VERIFY_INNER' "$here/.github/workflows"; then
  fail "a workflow sets VERIFY_INNER, which would skip this suite in CI"
fi

echo "the gate passes from a directory outside the repo"
