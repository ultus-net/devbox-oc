#!/usr/bin/env bash
# terraform/tests/authkey_is_stored.sh
#
# A required, documented variable that no resource consumes is a silent drop: the
# operator supplies a key, Terraform accepts it, and the host asks Key Vault for a
# secret that was never written. The tailnet join then fails on every boot.
#
# Usage: authkey_is_stored.sh [path/to/main.tf]
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
main="${1:-$(cd "$here/.." && pwd)/main.tf}"
fail() { echo "FAIL: $1" >&2; exit 1; }

[ -f "$main" ] || fail "no such file: $main"

# The variable must exist at all.
grep -qE '^variable "tailscale_authkey"' "$main" \
  || grep -qE '^variable "tailscale_authkey"' "$(dirname "$main")/variables.tf" \
  || fail "tailscale_authkey is no longer an input"

# It must be consumed, not merely declared.
grep -q 'var\.tailscale_authkey' "$main" \
  || fail "var.tailscale_authkey is declared but no resource consumes it"

# The secret name is a contract with host/bin/oc-tailnet-up, which defaults to
# TS_AUTHKEY_SECRET=tailscale-authkey. Renaming one side silently breaks the join.
start="$(grep -n 'resource "azurerm_key_vault_secret" "tailscale_authkey"' "$main" | head -1 | cut -d: -f1 || true)"
[ -n "$start" ] || fail "no azurerm_key_vault_secret.tailscale_authkey resource"
block="$(tail -n "+$start" "$main" | awk 'NR > 1 && /^}/{exit} {print}')"
printf '%s\n' "$block" | grep -Eq 'name[[:space:]]*=[[:space:]]*"tailscale-authkey"' \
  || fail "secret name is not the one oc-tailnet-up reads"
printf '%s\n' "$block" | grep -q 'var\.tailscale_authkey' \
  || fail "the secret does not carry the variable's value"

# The role assignment must exist before the secret, or the apply races and fails
# with an authorization error that reads like a permissions problem.
printf '%s\n' "$block" | grep -q 'deployer_kv_admin' \
  || fail "secret does not depend on the deployer's Key Vault role assignment"

echo "the tailscale auth key is stored where the host reads it"
