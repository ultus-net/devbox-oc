#!/usr/bin/env bash
# os/butane/tests/test_bootc_image.sh
#
# The OS image is built from the ucore bootc container, so a VM boots ucore
# directly. That is what replaced the two-stage autorebase, which existed only
# because the published image was plain Fedora CoreOS.
#
# This file guards the Ignition side: the rebase machinery must not come back.
# The build side (bootc ref, digest pin, default fs, Gen2) is guarded by running
# the script, in os/tests/test_build_os_image.sh.
#
# Every check reads the parsed document and walks all of its scalars. Two failed
# versions of this file bracket the rule:
#   - grepping the raw source fired on a comment that merely named the marker
#     directory, so the guard punished prose instead of the regression
#   - checking three named keys (storage.directories, systemd.units[].contents)
#     missed the same strings in a unit dropin, a storage file, or a link, which
#     is the repo's documented "a rule is only as wide as its reader"
# Walking every scalar covers all of them and still cannot see a comment, because
# comments never survive parsing.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
bu="${1:-$here/../ucore.bu}"

fail() { echo "FAIL: $1" >&2; exit 1; }

[ -f "$bu" ] || fail "no such file: $bu"
command -v python3 >/dev/null 2>&1 || fail "python3 is required and absent"
python3 -c 'import yaml' >/dev/null 2>&1 || fail "python3 has no PyYAML module"

# One parse, every string in the document. A rebase unit, a marker file, a dropin
# or a symlink all reach this list, so the reader is as wide as the rule.
scan="$(python3 - "$bu" <<'PY'
import sys, yaml

def strings(node):
    if isinstance(node, str):
        yield node
    elif isinstance(node, dict):
        for key, value in node.items():
            yield str(key)
            yield from strings(value)
    elif isinstance(node, list):
        for item in node:
            yield from strings(item)

cfg = yaml.safe_load(open(sys.argv[1]))
found = {
    "units": [],
    "marker": [],
    "rebase": [],
}
for unit in (cfg.get("systemd") or {}).get("units") or []:
    found["units"].append(unit.get("name") or "")

for value in strings(cfg):
    if "ucore-autorebase" in value:
        found["marker"].append(value)
    if "rpm-ostree rebase" in value or "bootc switch" in value:
        found["rebase"].append(value)

import json
print(json.dumps(found))
PY
)" || fail "could not parse $bu as YAML"

field() {
  printf '%s' "$scan" | python3 -c 'import json,sys; print("\n".join(json.load(sys.stdin)[sys.argv[1]]))' "$1"
}

units="$(field units)"

# T1: no rebase units. Their return is silent: the box reinstalls itself on first
# boot over an OS that is already ucore.
for banned in ucore-unsigned-autorebase.service ucore-signed-autorebase.service; do
  if printf '%s\n' "$units" | grep -qx "$banned"; then
    fail "$banned is back in the Ignition config, so the box rebases on first boot over an OS that is already ucore"
  fi
done

# T2: no marker path anywhere: not a directory, not a file, not a link. A unit
# gating on a marker means the rebase pair was not removed cleanly.
marker="$(field marker)"
if [ -n "$marker" ]; then
  fail "the Ignition config still names ucore-autorebase: $(printf '%s' "$marker" | tr '\n' ' ')"
fi

# T3: nothing rebases at runtime. Checking the unit contents alone missed a
# dropin, so the scan covers every string in the document. `bootc switch` is
# included because it is the modern spelling of the same multi-boot install, and
# a ban list that only knows the old one goes stale the day the tool changes.
rebases="$(field rebase)"
if [ -n "$rebases" ]; then
  fail "something in the Ignition config rebases at boot, which reintroduces the multi-boot install: $(printf '%s' "$rebases" | tr '\n' ' ')"
fi

# T4: the units that must survive are still declared, so deleting the rebase pair
# did not take a neighbouring unit with it.
for kept in oc-secrets.service oc-tailnet.service oc-idle.timer tailscaled.service; do
  printf '%s\n' "$units" | grep -qx "$kept" \
    || fail "$kept is missing, so removing the rebase stages removed a unit the box needs"
done

echo "the Ignition config has no rebase stage and keeps the units the box needs"
