#!/usr/bin/env bash
# os/butane/tests/test_bootc_image.sh
#
# The OS image is built from the ucore bootc container, so a VM boots ucore
# directly. That is what replaced the two-stage autorebase, which existed only
# because the published image was plain Fedora CoreOS.
#
# This file guards the Ignition side: the rebase machinery must not come back.
# The build side (bootc ref, digest pin, default fs, Gen2) is guarded by running
# the script, in os/tests/test_build_os_image.sh. Asserting it here by reading the
# script's text would be a rule that passes on a comment, which this repo has been
# bitten by more than once.
#
# An autorebase unit returning is silent: the box reinstalls itself on first boot
# over an OS that was already ucore, and the only symptom is an unexplained reboot.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
bu="${1:-$here/../ucore.bu}"

fail() { echo "FAIL: $1" >&2; exit 1; }

[ -f "$bu" ] || fail "no such file: $bu"
command -v python3 >/dev/null 2>&1 || fail "python3 is required and absent"
python3 -c 'import yaml' >/dev/null 2>&1 || fail "python3 has no PyYAML module"

# T1: no rebase units, read through the YAML parser so a comment cannot satisfy
# or break the check.
units="$(python3 - "$bu" <<'PY'
import sys, yaml
cfg = yaml.safe_load(open(sys.argv[1]))
for unit in (cfg.get("systemd") or {}).get("units") or []:
    print(unit.get("name") or "")
PY
)"
for banned in ucore-unsigned-autorebase.service ucore-signed-autorebase.service; do
  if printf '%s\n' "$units" | grep -qx "$banned"; then
    fail "$banned is back in the Ignition config, so the box rebases on first boot over an OS that is already ucore"
  fi
done

# T2: no marker directory. Its presence is the other half of the same regression:
# a unit that gates on markers means the rebase pair was not removed cleanly.
if grep -q "ucore-autorebase" "$bu"; then
  fail "the Ignition config still names ucore-autorebase, which only the rebase stages used"
fi

# T3: nothing rebases at runtime. A rebase in any surviving unit would reintroduce
# the multi-boot path with no marker to stop it looping.
if grep -q "rpm-ostree rebase" "$bu"; then
  fail "a surviving unit runs rpm-ostree rebase, which reintroduces the multi-boot install"
fi

# T4: the units that must survive are still declared, so deleting the rebase pair
# did not take a neighbouring unit with it.
for kept in oc-secrets.service oc-tailnet.service oc-idle.timer tailscaled.service; do
  printf '%s\n' "$units" | grep -qx "$kept" \
    || fail "$kept is missing, so removing the rebase stages removed a unit the box needs"
done

echo "the Ignition config has no rebase stage and keeps the units the box needs"
