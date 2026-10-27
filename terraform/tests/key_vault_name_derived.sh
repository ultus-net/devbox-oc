#!/usr/bin/env bash
# Assert the Key Vault name is derivable from tfvars alone.
#
# Ignition must exist before the apply that creates the resources it refers to.
# Ignition needs the vault name. So the vault name cannot come from state, which
# rules out `random_string`: on a fresh checkout there is no state to read, and
# `terraform output` fails. A random suffix makes the first deploy circular.
#
# This test catches a revert to `random_string`, which would otherwise only be
# discovered by a first deploy failing after the OS image was already published.
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

# The name must be stable across applies, so the suffix derives from an input.
grep -qE 'subscription_suffix[[:space:]]*=[[:space:]]*substr\(sha256\(' "$main" \
  || fail "subscription_suffix is not a deterministic hash of the subscription id"

# Azure requires a globally unique vault name of 3 to 24 characters.
grep -qE 'substr\("kv-\$\{var\.name_prefix\}-\$\{local\.subscription_suffix\}",[[:space:]]*0,[[:space:]]*24\)' "$main" \
  || fail "vault name is not truncated to 24 characters"

echo "key vault name is derivable without state"
