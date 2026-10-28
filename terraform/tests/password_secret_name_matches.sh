#!/usr/bin/env bash
# terraform/tests/password_secret_name_matches.sh
#
# The OpenCode password secret name is written in two places that never import
# each other: host/bin/oc-secrets defaults SECRET_NAME, and Terraform creates the
# secret it names. Drift produces a Key Vault 404 at boot that reads like a
# permissions bug, which is the same failure the tailscale authkey guard covers.
#
# Nothing here executes or evaluates a shipped script. A guard that evals text from
# the file it audits runs that file's code, which is how the previous version of this
# test could be made to touch a file just by editing a variable's default.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
fail() { echo "FAIL: $1" >&2; exit 1; }

writer="$root/host/bin/oc-secrets"
main_tf="$root/terraform/main.tf"
butane="$root/os/butane/ucore.bu"

[ -f "$writer" ] || fail "no such file: $writer"
[ -f "$main_tf" ] || fail "no such file: $main_tf"

# The Butane source is parsed rather than grepped, so a comment mentioning the name is
# not a definition. Missing python3 must fail, not silently skip the override check.
command -v python3 >/dev/null 2>&1 || fail "python3 is required and absent"
python3 -c 'import yaml' >/dev/null 2>&1 || fail "python3 has no PyYAML module"

# The default the host uses when nothing overrides it. Only the `${NAME:-default}`
# form is read, which is the one this script ships; anything else is a shape this
# test does not model, so it fails rather than guessing.
default_line="$(grep -E '^[[:space:]]*SECRET_NAME="\$\{SECRET_NAME:-[^}]+\}"' "$writer" || true)"
[ -n "$default_line" ] \
  || fail "oc-secrets no longer defaults SECRET_NAME as \${SECRET_NAME:-...}, so this test cannot read it"
declared="${default_line#*SECRET_NAME:-}"
declared="${declared%%\}*}"

# The created name, from the resource's own block. A `name` inside a nested block is
# not the resource's name, and an attribute that is not a string literal is a case
# this test does not model, so both must fail loudly instead of reading as a match.
start="$(grep -n 'resource "azurerm_key_vault_secret" "opencode_password"' "$main_tf" \
         | head -1 | cut -d: -f1 || true)"
[ -n "$start" ] || fail "no azurerm_key_vault_secret.opencode_password resource"

block="$(awk -v start="$start" 'NR > start { if ($0 ~ /^}/) exit; print }' "$main_tf")"
names="$(printf '%s\n' "$block" \
  | awk '/^[[:space:]]*name[[:space:]]*=/ { print }')"
[ -n "$names" ] || fail "the secret resource has no name attribute"
count="$(printf '%s\n' "$names" | wc -l)"
[ "$count" -eq 1 ] || fail "the secret resource sets name $count times: $names"
case "$names" in
  *'"'*) ;;
  *) fail "the secret resource name is not a string literal: $names" ;;
esac
created="$(printf '%s\n' "$names" | sed -E 's/^[^"]*"([^"]+)".*$/\1/')"

[ "$declared" = "$created" ] \
  || fail "the host asks for '$declared' but Terraform creates '$created'"

# A shipped env file that sets SECRET_NAME would make the default irrelevant, so any
# value it sets has to match too. systemd's last-wins rule applies, which boot_env.py
# implements; every definition is checked, so an earlier stray value cannot hide.
defs="$(python3 "$root/host/tests/boot_env.py" "$butane" SECRET_NAME \
  | awk -F'\t' '$1 == "envfile" || $1 == "environment" { print $2 "\t" $3 }')"
while IFS=$'\t' read -r env_owner value; do
  [ -n "${value:-}" ] || continue
  [ "$value" = "$created" ] \
    || fail "$env_owner sets SECRET_NAME=$value but Terraform creates '$created'"
done <<< "$defs"

echo "password secret name matches between the host and Terraform"
