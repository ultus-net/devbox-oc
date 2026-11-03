#!/usr/bin/env bash
# Assert the data disk cannot be removed by a stack teardown.
#
# The disk holds the session database and the operator's repos. It is the only
# thing on the box a rebuild must not lose, so `prevent_destroy` must sit inside
# the azurerm_managed_disk.data block specifically, not merely somewhere in the
# file.
#
# Usage: data_disk_protected.sh [path/to/main.tf]
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
main="${1:-$(cd "$here/.." && pwd)/main.tf}"
fail() { echo "FAIL: $1" >&2; exit 1; }

[ -f "$main" ] || fail "no such file: $main"

block="$(awk '/resource "azurerm_managed_disk" "data"/,/^}/' "$main")"
[ -n "$block" ] || fail "azurerm_managed_disk.data not found in $main"

printf '%s\n' "$block" | grep -q 'prevent_destroy[[:space:]]*=[[:space:]]*true' \
  || fail "data disk is not destroy-protected"

echo "data disk is destroy-protected"
