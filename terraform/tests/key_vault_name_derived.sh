#!/usr/bin/env bash
# Assert the Key Vault name is derivable from tfvars alone.
#
# Ignition must exist before the apply that creates the resources it refers to.
# Ignition needs the vault name. So the vault name cannot come from state, which
# rules out `random_string`: on a fresh checkout there is no state to read, and
# `terraform output` fails. A random suffix makes the first deploy circular.
#
# This test catches a revert to `random_string`, and a hash taken over a managed
# resource instead of an input. That second form would compile, validate, and read
# plausibly, while reintroducing the exact cycle this guards against.
#
# Usage: key_vault_name_derived.sh [path/to/main.tf]
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
main="${1:-$(cd "$here/.." && pwd)/main.tf}"
fail() { echo "FAIL: $1" >&2; exit 1; }

[ -f "$main" ] || fail "no such file: $main"

block="$(awk '/resource "azurerm_key_vault" "this"/,/^}/' "$main")"
[ -n "$block" ] || fail "azurerm_key_vault.this not found in $main"

printf '%s\n' "$block" | grep -qE '^[[:space:]]*name[[:space:]]*=[[:space:]]*local\.key_vault_name[[:space:]]*$' \
  || fail "key vault name is not derived from local.key_vault_name"

! grep -q 'random_string' "$main" \
  || fail "main.tf still uses random_string; the vault name must not depend on state"

# The suffix must hash an input variable. A hash over a managed resource (for
# example azurerm_key_vault.this.id) is still a hash, still deterministic, and
# still circular, so the argument is what has to be checked.
grep -qE 'subscription_suffix[[:space:]]*=[[:space:]]*substr\(' "$main" \
  || fail "subscription_suffix is not derived with substr()"

grep -qE 'subscription_suffix[[:space:]]*=[^=]*sha256\(var\.subscription_id\)' "$main" \
  || fail "subscription_suffix does not hash var.subscription_id, so it may depend on state"

# Nothing in the suffix expression may reference a resource or a data source, or
# the name cannot be computed before the apply.
suffix_line="$(grep -E 'subscription_suffix[[:space:]]*=' "$main")"
case "$suffix_line" in
  *azurerm_*|*data\.*|*module\.*)
    fail "subscription_suffix references managed state: ${suffix_line}" ;;
esac

# Azure caps a vault name at 24 characters. The suffix must be sized so the whole
# name fits, rather than truncating the assembled name and silently losing hex
# characters that the uniqueness depends on.
grep -qE 'substr\(sha256\(var\.subscription_id\),[[:space:]]*0,[[:space:]]*min\([0-9]+,[[:space:]]*20 - length\(var\.name_prefix\)\)\)' "$main" \
  || fail "suffix length is not bounded so the name stays within 24 characters"

grep -qE 'key_vault_name[[:space:]]*=[[:space:]]*"kv-\$\{var\.name_prefix\}-\$\{local\.subscription_suffix\}"[[:space:]]*$' "$main" \
  || fail "key vault name is not built from the prefix and the derived suffix, or is truncated"

echo "key vault name is derivable without state"
