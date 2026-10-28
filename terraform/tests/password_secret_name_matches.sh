#!/usr/bin/env bash
# terraform/tests/password_secret_name_matches.sh
#
# The OpenCode password secret name is written in two places that never import
# each other: host/bin/oc-secrets defaults SECRET_NAME, and Terraform creates the
# secret it names. Drift produces a Key Vault 404 at boot that reads like a
# permissions bug, which is the same failure the tailscale authkey guard covers.
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

# The default the host uses when the unit sets nothing. bash evaluates the right-hand
# side with SECRET_NAME unset, which is the boot condition, so quoting and a `:-`
# fallback resolve as they do at runtime instead of being pattern-matched by hand.
assign_re='^[[:space:]]*(export[[:space:]]+|readonly[[:space:]]+|declare([[:space:]]+-[A-Za-z]+)*[[:space:]]+|local([[:space:]]+-[A-Za-z]+)*[[:space:]]+)?SECRET_NAME='
decl_lines="$(grep -E "$assign_re" "$writer" || true)"
[ -n "$decl_lines" ] || fail "oc-secrets no longer assigns SECRET_NAME, so the name is unbound"
last_decl="$(printf '%s\n' "$decl_lines" | tail -1)"
rhs="${last_decl#*SECRET_NAME=}"
rhs="${rhs%%[[:space:]]#*}"
# shellcheck disable=SC2016
declared="$(env -u SECRET_NAME DECL_RHS="$rhs" bash -c '
  set -u
  eval "SECRET_NAME=$DECL_RHS"
  printf %s "$SECRET_NAME"
' 2>/dev/null || true)"
[ -n "$declared" ] \
  || fail "oc-secrets declares a SECRET_NAME that does not evaluate: $rhs"

start="$(grep -n 'resource "azurerm_key_vault_secret" "opencode_password"' "$main_tf" \
         | head -1 | cut -d: -f1 || true)"
[ -n "$start" ] || fail "no azurerm_key_vault_secret.opencode_password resource"
block="$(tail -n "+$start" "$main_tf" | awk 'NR > 1 && /^}/{exit} {print}')"
created="$(printf '%s\n' "$block" | grep -oE 'name[[:space:]]*=[[:space:]]*"[^"]+"' \
           | head -1 | sed -E 's/.*"([^"]+)"$/\1/')"
[ -n "$created" ] || fail "the secret resource has no name attribute"

[ "$declared" = "$created" ] \
  || fail "the host asks for '$declared' but Terraform creates '$created'"

# A unit env file that sets SECRET_NAME would make the default irrelevant, so any
# value it sets has to match too.
defs="$(python3 "$root/host/tests/env_file_paths.py" --values "$butane" SECRET_NAME)"
while IFS=$'\t' read -r env_path value; do
  [ -n "${value:-}" ] || continue
  [ "$value" = "$created" ] \
    || fail "$env_path sets SECRET_NAME=$value but Terraform creates '$created'"
done <<< "$defs"

echo "password secret name matches between the host and Terraform"
