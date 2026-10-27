#!/usr/bin/env bash
# os/butane/tests/test_autorebase.sh
#
# The published Azure image is Fedora CoreOS, because Fedora publishes no ucore
# VHD and the design forbids forking ucore. Ignition therefore has to rebase the
# box onto the ucore image on first boot, or the host runs plain FCOS: no
# tailscale package, zincati instead of ucore's update path, and none of the
# assumptions every host unit makes.
#
# ucore documents this as two stages. The first rebase binds an unverified
# reference and reboots. Only after booting ucore does the container-signing
# policy exist that lets the second stage accept a signed reference. Collapsing
# them into one stage fails, because the policy is absent on the first boot.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
bu="${1:-$here/../ucore.bu}"
fail() { echo "FAIL: $1" >&2; exit 1; }

[ -f "$bu" ] || fail "no such file: $bu"

# Take a unit's block by line number. An awk range whose end pattern matches the
# start line collapses to one line and reads as absent.
block_of() {
  local name="$1" start
  start="$(grep -n -- "- name: ${name}\$" "$bu" | head -1 | cut -d: -f1 || true)"
  [ -n "$start" ] || return 1
  tail -n "+$start" "$bu" | awk 'NR > 1 && /^    - name: /{exit} {print}'
}

unsigned="$(block_of ucore-unsigned-autorebase.service)" \
  || fail "ucore-unsigned-autorebase.service is not in the Ignition config"
signed="$(block_of ucore-signed-autorebase.service)" \
  || fail "ucore-signed-autorebase.service is not in the Ignition config"

for pair in "unsigned:$unsigned" "signed:$signed"; do
  label="${pair%%:*}"
  body="${pair#*:}"
  printf '%s\n' "$body" | grep -Eq '^[[:space:]]+enabled: true[[:space:]]*$' \
    || fail "${label} autorebase unit is present but not enabled"
  printf '%s\n' "$body" | grep -Eq '^[[:space:]]*ExecStart=/usr/bin/rpm-ostree rebase ' \
    || fail "${label} autorebase unit does not rebase"
  printf '%s\n' "$body" | grep -Eq '^[[:space:]]*ExecStart=/usr/bin/systemctl reboot[[:space:]]*$' \
    || fail "${label} autorebase unit does not reboot into the new deployment"
  # A marker per stage is what stops a reboot loop. Without it the unit is
  # enabled, the condition is always true, and the box reboots forever.
  printf '%s\n' "$body" | grep -Eq '^[[:space:]]*ExecStart=/usr/bin/touch /etc/ucore-autorebase/' \
    || fail "${label} autorebase unit writes no marker, so it can reboot-loop"
done

# Stage 1 must be the unverified reference, and stage 2 the signed one. Swapping
# them asks for a signed rebase before any policy exists, which fails on boot.
printf '%s\n' "$unsigned" \
  | grep -Eq 'rpm-ostree rebase .*ostree-unverified-registry:ghcr\.io/ublue-os/ucore-minimal:stable' \
  || fail "stage 1 does not rebase to the unverified ucore-minimal reference"
printf '%s\n' "$signed" \
  | grep -Eq 'rpm-ostree rebase ostree-image-signed:docker://ghcr\.io/ublue-os/ucore-minimal:stable' \
  || fail "stage 2 does not rebase to the signed ucore-minimal reference"

# The two stages must be ordered by their markers, or both run on the same boot.
printf '%s\n' "$unsigned" | grep -q 'ConditionPathExists=!/etc/ucore-autorebase/unverified' \
  || fail "stage 1 has no marker condition, so it reruns after it already ran"
printf '%s\n' "$signed" | grep -q 'ConditionPathExists=/etc/ucore-autorebase/unverified' \
  || fail "stage 2 does not wait for stage 1's marker"
printf '%s\n' "$signed" | grep -q 'ConditionPathExists=!/etc/ucore-autorebase/signed' \
  || fail "stage 2 has no marker condition, so it reruns after it already ran"

# The units write markers into this directory, so Ignition must create it. A
# touch into a missing directory fails and the rebase never completes.
grep -Eq '^[[:space:]]*- path: /etc/ucore-autorebase[[:space:]]*$' "$bu" \
  || fail "the marker directory /etc/ucore-autorebase is not created"

echo "the two-stage ucore autorebase is configured"
