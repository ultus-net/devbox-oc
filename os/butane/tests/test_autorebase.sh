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

# Directive values, matched at the start of a line. An unanchored grep is
# satisfied by a commented-out directive, which reports success while the unit
# does nothing.
directive_values() { printf '%s\n' "$1" | sed -n "s|^[[:space:]]*$2[[:space:]]*=[[:space:]]*||p"; }

# Fields after a directive prefix, so one ExecStart= can be told from another.
directive_fields() { printf '%s\n' "$1" | sed -n "s|^[[:space:]]*$2[[:space:]][[:space:]]*||p"; }

# The body of one [Section] inside a unit. Every directive below is
# section-sensitive: systemd logs `Unknown key ... in section [Service],
# ignoring` for a key in the wrong section and carries on, so a section-blind
# grep passes on a unit that has no ordering, no condition, and no enablement.
section_of() { printf '%s\n' "$1" | awk -v want="$2" '
  /^[[:space:]]*\[/ { name=$0; gsub(/^[[:space:]]*\[|\][[:space:]]*$/, "", name); on=(name==want); next }
  on { print }
'; }

unsigned="$(block_of ucore-unsigned-autorebase.service)" \
  || fail "ucore-unsigned-autorebase.service is not in the Ignition config"
signed="$(block_of ucore-signed-autorebase.service)" \
  || fail "ucore-signed-autorebase.service is not in the Ignition config"

for pair in "unsigned:$unsigned" "signed:$signed"; do
  label="${pair%%:*}"
  body="${pair#*:}"
  service="$(section_of "$body" Service)"
  unit_sec="$(section_of "$body" Unit)"
  [ -n "$service" ] || fail "${label} autorebase unit has no [Service] section"
  [ -n "$unit_sec" ] || fail "${label} autorebase unit has no [Unit] section"
  # The unit-level key, not any line in the block. A `enabled: true` line inside
  # `contents: |` is unit text, not YAML, and satisfies a whole-block grep while
  # Butane renders no enabled flag at all. The key sits at exactly six spaces.
  printf '%s\n' "$body" | grep -Eq '^      enabled: true[[:space:]]*$' \
    || fail "${label} autorebase unit is present but not enabled"
  directive_fields "$service" 'ExecStart=/usr/bin/rpm-ostree rebase' \
    | grep -q 'rpm-ostree\|ostree-' \
    || fail "${label} autorebase unit does not rebase"
  directive_values "$service" 'ExecStart' | grep -Fxq '/usr/bin/systemctl reboot' \
    || fail "${label} autorebase unit does not reboot into the new deployment"
  # ExecStart= without [Install] leaves the unit static: no enablement symlink is
  # created, so it never starts. `systemctl --root is-enabled` reports "static"
  # and the boot sequence stops one step short of ucore with nothing in the log.
  #
  # Both keys are read from [Install] specifically. WantedBy= in [Service] is
  # ignored with a warning, which is the same never-enabled outcome wearing a
  # line a section-blind grep accepts.
  install_sec="$(section_of "$body" Install)"
  [ -n "$install_sec" ] || fail "${label} autorebase unit has no [Install] section, so it is never enabled"
  directive_values "$install_sec" 'WantedBy' | grep -Fxq 'multi-user.target' \
    || fail "${label} autorebase unit is not wanted by multi-user.target in [Install]"
done

# Stage 1 must be the unverified reference, and stage 2 the signed one. Swapping
# them asks for a signed rebase before any policy exists, which fails on boot.
printf '%s\n' "$unsigned" \
  | grep -Eq 'rpm-ostree rebase .*ostree-unverified-registry:ghcr\.io/ublue-os/ucore-minimal:stable' \
  || fail "stage 1 does not rebase to the unverified ucore-minimal reference"
printf '%s\n' "$signed" \
  | grep -Eq 'rpm-ostree rebase ostree-image-signed:docker://ghcr\.io/ublue-os/ucore-minimal:stable' \
  || fail "stage 2 does not rebase to the signed ucore-minimal reference"

# A marker per stage is what stops a reboot loop. Without it the unit is enabled,
# the condition is always true, and the box reboots forever.
#
# The marker a stage reads and the marker it writes must be the same string. A
# rename on one side only is a reboot loop that reads as configured, so bind the
# two together instead of checking each against a literal.
marker_written() {
  local body="$1" found
  found="$(directive_fields "$(section_of "$body" Service)" 'ExecStart=/usr/bin/touch' | awk 'NF{print $1}')"
  case "$found" in
    /etc/ucore-autorebase/?*) printf '%s\n' "$found" ;;
    *) fail "an autorebase stage writes no marker under /etc/ucore-autorebase" ;;
  esac
}
marker_unsigned="$(marker_written "$unsigned")"
marker_signed="$(marker_written "$signed")"
[ "$marker_unsigned" != "$marker_signed" ] \
  || fail "both stages write the same marker, so one of them never runs"

# Stage 1 runs while its own marker is absent and the later stage has not run.
# Conditions are read from [Unit], where systemd honours them.
expect_condition() {
  local label="$1" body="$2" condition="$3"
  directive_values "$(section_of "$body" Unit)" 'ConditionPathExists' \
    | grep -Fxq "$condition" \
    || fail "${label} does not carry 'ConditionPathExists=${condition}' in [Unit]"
}
expect_condition stage-1 "$unsigned" "!${marker_unsigned}"
expect_condition stage-1 "$unsigned" "!${marker_signed}"
# Stage 2 runs only once stage 1 has recorded its switch, and only once.
expect_condition stage-2 "$signed" "${marker_unsigned}"
expect_condition stage-2 "$signed" "!${marker_signed}"

# Each stage disables itself before rebooting, so a marker deleted later does not
# replay the rebase. The name it disables must be the unit doing the disabling.
for pair in "ucore-unsigned-autorebase.service:$unsigned" "ucore-signed-autorebase.service:$signed"; do
  unit_name="${pair%%:*}"
  body="${pair#*:}"
  directive_fields "$(section_of "$body" Service)" 'ExecStart=/usr/bin/systemctl disable' \
    | grep -Fxq "$unit_name" \
    || fail "${unit_name} does not disable itself before rebooting"
done

# The units write markers into this directory, so Ignition must create it. A
# touch into a missing directory fails and the rebase never completes.
grep -Eq '^[[:space:]]*- path: /etc/ucore-autorebase[[:space:]]*$' "$bu" \
  || fail "the marker directory /etc/ucore-autorebase is not created"

echo "the two-stage ucore autorebase is configured"
