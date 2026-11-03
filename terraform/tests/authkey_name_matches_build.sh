#!/usr/bin/env bash
# terraform/tests/authkey_name_matches_build.sh
#
# The Tailscale auth key secret name is written in two places that never import
# each other: the Ignition build substitutes it from build.sh, and Terraform
# creates the secret it names. If the two drift, the join asks Key Vault for a
# secret nobody created and fails with a 404 that reads like a permissions bug.
#
# The compiled .ign is checked too, because Terraform ships it rather than the
# .bu source. Ignition stores file content as a data URI, base64-encoded when it
# is gzipped and percent-encoded when it is not, so the check decodes instead of
# grepping raw bytes, which would never match.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
fail() { echo "FAIL: $1" >&2; exit 1; }

build_sh="$root/os/butane/build.sh"
main_tf="$root/terraform/main.tf"
ign="$root/os/butane/ucore.ign"

[ -f "$build_sh" ] || fail "no such file: $build_sh"
[ -f "$main_tf" ] || fail "no such file: $main_tf"

built="$(grep -oE 'TS_AUTHKEY_SECRET:-[^}]+' "$build_sh" | head -1 | sed 's/^TS_AUTHKEY_SECRET:-//')"
[ -n "$built" ] || fail "build.sh no longer defaults TS_AUTHKEY_SECRET, so the name is unbound"

start="$(grep -n 'resource "azurerm_key_vault_secret" "tailscale_authkey"' "$main_tf" \
         | head -1 | cut -d: -f1 || true)"
[ -n "$start" ] || fail "no azurerm_key_vault_secret.tailscale_authkey resource"
block="$(tail -n "+$start" "$main_tf" | awk 'NR > 1 && /^}/{exit} {print}')"
created="$(printf '%s\n' "$block" | grep -oE 'name[[:space:]]*=[[:space:]]*"[^"]+"' \
           | head -1 | sed -E 's/.*"([^"]+)"$/\1/')"
[ -n "$created" ] || fail "the secret resource has no name attribute"

[ "$built" = "$created" ] \
  || fail "the join asks for '$built' but Terraform creates '$created'"

# Terraform ships ucore.ign, not ucore.bu. A fix applied only to the source
# leaves the deployed host broken while every source-level test still passes.
if [ -f "$ign" ]; then
  command -v python3 >/dev/null 2>&1 || fail "python3 is required to inspect the Ignition"
  python3 - "$ign" "$created" <<'PY' || exit 1
import base64
import gzip
import json
import sys
import urllib.parse

ign_path, expected = sys.argv[1], sys.argv[2]
with open(ign_path) as handle:
    config = json.load(handle)


def decode(contents):
    """Decode an Ignition data URI to text."""
    source = contents.get("source") or ""
    if not source.startswith("data:"):
        return contents.get("inline") or ""
    header, _, payload = source.partition(",")
    if ";base64" in header:
        raw = base64.b64decode(payload)
        if contents.get("compression") == "gzip":
            raw = gzip.decompress(raw)
        return raw.decode()
    return urllib.parse.unquote(payload)


found = []
for entry in (config.get("storage") or {}).get("files") or []:
    path = entry.get("path") or ""
    if path.endswith(".env"):
        found.append((path, decode(entry.get("contents") or {})))

if not found:
    print("FAIL: the compiled Ignition carries no env file at all", file=sys.stderr)
    sys.exit(1)

needle = f"TS_AUTHKEY_SECRET={expected}"
for path, text in found:
    if needle in text:
        print(f"compiled Ignition {path} names the secret Terraform creates")
        sys.exit(0)

names = ", ".join(path for path, _ in found)
print(
    f"FAIL: ucore.ign ({names}) does not name the secret Terraform creates "
    f"({expected}); regenerate it with os/butane/build.sh",
    file=sys.stderr,
)
sys.exit(1)
PY
fi

echo "the auth key secret name matches across build, Terraform, and the compiled Ignition"
