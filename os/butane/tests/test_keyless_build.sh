#!/usr/bin/env bash
# os/butane/tests/test_keyless_build.sh
#
# A keyless build must put no usable Tailscale secret on the media and must leave
# a console login, because the physical console is the only path before the join.
# A keyed build must still embed the key. Both run through build.sh, so this
# covers the substitution and compile path rather than a reimplemented sed.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$here/../../.." && pwd)"
build="$repo_root/os/butane/build.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fail() { echo "FAIL: $1" >&2; exit 1; }

BUTANE="${BUTANE:-}"
if [ -z "$BUTANE" ]; then
  for candidate in "$(command -v butane 2>/dev/null || true)" "$repo_root/.tools/butane"; do
    if [ -n "$candidate" ] && [ -x "$candidate" ]; then
      BUTANE="$candidate"
      break
    fi
  done
fi
if [ -z "$BUTANE" ] || [ ! -x "$BUTANE" ]; then
  echo "SKIP: no Butane binary; set BUTANE to compile the artifact"
  exit 0
fi
# build.sh reads BUTANE from the environment; a fallback found here must be
# exported or the child falls back to podman.
export BUTANE

export SSH_PUBKEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl keyless-test"
export OC_HOSTNAME=devbox
# This suite is about the console door and the key, not the pin, so it uses a
# fixture digest and the escape. A tree with no promoted record then still runs
# it; test_image_pin.sh owns the pin and the shapes it refuses.
export ALLOW_UNPINNED_IMAGE=1
export IMAGE="ghcr.io/example/devbox@sha256:0000000000000000000000000000000000000000000000000000000000000000"

keyfile="/etc/devbox/tailscale-authkey"
autologin="/etc/systemd/system/getty@tty1.service.d/10-autologin.conf"

source_of() {
  jq -r --arg p "$1" '.storage.files[] | select(.path==$p) | (.contents.source? // "")' "$2"
}

decode() {
  sed 's/^data:,//' \
    | python3 -c 'import sys, urllib.parse; sys.stdout.write(urllib.parse.unquote(sys.stdin.read()))'
}

# Keyless: no key variable at all must compile and leave the key file empty.
env -u TS_AUTHKEY -u ALLOW_PLACEHOLDERS "$build" "$tmp/keyless.ign" >/dev/null 2>&1 \
  || fail "keyless build exited non-zero"
jq -e '.ignition.version' "$tmp/keyless.ign" >/dev/null || fail "keyless build is not Ignition"
jq -e --arg p "$keyfile" '[.storage.files[] | select(.path==$p)] | length == 1' \
  "$tmp/keyless.ign" >/dev/null || fail "keyless build dropped the auth key path"
[ -z "$(source_of "$keyfile" "$tmp/keyless.ign")" ] \
  || fail "keyless build wrote a usable auth key"

# The console is the only way in before the join, so the autologin must ship.
# Assert the reset and the full command: a wrong agetty path or a missing
# `ExecStart=` reset still contains `--autologin` and would pass a loose grep.
jq -e --arg p "$autologin" '[.storage.files[] | select(.path==$p)] | length == 1' \
  "$tmp/keyless.ign" >/dev/null || fail "keyless build has no console autologin"
dropin="$(source_of "$autologin" "$tmp/keyless.ign" | decode)"
printf '%s\n' "$dropin" | grep -qx 'ExecStart=' \
  || fail "console autologin does not reset ExecStart"
printf '%s\n' "$dropin" \
  | grep -Fqx "ExecStart=-/usr/sbin/agetty --autologin core --noreset --noclear - \${TERM}" \
  || fail "console autologin does not use the getty command"

# Keyed: the key is embedded, and the console autologin stays for recovery.
key="tskey-auth-KEYED_TEST_123"
TS_AUTHKEY="$key" "$build" "$tmp/keyed.ign" >/dev/null 2>&1 || fail "keyed build exited non-zero"
source_of "$keyfile" "$tmp/keyed.ign" | decode | grep -qx -- "$key" \
  || fail "keyed build did not embed the auth key"
jq -e --arg p "$autologin" '[.storage.files[] | select(.path==$p)] | length == 1' \
  "$tmp/keyed.ign" >/dev/null || fail "keyed build dropped the console autologin"

echo "keyless and keyed builds are both valid"
