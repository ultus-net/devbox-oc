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

# The value systemd would use: the last assignment of the key, with the quotes it
# strips removed. A repeated key is last-wins, so a later line overrides an earlier
# one and a first-line-only match would accept the wrong password.
effective_env_value() {
  local file="$1" key="$2" line value
  line="$(grep -E "^${key}=" "$file" | tail -1)"
  [ -n "$line" ] || return 1
  value="${line#*=}"
  value="${value%\"}"; value="${value#\"}"
  value="${value%\'}"; value="${value#\'}"
  printf '%s' "$value"
}

# T1: writes the documented variable with tight permissions.
#
# The effective value is compared, not just a matching line. systemd takes the last
# value for a repeated key, so `OPENCODE_PASSWORD=s3cret` followed by a later
# `OPENCODE_PASSWORD=legacy` would authenticate with `legacy` while a `grep -x` for
# the first line still passes. Quotes around a value are valid EnvironmentFile syntax
# and systemd strips them, so the comparison normalises them rather than rejecting a
# legitimate writer.
PATH="$tmp/bin:$PATH" VAULT_NAME=v OUT_FILE="$tmp/env" "$here/../bin/oc-secrets"
[ "$(effective_env_value "$tmp/env" OPENCODE_PASSWORD)" = "s3cret" ] \
  || fail "T1 the effective OPENCODE_PASSWORD is wrong: $(cat "$tmp/env")"
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

# T4: the write goes to $OUT_FILE, not to a path hardcoded beside it.
#
# The quadlet guard proves the declaration evaluates to the file the container loads.
# It cannot prove the writer *uses* that variable: a writer that declares
# `/etc/opencode/env` and then writes a hardcoded `/etc/opencode/other` passes that
# comparison while the container reads a file nothing writes. Only running the writer
# answers that.
#
# The declaration line is replaced wholesale rather than pattern-matching the shipped
# default, so a legitimate change to its shape does not break this test. Only that one
# line changes; the write, trap, mode and quoting logic stay the shipped ones.
sandbox_writer="$tmp/oc-secrets"
sed -E "s#^[[:space:]]*(export[[:space:]]+|readonly[[:space:]]+)?OUT_FILE=.*\$#OUT_FILE=$tmp/default-env#" \
  "$here/../bin/oc-secrets" > "$sandbox_writer"
grep -qx "OUT_FILE=$tmp/default-env" "$sandbox_writer" \
  || fail "T4 could not rewrite the OUT_FILE declaration, so the boot path is untested"
chmod +x "$sandbox_writer"
cp "$here/../bin/lib-imds.sh" "$tmp/lib-imds.sh"
if ! env -u OUT_FILE PATH="$tmp/bin:$PATH" VAULT_NAME=v bash "$sandbox_writer"; then
  fail "T4 the writer does not run with OUT_FILE unset, so it writes nothing at boot"
fi
[ "$(effective_env_value "$tmp/default-env" OPENCODE_PASSWORD)" = "s3cret" ] \
  || fail "T4 the writer did not write the path it declares when OUT_FILE was unset"
[ "$(stat -c '%a' "$tmp/default-env")" = "600" ] || fail "T4 wrong mode on the default path"
echo "all secret tests passed"
