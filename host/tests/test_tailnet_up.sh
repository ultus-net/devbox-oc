#!/usr/bin/env bash
# host/tests/test_tailnet_up.sh
#
# The tailnet is the only data path to the box. `tailscale up` is idempotent, so
# a key present must always run it; a state file alone must never suppress a
# join. A successful join must delete the key, and a failed join with state must
# not latch the box off the tailnet. A fake tailscale records joins.
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
if [ "${1:-}" = "up" ]; then
  if [ "${FAIL_UP:-0}" = "1" ]; then exit 1; fi
  echo "$*" >> "$UP_CALLS"
fi
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

# T1: first boot joins exactly once, with the key file and a stable identity,
# then removes the key so a revoked key cannot break later boots.
printf 'tskey-test\n' > "$tmp/devbox/tailscale-authkey"
joined T1
[ "$(wc -l < "$tmp/up-calls")" -eq 1 ] || fail "T1 first boot did not join exactly once"
grep -q -- '--auth-key file:' "$tmp/up-calls" || fail "T1 join did not use the key file"
if grep -q -- '--ephemeral' "$tmp/up-calls"; then
  fail "T1 join used --ephemeral, which breaks the saved server URL"
fi
[ ! -e "$tmp/devbox/tailscale-authkey" ] || fail "T1 the auth key survived a successful join"

# T2: a key present with a state file must still run up. It is idempotent, and
# skipping here is what leaves a half-started node off the tailnet.
printf 'tskey-test\n' > "$tmp/devbox/tailscale-authkey"
: > "$tmp/state/tailscaled.state"
joined T2
[ "$(wc -l < "$tmp/up-calls")" -eq 2 ] \
  || fail "T2 a state file suppressed the idempotent join"
[ ! -e "$tmp/devbox/tailscale-authkey" ] || fail "T2 the auth key survived a successful join"

# T3: no key but existing state is the normal post-join state. Keep the node and
# exit cleanly.
joined T3
[ "$(wc -l < "$tmp/up-calls")" -eq 2 ] || fail "T3 called tailscale with no auth key"
[ -f "$tmp/state/tailscaled.state" ] || fail "T3 removed the tailnet state"

# T4: no key and no state is unrecoverable; fail loudly.
setup
rc=0
run_up >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail "T4 joined with no auth key and no state"
[ ! -s "$tmp/up-calls" ] || fail "T4 called tailscale with no auth key"

# T5: an empty key is the same defect: readable, but useless.
setup
: > "$tmp/devbox/tailscale-authkey"
rc=0
run_up >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail "T5 joined with an empty auth key"

# T6: a revoked key makes `up` fail, but the node already has state. The service
# must still succeed so the serve step runs.
setup
printf 'tskey-revoked\n' > "$tmp/devbox/tailscale-authkey"
: > "$tmp/state/tailscaled.state"
joined T6 FAIL_UP=1
[ "$(wc -l < "$tmp/up-calls")" -eq 0 ] || fail "T6 recorded a successful join that did not happen"

# T7: a failed first join with no state is fatal; there is nothing to keep.
setup
printf 'tskey-bad\n' > "$tmp/devbox/tailscale-authkey"
rc=0
run_up FAIL_UP=1 >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail "T7 swallowed a failed first join"

# T8: the keyless steady state is an empty key file, not a missing one. Ignition
# creates the file empty, and it must not be mistaken for a usable key.
setup
: > "$tmp/devbox/tailscale-authkey"
: > "$tmp/state/tailscaled.state"
joined T8
[ "$(wc -l < "$tmp/up-calls")" -eq 0 ] || fail "T8 called tailscale with an empty key"
[ -f "$tmp/state/tailscaled.state" ] || fail "T8 removed the tailnet state"

echo "tailnet join is idempotent, key-driven and cannot latch"
