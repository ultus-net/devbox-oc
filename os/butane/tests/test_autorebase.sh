#!/usr/bin/env bash
# os/butane/tests/test_autorebase.sh
#
# The install path is Fedora CoreOS media, then one rebase to ucore-minimal.
# This guard keeps that path honest: the rebase must be pinned to the ucore
# reference in the source, it must run once, and it must reboot.
#
# It also keeps the deleted Azure image path deleted. A VHD or managed-image unit
# reappearing here means the pivot was only half applied.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
bu="${1:-$here/../ucore.bu}"
fail() { echo "FAIL: $1" >&2; exit 1; }

[ -f "$bu" ] || fail "no such file: $bu"
command -v python3 >/dev/null 2>&1 || fail "python3 is required and absent"
python3 -c 'import yaml' >/dev/null 2>&1 || fail "python3 has no PyYAML module"

python3 - "$bu" <<'PY'
import sys

import yaml

path = sys.argv[1]
with open(path) as handle:
    config = yaml.safe_load(handle)

units = (config.get("systemd") or {}).get("units") or []
autorebase = [u for u in units if "autorebase" in (u.get("name") or "")]
if len(autorebase) != 1:
    raise SystemExit(
        f"FAIL: expected exactly one autorebase unit, found {len(autorebase)}"
    )

unit = autorebase[0]
body = unit.get("contents") or ""
required = [
    "/usr/bin/rpm-ostree rebase",
    "--bypass-driver",
    "ostree-unverified-registry:__UCORE_IMAGE__",
    "ConditionPathExists=!/etc/ucore-autorebase/done",
    "/usr/bin/touch /etc/ucore-autorebase/done",
    "systemctl disable",
    "/usr/bin/systemctl reboot",
]
missing = [line for line in required if line not in body]
if missing:
    raise SystemExit(
        "FAIL: the autorebase unit is incomplete; missing:\n  " + "\n  ".join(missing)
    )
if unit.get("enabled") is not True:
    raise SystemExit("FAIL: the autorebase unit is not enabled")

files = {
    entry.get("path")
    for entry in (config.get("storage") or {}).get("files") or []
}
if "/etc/devbox/tailscale-authkey" not in files:
    raise SystemExit("FAIL: the install config does not carry the Tailscale key")

for forbidden in ("azure", "vhd", "managed image", "storage account"):
    if forbidden in body.lower():
        raise SystemExit(f"FAIL: the autorebase unit mentions {forbidden}")
PY

echo "one autorebase unit, enabled, pinned and rebooted"
