#!/usr/bin/env bash
# host/tests/test_apply.sh
#
# devbox-apply is the only writer of host configuration, so the properties that
# matter are what it writes, that it refuses to write a half-rendered unit, and
# that a second run changes nothing. Run it against a scratch root rather than
# reading its source.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
script="$here/../bin/devbox-apply"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }

digest="$(printf 'a%.0s' $(seq 1 64))"
printf '%s\n' "$digest" >"$tmp/digest"

run_apply() (
  env DEVBOX_ROOT="$1" DEVBOX_DIGEST_FILE="$2" DEVBOX_NO_ACTIVATE=1 "$script"
)

# T1: a run installs the host layer into the given root.
run_apply "$tmp/root1" "$tmp/digest" >/dev/null || fail "T1 apply exited non-zero"
root="$tmp/root1"

for f in oc-env hermes-env oc-paths oc-tailnet oc-tailnet-up devbox-apply; do
  [ -x "$root/usr/local/sbin/$f" ] || fail "T1 $f is not installed executable"
done

for f in oc-paths oc-env hermes-env oc-tailnet devbox-apply; do
  [ -f "$root/etc/systemd/system/$f.service" ] || fail "T1 $f.service missing"
done
# The apply unit runs the tree copy, not the installed one, so a stale
# /usr/local/sbin/devbox-apply cannot quietly win on the next boot.
grep -qx 'ExecStart=/srv/repos/devbox-oc/host/bin/devbox-apply' \
  "$root/etc/systemd/system/devbox-apply.service" \
  || fail "T1 the apply unit does not run the tracked tree"

quadlet="$root/etc/containers/systemd/opencode.container"
[ -f "$quadlet" ] || fail "T1 the OpenCode quadlet is missing"
grep -q "ghcr.io/ultus-net/devbox-oc@sha256:$digest" "$quadlet" \
  || fail "T1 the digest is not rendered into the quadlet"
grep -q '__IMAGE__' "$quadlet" && fail "T1 an unrendered placeholder survived"
[ "$(stat -c '%a' "$quadlet")" = "644" ] || fail "T1 the quadlet mode is not 0644"

# T2: the always-on policy and the single-door policy are written, not assumed.
for unit in sleep.target suspend.target hibernate.target hybrid-sleep.target; do
  [ "$(readlink "$root/etc/systemd/system/$unit" || true)" = "/dev/null" ] \
    || fail "T2 $unit is not masked"
done
grep -q '^IdleAction=ignore' "$root/etc/systemd/logind.conf.d/10-devbox-login.conf" \
  || fail "T2 logind does not ignore idle"
grep -q '^LLMNR=no' "$root/etc/systemd/resolved.conf.d/10-devbox-resolved.conf" \
  || fail "T2 resolved still answers LLMNR"
grep -q 'ListenStream=127.0.0.1:9090' \
  "$root/etc/systemd/system/cockpit.socket.d/10-devbox.conf" \
  || fail "T2 cockpit is not rebound to loopback"

# T3: a second run with the same tree changes nothing.
run_apply "$tmp/root2" "$tmp/digest" >/dev/null || fail "T3 second run exited non-zero"
diff -r "$tmp/root1" "$tmp/root2" >/dev/null || fail "T3 apply is not idempotent"

# T4: a digest that is not a digest fails closed before anything is written.
printf 'REPLACE_ME\n' >"$tmp/bad-digest"
rc=0
run_apply "$tmp/root3" "$tmp/bad-digest" >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail "T4 apply accepted a placeholder digest"
[ ! -e "$tmp/root3/etc" ] || fail "T4 apply wrote files before it failed"

# T5: a short digest fails, so a truncated record cannot ship.
printf 'abc123\n' >"$tmp/short"
rc=0
run_apply "$tmp/root4" "$tmp/short" >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail "T5 apply accepted a short digest"

echo "devbox-apply renders, masks, and is idempotent"
