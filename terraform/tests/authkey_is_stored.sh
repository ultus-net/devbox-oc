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
# It must be consumed as a value, not merely mentioned. A comment that names the
# variable, plus a hardcoded literal, would satisfy an unanchored grep while the
# secret holds a string the operator never supplied.
tffiles=("$main")
if [ -d "$(dirname "$main")" ]; then
  while IFS= read -r f; do
    [ "$f" = "$main" ] || tffiles+=("$f")
  done < <(find "$(dirname "$main")" -maxdepth 1 -name '*.tf' -print)
fi
grep -hE '^[[:space:]]*value[[:space:]]*=[[:space:]]*var\.tailscale_authkey[[:space:]]*$' \
  "${tffiles[@]}" >/dev/null \
  || fail "var.tailscale_authkey is declared but no secret carries it as a value"

# The secret name is a contract with host/bin/oc-tailnet-up, which defaults to
# TS_AUTHKEY_SECRET=tailscale-authkey. Renaming one side silently breaks the join.
start="$(grep -n 'resource "azurerm_key_vault_secret" "tailscale_authkey"' "$main" | head -1 | cut -d: -f1 || true)"
[ -n "$start" ] || fail "no azurerm_key_vault_secret.tailscale_authkey resource"
block="$(tail -n "+$start" "$main" | awk 'NR > 1 && /^}/{exit} {print}')"
printf '%s\n' "$block" | grep -Eq 'name[[:space:]]*=[[:space:]]*"tailscale-authkey"' \
  || fail "secret name is not the one oc-tailnet-up reads"
printf '%s\n' "$block" | grep -Eq '^[[:space:]]*value[[:space:]]*=[[:space:]]*var\.tailscale_authkey[[:space:]]*$' \
  || fail "the secret does not carry the variable's value"

# The role assignment must exist before the secret, or the apply races and fails
# with an authorization error that reads like a permissions problem. Match the
# depends_on list itself at line start: a commented-out list satisfies a looser
# pattern while ordering nothing.
#
# Terraform allows the list to span lines, and `terraform fmt` does not collapse
# it, so a single-line pattern rejects valid configuration. Take the list from
# `depends_on = [` up to its closing bracket, comments excluded.
depends_block="$(printf '%s\n' "$block" \
  | awk '/^[[:space:]]*depends_on[[:space:]]*=/{on=1} on{print} on && /\]/{exit}' \
  | grep -v '^[[:space:]]*#')"
[ -n "$depends_block" ] \
  || fail "secret does not depend on the deployer's Key Vault role assignment"
printf '%s\n' "$depends_block" | grep -q 'azurerm_role_assignment\.deployer_kv_admin' \
  || fail "secret does not depend on the deployer's Key Vault role assignment"

echo "the tailscale auth key is stored where the host reads it"
