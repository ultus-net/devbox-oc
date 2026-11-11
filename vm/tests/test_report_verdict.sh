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

# A default run must not pass without the rollback rehearsal. A report that lost
# the rollback lines is a silent regression, which is what #34 exists to stop.
cat > "$tmp/rollback.txt" <<'EOF'
PASS booted-image: ucore-minimal
PASS rollback-restart-stable: 10.0.2.2:5000/devbox@sha256:aaa
PASS rollback-pull-older: 10.0.2.2:5000/devbox:older
PASS rollback-repoint: 10.0.2.2:5000/devbox:newer
PASS rollback-pull-newer: 10.0.2.2:5000/devbox:newer
PASS rollback-digest: sha256:aaa
PASS rollback-changed: 10.0.2.2:5000/devbox@sha256:bbb
PASS rollback-timer-restored: active
SUMMARY failures=0
EOF
"$verdict" "$tmp/pass.txt" || fail "a clean report without --rollback was rejected"
"$verdict" "$tmp/rollback.txt" --rollback || fail "a full rollback report was rejected"
if "$verdict" "$tmp/pass.txt" --rollback 2>/dev/null; then
  fail "a report with no rollback lines passed a --rollback verdict"
fi

# Teeth: skip the rollback requirement and the rollback-less report must pass.
mutated="$tmp/verdict-norollback.sh"
sed 's|require_rollback" = 1|require_rollback" = 2|' "$verdict" > "$mutated"
cmp -s "$verdict" "$mutated" && fail "rollback mutation did not land"
if ! bash "$mutated" "$tmp/pass.txt" --rollback 2>/dev/null; then
  fail "mutation survived: the rollback requirement was not enforced"
fi

echo "report verdict requires a clean summary"
