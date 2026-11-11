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

# A report that pulled the fixture image must carry the rollback checks. The
# fixture host is the harness registry, so its pull says the rehearsal was
# expected; a published-image report does not require it.
cat > "$tmp/rollback.txt" <<'EOF'
PASS image-pull: 10.0.2.2:5000/devbox@sha256:aaa
PASS rollback-restart-stable: 10.0.2.2:5000/devbox@sha256:aaa
PASS rollback-pull-older: 10.0.2.2:5000/devbox:older
PASS rollback-pin: 10.0.2.2:5000/devbox@sha256:bbb
PASS rollback-digest: sha256:bbb
PASS rollback-changed: 10.0.2.2:5000/devbox@sha256:bbb
PASS rollback-timer-restored: active
SUMMARY failures=0
EOF
cat > "$tmp/fixture-no-rollback.txt" <<'EOF'
PASS image-pull: 10.0.2.2:5000/devbox@sha256:aaa
SUMMARY failures=0
EOF
cat > "$tmp/published.txt" <<'EOF'
PASS image-pull: ghcr.io/ultus-net/devbox:prod
SUMMARY failures=0
EOF
"$verdict" "$tmp/rollback.txt" || fail "a full fixture report was rejected"
"$verdict" "$tmp/published.txt" || fail "a published-image report without rollback lines was rejected"
if "$verdict" "$tmp/fixture-no-rollback.txt" 2>/dev/null; then
  fail "a fixture report with no rollback lines was accepted"
fi
grep -v '^PASS rollback-timer-restored:' "$tmp/rollback.txt" > "$tmp/rollback-missing.txt"
if "$verdict" "$tmp/rollback-missing.txt" 2>/dev/null; then
  fail "a fixture report missing one rollback line was accepted"
fi

# Every required line is load-bearing, so prove it for the pin step too rather
# than for the last name in the loop alone.
grep -v '^PASS rollback-pin:' "$tmp/rollback.txt" > "$tmp/rollback-no-pin.txt"
if "$verdict" "$tmp/rollback-no-pin.txt" 2>/dev/null; then
  fail "a fixture report with no rollback-pin line was accepted"
fi

# Teeth: skip the fixture requirement and the rollback-less fixture report must
# pass, so the assertion above cannot be satisfied by an unrelated check.
mutated="$tmp/verdict-norollback.sh"
sed 's|image-pull: 10|image-pull: 99|' "$verdict" > "$mutated"
cmp -s "$verdict" "$mutated" && fail "rollback mutation did not land"
if ! bash "$mutated" "$tmp/fixture-no-rollback.txt" 2>/dev/null; then
  fail "mutation survived: the rollback requirement was not enforced"
fi

echo "report verdict requires a clean summary"
