#!/usr/bin/env bash
# vm/report-verdict.sh
#
# Decide whether a guest report is a pass. A pass needs no FAIL line and the
# summary line the guest writes last. A truncated, empty or foreign post has
# neither, and used to read as a clean run.
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
