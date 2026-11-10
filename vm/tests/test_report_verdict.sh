#!/usr/bin/env bash
# vm/tests/test_report_verdict.sh
#
# A guest report is the only evidence a run has. A truncated post, an empty file
# or a report that lost its summary must not read as a pass, so the host's
# verdict is its own script and its own test.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
verdict="$here/../report-verdict.sh"
fail() { echo "FAIL: $1" >&2; exit 1; }

[ -f "$verdict" ] || fail "no report verdict at $verdict"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

printf 'PASS booted-image: ucore-minimal\nSKIP cockpit-loopback: absent\nSUMMARY failures=0\n' \
  > "$tmp/pass.txt"
printf 'PASS booted-image: ucore-minimal\nFAIL srv-mounted: inactive\nSUMMARY failures=1\n' \
  > "$tmp/fail.txt"
printf 'PASS booted-image: ucore-minimal\nFAIL srv-mounted: inactive\n' \
  > "$tmp/no-summary.txt"
printf 'PASS booted-image: ucore-minimal\n' > "$tmp/partial.txt"
: > "$tmp/empty.txt"

"$verdict" "$tmp/pass.txt" || fail "a clean report was not accepted"
if "$verdict" "$tmp/fail.txt" 2>/dev/null; then
  fail "a report with a FAIL line was accepted"
fi
if "$verdict" "$tmp/no-summary.txt" 2>/dev/null; then
  fail "a truncated report without the summary line was accepted"
fi
if "$verdict" "$tmp/empty.txt" 2>/dev/null; then
  fail "an empty report was accepted"
fi
if "$verdict" "$tmp/partial.txt" 2>/dev/null; then
  fail "a partial report with no FAIL and no summary was accepted"
fi

# Teeth: remove the summary requirement and the partial report must pass. That is
# the false pass this script exists to prevent, so the mutation has to change the
# answer before the assertion above is trusted.
mutated="$tmp/verdict-nosummary.sh"
# shellcheck disable=SC2016  # sed pattern, not a shell expansion.
sed "s|grep -qx 'SUMMARY failures=0'|true|" "$verdict" > "$mutated"
cmp -s "$verdict" "$mutated" && fail "mutation did not land"
if ! bash "$mutated" "$tmp/partial.txt" 2>/dev/null; then
  fail "mutation survived: the partial report was still rejected without the summary check"
fi

echo "report verdict requires a clean summary"
