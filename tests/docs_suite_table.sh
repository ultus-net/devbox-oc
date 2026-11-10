#!/usr/bin/env bash
# tests/docs_suite_table.sh
#
# The README suite table is a hand-written list, so it drifts from the gate:
# six suites once ran in tests/verify.sh without a row, and the table still
# claimed to be the list. Read both documents and compare them, so a suite
# added to the gate without a row, or a row whose suite was deleted, fails here.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
verify="$root/tests/verify.sh"
readme="$root/README.md"
fail() { echo "FAIL: $1" >&2; exit 1; }

[ -s "$verify" ] || fail "no tests/verify.sh"
[ -s "$readme" ] || fail "no README.md"

# `run "<label>" ./path/to/suite.sh [args]` names one suite per line. Leading
# whitespace is allowed so a suite inside a conditional block is still seen.
suites="$(sed -n 's/^[[:space:]]*run[[:space:]]\+"[^"]*"[[:space:]]*\.\/\([^[:space:]]*\).*/\1/p' "$verify")"
[ -n "$suites" ] || fail "tests/verify.sh declares no suites"
suite_count="$(printf '%s\n' "$suites" | grep -c . || true)"

# A suite line this reader cannot parse must fail rather than disappear. Count
# occurrences, not lines, so two runs on one line cannot hide.
declared="$(grep -o 'run "' "$verify" | grep -c . || true)"
[ "$declared" = "$suite_count" ] \
  || fail "tests/verify.sh declares $declared suites but $suite_count were parsed; keep each run on one line"

# Duplicates survive a membership check, so compare the unique count.
[ "$(printf '%s\n' "$suites" | sort -u | grep -c . || true)" = "$suite_count" ] \
  || fail "tests/verify.sh declares a suite twice"

# A suite row is a table cell that starts with a backticked test script path.
# Other tables in the README also start a row with a backticked name, so match
# the shape of a suite path rather than any first cell. The backtick is written
# as \x60 so the script holds no literal one, which shellcheck flags in quotes.
rows="$(sed -n 's/^| \x60\([^\x60]*tests\/[^\x60]*\.sh\)\x60 |.*/\1/p' "$readme")"
[ -n "$rows" ] || fail "README.md has no suite rows"
row_count="$(printf '%s\n' "$rows" | grep -c . || true)"
[ "$(printf '%s\n' "$rows" | sort -u | grep -c . || true)" = "$row_count" ] \
  || fail "README.md lists a suite twice"

while IFS= read -r path; do
  [ -n "$path" ] || continue
  grep -qxF "$path" <<<"$rows" \
    || fail "tests/verify.sh runs $path but README.md has no row for it"
done <<<"$suites"

while IFS= read -r path; do
  [ -n "$path" ] || continue
  grep -qxF "$path" <<<"$suites" \
    || fail "README.md lists $path but tests/verify.sh does not run it"
done <<<"$rows"

echo "the README suite table matches the gate"
