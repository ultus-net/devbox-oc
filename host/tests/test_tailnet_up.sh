#!/usr/bin/env bash
# host/tests/test_tailnet_up.sh
# The tailnet is the only data path to the box, so the join must happen once on
# first boot and never again once state exists. A fake tailscale records the
# joins; a fake curl serves IMDS and Key Vault so no network is needed.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
script="$here/../bin/oc-tailnet-up"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }

setup() {
  rm -rf "${tmp:?}/bin" "${tmp:?}/devbox" "${tmp:?}/state"
  mkdir -p "$tmp/bin" "$tmp/devbox" "$tmp/state"
  : > "$tmp/up-calls"
  : > "$tmp/kv-calls"
  cat > "$tmp/bin/tailscale" <<'EOF'
#!/usr/bin/env bash
[[ "${1:-}" == "up" ]] && { echo "$*" >> "$UP_CALLS"; exit 0; }
exit 0
EOF
  cat > "$tmp/bin/curl" <<'EOF'
#!/usr/bin/env bash
# The URL is not always the last argument, so classify by scanning every one.
url=""
for a in "$@"; do case "$a" in http://*|https://*) url="$a" ;; esac; done
if [[ "$url" == *"169.254.169.254"* ]]; then printf '%s' '{"access_token":"tok"}'; exit 0; fi
if [[ "$url" == *"vault.azure.net/secrets/"* ]]; then
  echo "$url" >> "$KV_CALLS"
  body="${KV_RESP:-}"
  [ -n "$body" ] || body='{"value":"tskey-from-kv"}'
  printf '%s' "$body"
  exit 0
fi
exit 0
EOF
  chmod +x "$tmp/bin/tailscale" "$tmp/bin/curl"
}

# The body runs in a subshell, and the caller passes extra environment as
# NAME=value words, so one case's Key Vault settings cannot leak into the next.
run_up() (
  env PATH="$tmp/bin:$PATH" STATE_DIR="$tmp/state" \
    AUTH_KEY_FILE="$tmp/devbox/tailscale-authkey" \
    UP_CALLS="$tmp/up-calls" KV_CALLS="$tmp/kv-calls" \
    "$@" "$script"
)

# A failed join is a labelled failure, not a bare exit from set -e.
joined() {
  local case_id="$1" rc=0
  shift
  run_up "$@" >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 0 ] || fail "${case_id} oc-tailnet-up exited ${rc}"
}

# T0: systemd ExecStart runs both scripts directly, so a lost exec bit fails
# every boot and every other case would pass vacuously.
setup
for f in oc-tailnet-up oc-tailnet; do
  [ -x "$here/../bin/$f" ] || fail "T0 $f is not executable"
done

# T1: first boot joins exactly once, with the key file and a stable identity.
printf 'tskey-test\n' > "$tmp/devbox/tailscale-authkey"
joined T1
[ "$(wc -l < "$tmp/up-calls")" -eq 1 ] || fail "T1 first boot did not join exactly once"
grep -q -- '--auth-key file:' "$tmp/up-calls" || fail "T1 join did not use the key file"
if grep -q -- '--ephemeral' "$tmp/up-calls"; then
  fail "T1 join used --ephemeral, which breaks the saved server URL"
fi

# T2: a second boot with state present must not re-auth.
: > "$tmp/state/tailscaled.state"
joined T2
[ "$(wc -l < "$tmp/up-calls")" -eq 1 ] || fail "T2 rejoined with existing state"

# T3: no local key, so it comes from Key Vault, and the join happens once.
setup
[ ! -e "$tmp/devbox/tailscale-authkey" ] || fail "T3 fixture already has a key file"
joined T3 TS_AUTHKEY_SECRET=tailscale-authkey VAULT_NAME=kv
[ "$(wc -l < "$tmp/up-calls")" -eq 1 ] || fail "T3 Key Vault key did not produce one join"
[ "$(wc -l < "$tmp/kv-calls")" -eq 1 ] || fail "T3 expected exactly one Key Vault fetch"
[ "$(cat "$tmp/devbox/tailscale-authkey")" = "tskey-from-kv" ] || fail "T3 wrong key written"
[ "$(stat -c '%a' "$tmp/devbox/tailscale-authkey")" = "600" ] || fail "T3 key file is not 0600"

echo "tailnet join is idempotent"
