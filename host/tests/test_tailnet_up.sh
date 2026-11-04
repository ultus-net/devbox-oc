#!/usr/bin/env bash
# host/tests/test_tailnet_up.sh
# The tailnet is the only data path to the box, so the join must happen once on
# first boot and never again once state exists. A fake tailscale records joins.
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
  cat > "$tmp/bin/tailscale" <<'EOF'
#!/usr/bin/env bash
[[ "${1:-}" == "up" ]] && { echo "$*" >> "$UP_CALLS"; exit 0; }
exit 0
EOF
  chmod +x "$tmp/bin/tailscale"
}

run_up() (
  env PATH="$tmp/bin:$PATH" STATE_DIR="$tmp/state" \
    AUTH_KEY_FILE="$tmp/devbox/tailscale-authkey" \
    UP_CALLS="$tmp/up-calls" "$@" "$script"
)

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

# T3: no key file is a labelled failure, not a silent skip.
setup
rc=0
run_up >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail "T3 joined with no auth key"
[ ! -s "$tmp/up-calls" ] || fail "T3 called tailscale with no auth key"

# T4: an empty key file is the same defect: readable, but useless.
setup
: > "$tmp/devbox/tailscale-authkey"
rc=0
run_up >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail "T4 joined with an empty auth key"

echo "tailnet join is idempotent and needs a real key"
