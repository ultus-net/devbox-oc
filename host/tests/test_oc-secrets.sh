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

# T4: the path comes from the environment, and its absence fails closed.
#
# The writer no longer has a default: /etc/devbox/oc-secrets.env defines OUT_FILE,
# and the quadlet guard proves that definition reaches the service and matches the
# file the container loads. A second definition inside the script is exactly how the
# two drifted apart before, so there must not be one.
#
# Two properties are checked here. Without OUT_FILE the writer must fail rather than
# pick a path of its own, because a silent write to a file nobody reads looks like
# success. With it set, the bytes must land there and not somewhere hardcoded beside
# it, which no amount of configuration comparison can show.
if env -u OUT_FILE PATH="$tmp/bin:$PATH" VAULT_NAME=v \
     "$here/../bin/oc-secrets" >/dev/null 2>&1; then
  fail "T4 the writer succeeded with OUT_FILE unset, so it invents a path the boot path never defined"
fi

# A writer that honours OUT_FILE for its directory but writes a fixed name inside it
# would pass a directory-only comparison, so compare the whole path.
hardcoded="$tmp/hardcoded"
if PATH="$tmp/bin:$PATH" VAULT_NAME=v OUT_FILE="$hardcoded" \
     "$here/../bin/oc-secrets" >/dev/null 2>&1; then
  [ "$(effective_env_value "$hardcoded" OPENCODE_PASSWORD)" = "s3cret" ] \
    || fail "T4 the writer did not write the OUT_FILE it was given"
else
  fail "T4 the writer failed with OUT_FILE set"
fi

# The script must not set OUT_FILE at all. A fallback would make the boot path's
# definition optional, which is the drift this design removes.
#
# Two mechanisms, because each covers what the other cannot. Running it readonly
# catches every assignment that actually executes, whatever its shape and wherever it
# sits. It cannot catch one behind a condition that is false on the machine running the
# test, so a text rule covers that case: the script must not contain an OUT_FILE
# assignment at all. Neither is sufficient alone.
#
# `BASH_SOURCE` is passed explicitly because a sourced script sees the caller's $0.
#
# The environment is stripped to what a unit gets: PATH is the stub plus the system
# directories, not the caller's PATH. A writer that shells out to something installed
# only on the interactive PATH passes with the caller's environment and fails under
# systemd, which is the failure this closes.
# The child expands $SELF and $OUT_FILE, so the single-quoted body is deliberate.
# shellcheck disable=SC2016
readonly_out="$(env -i PATH="$tmp/bin:/usr/bin:/bin" HOME="$tmp" TMPDIR="$tmp" \
  VAULT_NAME=v OUT_FILE="$tmp/readonly-env" SELF="$here/../bin/oc-secrets" \
  bash -c 'readonly OUT_FILE; cd "$(dirname "$SELF")" && . "./$(basename "$SELF")"' \
  2>&1 || true)"
case "$readonly_out" in
  *"readonly variable"*)
    fail "T4 the writer assigns OUT_FILE ($readonly_out), so the boot path's definition is not the only one" ;;
esac
grep -qx 'OPENCODE_PASSWORD=s3cret' "$tmp/readonly-env" 2>/dev/null \
  || fail "T4 the writer did not complete when OUT_FILE was readonly and set: $readonly_out"

# The static half. `: "${OUT_FILE:?...}"` is a check, not an assignment, so it does not
# match; `OUT_FILE=`, `export OUT_FILE=`, and `${OUT_FILE:-...}` all do.
if grep -nE '(^|[^A-Za-z0-9_])OUT_FILE=' "$here/../bin/oc-secrets" >/dev/null; then
  fail "T4 the writer contains an OUT_FILE= assignment, so the boot path's definition is not the only one:
$(grep -nE '(^|[^A-Za-z0-9_])OUT_FILE=' "$here/../bin/oc-secrets")"
fi
echo "all secret tests passed"
