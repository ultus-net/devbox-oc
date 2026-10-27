#!/usr/bin/env bash
# host/tests/test_oc-secrets.sh
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
fail() { echo "FAIL: $1" >&2; exit 1; }
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"

cat > "$tmp/bin/curl" <<'EOF'
#!/usr/bin/env bash
url=""
for a in "$@"; do
  case "$a" in http://*|https://*) url="$a" ;; esac
done
if [[ "$url" == *"169.254.169.254"* ]]; then printf '%s' '{"access_token":"tok"}'; exit 0; fi
if [[ "$url" == *"vault.azure.net/secrets/opencode-password"* ]]; then
  printf '%s' "${SECRET_RESP:-{\"value\":\"s3cret\"}}"; exit 0
fi
if [[ "$url" == *"/oauth2/exchange"* ]]; then printf '%s' '{"refresh_token":"r3fresh"}'; exit 0; fi
exit 0
EOF
chmod +x "$tmp/bin/curl"

# T1: writes the documented variable with tight permissions.
PATH="$tmp/bin:$PATH" VAULT_NAME=v OUT_FILE="$tmp/env" "$here/../bin/oc-secrets"
grep -qx 'OPENCODE_PASSWORD=s3cret' "$tmp/env" || fail "T1 wrong content"
[ "$(stat -c '%a' "$tmp/env")" = "600" ] || fail "T1 wrong mode"

# T2: an empty secret must not overwrite a good file.
printf 'OPENCODE_PASSWORD=old\n' > "$tmp/env"; chmod 600 "$tmp/env"
if SECRET_RESP='{"value":""}' PATH="$tmp/bin:$PATH" VAULT_NAME=v \
     OUT_FILE="$tmp/env" "$here/../bin/oc-secrets" 2>/dev/null; then
  fail "T2 should have refused an empty secret"
fi
grep -qx 'OPENCODE_PASSWORD=old' "$tmp/env" || fail "T2 clobbered the good file"

# T3: ACR login writes an auths entry for the registry hostname.
PATH="$tmp/bin:$PATH" ACR_NAME=myreg OUT="$tmp/auth.json" "$here/../bin/oc-acr-login"
jq -e '.auths["myreg.azurecr.io"].auth' "$tmp/auth.json" >/dev/null || fail "T3 no auths entry"
[ "$(stat -c '%a' "$tmp/auth.json")" = "600" ] || fail "T3 wrong mode"

echo "all secret tests passed"
