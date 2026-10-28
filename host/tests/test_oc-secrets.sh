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

# The effective password: the last assignment of the key, with one surrounding pair
# of quotes removed. Those are the two rules that decide the value for the line the
# writer emits. This is not a full EnvironmentFile parser: systemd also handles
# backslash escapes, CRLF, and whitespace around the key, and none of those can occur
# in the single printf line oc-secrets writes.
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

# T4: the path is supplied by the boot path, and its absence fails closed and says so.
#
# One check, not three. Earlier rounds enumerated assignment shapes and each round
# left one outside the union: a `:=` default, a re-exec through `env`, a `printf -v`
# into an indirection. All of them share one observable property, and it does not
# depend on how the shape is spelled: a writer that refuses when `OUT_FILE` is absent
# cannot be using a path of its own, because refusing is the alternative to inventing
# one.
#
# So the check is behavioural. Any default, append, or assignment makes the writer
# *proceed* instead of refusing, which is what fails here. The message is part of the
# assertion too: a run that dies for an unrelated reason must not read as a refusal.
#
# The environment is stripped to what a unit gets. A writer that shells out to a tool
# installed only on the interactive PATH passes with the caller's environment and
# fails under systemd, which is the failure this closes.
refusal="$(env -i PATH="$tmp/bin:/usr/bin:/bin" HOME="$tmp" TMPDIR="$tmp" \
  VAULT_NAME=v "$here/../bin/oc-secrets" 2>&1)" && \
  fail "T4 the writer succeeded with OUT_FILE absent, so it invents a path the boot path never defined"
case "$refusal" in
  *"OUT_FILE is required"*) ;;
  *) fail "T4 the writer failed with OUT_FILE absent for some other reason, which is not a refusal: $refusal" ;;
esac

# The check above proves the writer has no fallback. It cannot prove the writer *uses*
# the path it is handed: a script that declares the variable and then writes a fixed
# path beside it refuses nothing. So the bytes are read back from where it was told
# to write, which is the property no configuration comparison can show.
target="$tmp/supplied/env"
mkdir -p "$tmp/supplied"
PATH="$tmp/bin:$PATH" VAULT_NAME=v OUT_FILE="$target" \
  "$here/../bin/oc-secrets" >/dev/null \
  || fail "T4 the writer failed with OUT_FILE set"
[ "$(effective_env_value "$target" OPENCODE_PASSWORD)" = "s3cret" ] \
  || fail "T4 the writer did not write the OUT_FILE it was given"
[ "$(stat -c '%a' "$target")" = "600" ] || fail "T4 wrong mode on the supplied path"

echo "all secret tests passed"
