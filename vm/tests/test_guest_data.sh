#!/usr/bin/env bash
# vm/tests/test_guest_data.sh
#
# guest-data.sh runs systemd-repart against the harness data disk. Pointed at the
# OS disk it would destroy the running system, so the guard that refuses the root
# device is load-bearing. The script only runs its body when executed, so this
# test sources it and drives the decision with fixture device names.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
vm="$(cd "$here/.." && pwd)"
fail() { echo "FAIL: $1" >&2; exit 1; }

# The source path is resolved at run time, so shellcheck cannot follow it. The
# predicate under test lives in that file and nowhere else.
# shellcheck disable=SC1090,SC1091
# shellcheck source=../guest-data.sh
. "$vm/guest-data.sh"

# T1: the whole OS disk and its root partition are both refused.
if ! refuses_root_device /dev/vda /dev/vda4 /dev/vda; then
  fail "T1: the whole OS disk was accepted as the data disk"
fi
if ! refuses_root_device /dev/vda4 /dev/vda4 /dev/vda; then
  fail "T1: the root partition was accepted as the data disk"
fi

# T2: a separate disk is accepted, with a resolvable parent disk.
if refuses_root_device /dev/vdb /dev/vda4 /dev/vda; then
  fail "T2: the separate data disk was refused"
fi

# T3: an unknown root device is not treated as a conflict.
if refuses_root_device /dev/vdb "" ""; then
  fail "T3: a missing root source was reported as a conflict"
fi

# Teeth: invert the comparison and the data-disk case above must fail. Prove the
# mutation lands and changes the answer the guard gives.
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mutated="$tmp/guest-data.sh"
# shellcheck disable=SC2016  # sed patterns, not shell expansions.
sed 's/\[ "\$dev" = "\$root_src" \]/[ "$dev" != "$root_src" ]/' \
  "$vm/guest-data.sh" > "$mutated"
cmp -s "$vm/guest-data.sh" "$mutated" && fail "mutation did not land"
# shellcheck disable=SC1090  # the mutated copy is a run-time path.
if ( . "$mutated" >/dev/null 2>&1; refuses_root_device /dev/vdb /dev/vda4 /dev/vda ); then
  : # the inverted guard refuses the data disk, so T2 would fail
else
  fail "mutation survived: an inverted guard still accepted the data disk"
fi

echo "guest data script refuses the device that backs /"
