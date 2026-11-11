#!/usr/bin/env bash
# vm/report-verdict.sh
#
# Decide whether a guest report is a pass. A pass needs no FAIL line and the
# summary line the guest writes last. A truncated, empty or foreign post has
# neither, and used to read as a clean run. A default run also expects the
# rollback rehearsal, so --rollback fails a report that never ran it.
set -euo pipefail
report="${1:?usage: report-verdict.sh REPORT [--rollback]}"
require_rollback=0
if [ "${2:-}" = "--rollback" ]; then
  require_rollback=1
elif [ -n "${2:-}" ]; then
  echo "unknown argument: $2" >&2
  exit 2
fi

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
if [ "$require_rollback" = 1 ]; then
  missing=""
  for name in restart-stable pull-older repoint pull-newer digest changed timer-restored; do
    grep -q "^PASS rollback-$name:" "$report" || missing="$missing rollback-$name"
  done
  if [ -n "$missing" ]; then
    echo "the rollback rehearsal did not report:$missing" >&2
    exit 1
  fi
fi
