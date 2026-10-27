#!/usr/bin/env bash
# Assert the project never reintroduces a scheduled hard stop.
#
# The box starts on a schedule and stops only when idle, because a fixed cutoff
# would kill an active agent turn. That is an anti-goal (design doc, decision 6).
#
# Usage: no_scheduled_stop.sh [dir]
#
# Two checks that must both hold:
#   1. no shutdown-schedule machinery exists anywhere under terraform/
#   2. the scheduled start still exists
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
dir="${1:-$(cd "$here/.." && pwd)}"
fail() { echo "FAIL: $1" >&2; exit 1; }

[ -d "$dir" ] || fail "no such directory: $dir"

# Scan Terraform sources only. Excluding this file matters: its own pattern
# text would otherwise match itself and the check could never pass.
hits="$(
  find "$dir" -maxdepth 1 -name '*.tf' -type f -print0 \
    | xargs -0 grep -lE 'dev_test_global_vm_shutdown_schedule|daily_recurrence_time' 2>/dev/null || true
)"
[ -z "$hits" ] || fail "a scheduled shutdown exists; the idle gate owns shutdown: $hits"

grep -q 'azurerm_logic_app_workflow' "$dir/schedule.tf" 2>/dev/null \
  || fail "no scheduled start in $dir/schedule.tf"

echo "start is scheduled, stop is not"
