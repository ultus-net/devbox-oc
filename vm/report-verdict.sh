#!/usr/bin/env bash
# vm/report-verdict.sh
#
# Decide whether a guest report is a pass. A pass needs no FAIL line and the
# summary line the guest writes last. A truncated, empty or foreign post has
# neither, and used to read as a clean run. A report that pulled the fixture
# image also has to carry the rollback checks, so a rehearsal that was skipped
# cannot read as green.
set -euo pipefail
report="${1:?usage: report-verdict.sh REPORT}"

if [ ! -s "$report" ]; then
  echo "empty report: $report" >&2
  exit 1
fi
if grep -q '^FAIL ' "$report"; then
  exit 1
fi
if ! grep -qx 'SUMMARY failures=0' "$report"; then
  echo "report has no 'SUMMARY failures=0' line: $report" >&2
  exit 1
fi
# The fixture image is only pulled by the harness registry, so its presence says
# the rollback steps were expected. Decide from the report, not from a flag the
# caller could forget.
if grep -q '^PASS image-pull: 10\.0\.2\.2:' "$report"; then
  missing=""
  for name in restart-stable pull-older pin digest changed timer-restored; do
    grep -q "^PASS rollback-$name:" "$report" || missing="$missing rollback-$name"
  done
  if [ -n "$missing" ]; then
    echo "the fixture ran but the rollback rehearsal did not report:$missing" >&2
    exit 1
  fi
fi
