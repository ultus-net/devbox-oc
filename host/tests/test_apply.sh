#!/usr/bin/env bash
# host/tests/test_apply.sh
#
# devbox-apply is the only writer of host configuration, so the properties that
# matter are what it writes, that it refuses a digest the repo's record format
# does not allow, that it refuses to write a half-rendered unit, and that a
# second run over the same root changes nothing. Run it against a scratch root
# rather than reading its source.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
script="$here/../bin/devbox-apply"
tree="$here/../.."
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }

# The record is the shape the repo ships: comments above one sha256 line. A bare
# digest is not the input, and a fixture that uses one hides a parse that cannot
# read the real file.
digest="$(printf 'a%.0s' $(seq 1 64))"
{
  printf '# The promoted :prod digest.\n'
  printf 'sha256:%s\n' "$digest"
} >"$tmp/record"

run_apply() (
  env DEVBOX_ROOT="$1" DEVBOX_DIGEST_FILE="$2" DEVBOX_NO_ACTIVATE=1 \
    DEVBOX_TREE="${3:-$tree}" "$script"
)

# A snapshot of content and mode. mtime is excluded on purpose: every file is
# installed by replacement, so a rewrite is legitimate as long as the bytes and
# the mode are unchanged. An append changes the bytes and is caught here.
snapshot() {
  cd "$1" || fail "no root at $1"
  find . \( -type f -o -type l \) -printf '%p %y %m %l\n' | sort
  find . -type f -print0 | sort -z | xargs -0 sha256sum
}

# T1: a run installs the host layer into the given root.
root="$tmp/root1"
run_apply "$root" "$tmp/record" >/dev/null || fail "T1 apply exited non-zero"

for f in oc-env hermes-env oc-paths oc-tailnet oc-tailnet-up devbox-apply; do
  [ -x "$root/usr/local/sbin/$f" ] || fail "T1 $f is not installed executable"
done

for f in oc-paths oc-env hermes-env oc-tailnet devbox-apply oc-backup; do
  [ -f "$root/etc/systemd/system/$f.service" ] || fail "T1 $f.service missing"
done
[ -f "$root/etc/systemd/system/oc-backup.timer" ] || fail "T1 oc-backup.timer missing"
# The apply unit runs the tree copy, not the installed one, so a stale
# /usr/local/sbin/devbox-apply cannot quietly win on the next boot.
grep -qx 'ExecStart=/srv/repos/devbox-oc/host/bin/devbox-apply' \
  "$root/etc/systemd/system/devbox-apply.service" \
  || fail "T1 the apply unit does not run the tracked tree"
# A workload that starts before this unit ran would keep the previous quadlet.
grep -q '^Before=opencode.service hermes.service' \
  "$root/etc/systemd/system/devbox-apply.service" \
  || fail "T1 the apply unit does not order itself before the workloads"

quadlet="$root/etc/containers/systemd/opencode.container"
[ -f "$quadlet" ] || fail "T1 the OpenCode quadlet is missing"
grep -q "ghcr.io/ultus-net/devbox@sha256:$digest" "$quadlet" \
  || fail "T1 the digest is not rendered into the repository that publishes it"
grep -qE '__[A-Z_]+__' "$quadlet" && fail "T1 an unrendered placeholder survived"
[ "$(stat -c '%a' "$quadlet")" = "644" ] || fail "T1 the quadlet mode is not 0644"

# T2: the always-on policy and the single-door policy are written, not assumed.
for unit in sleep.target suspend.target hibernate.target hybrid-sleep.target \
  suspend-then-hibernate.target sshd.service sshd.socket; do
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

# T3: a second run over the same root changes nothing. Two fresh roots would only
# prove determinism, and would miss an append to a file the first run wrote.
snapshot "$root" >"$tmp/before"
run_apply "$root" "$tmp/record" >/dev/null || fail "T3 second run exited non-zero"
snapshot "$root" >"$tmp/after"
diff -u "$tmp/before" "$tmp/after" >/dev/null \
  || fail "T3 apply is not idempotent: a second run changed content or mode"

# T4: a record the parse does not accept fails closed before anything is written.
for bad in REPLACE_ME PENDING abc123; do
  printf '%s\n' "$bad" >"$tmp/bad"
  rc=0
  run_apply "$tmp/bad-root" "$tmp/bad" >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "T4 apply accepted the record value $bad"
  [ ! -e "$tmp/bad-root/etc" ] || fail "T4 apply wrote files before it failed"
done

# T5: a record holding two digests is ambiguous and fails.
{
  printf 'sha256:%s\n' "$digest"
  printf 'sha256:%s\n' "$(printf 'b%.0s' $(seq 1 64))"
} >"$tmp/two"
rc=0
run_apply "$tmp/two-root" "$tmp/two" >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail "T5 apply accepted a record with two digests"

# T6: a quadlet carrying a placeholder the renderer does not know fails before it
# is installed, so no unit with a literal placeholder reaches the generator. The
# tree has the same shape the script requires: host/bin, host/quadlet, host/units.
mkdir -p "$tmp/tree/host"
cp -r "$here/../bin" "$here/../quadlet" "$here/../units" "$here/../config" \
  "$tmp/tree/host/"
# Positive control first: the same fixture without the bad quadlet must succeed,
# or the negative case would pass for the wrong reason.
run_apply "$tmp/control-root" "$tmp/record" "$tmp/tree" >/dev/null \
  || fail "T6 the fixture tree is rejected before the placeholder check"
printf '[Container]\nImage=__UNRENDERED__\n' >"$tmp/tree/host/quadlet/zz-bad.container"
rc=0
run_apply "$tmp/placeholder-root" "$tmp/record" "$tmp/tree" >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail "T6 apply accepted a placeholder it cannot render"
[ ! -e "$tmp/placeholder-root/etc/containers/systemd/zz-bad.container" ] \
  || fail "T6 apply installed a unit with an unrendered placeholder"

# T7: activation from inside the unit must not block on the workloads it is
# ordered before, and a manual run must block so the operator sees them up.
mkdir -p "$tmp/stub"
cat >"$tmp/stub/systemctl" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >>"$SYSTEMCTL_LOG"
STUB
chmod +x "$tmp/stub/systemctl"

activate() {
  env -u INVOCATION_ID DEVBOX_ROOT="$1" DEVBOX_DIGEST_FILE="$tmp/record" \
    PATH="$tmp/stub:$PATH" SYSTEMCTL_LOG="$2" "${@:3}" "$script"
}

activate "$tmp/manual-root" "$tmp/manual.log" >/dev/null \
  || fail "T7 the manual activation run exited non-zero"
grep -qx 'start opencode.service hermes.service' "$tmp/manual.log" \
  || fail "T7 the manual run does not block on the workloads"

activate "$tmp/unit-root" "$tmp/unit.log" INVOCATION_ID=test >/dev/null \
  || fail "T7 the unit activation run exited non-zero"
grep -qx 'start --no-block opencode.service hermes.service' "$tmp/unit.log" \
  || fail "T7 the unit run blocks on a job ordered after it"

echo "devbox-apply renders, masks the doors, and is idempotent"
