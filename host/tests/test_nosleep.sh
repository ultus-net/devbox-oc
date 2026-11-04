#!/usr/bin/env bash
# host/tests/test_nosleep.sh
#
# This box is always on and lives in a server room. A sleep target that is not
# masked, or a logind policy that acts on idle, takes it off the tailnet with no
# way back except a physical visit.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
bu="${1:-$here/../../os/butane/ucore.bu}"
fail() { echo "FAIL: $1" >&2; exit 1; }

[ -f "$bu" ] || fail "no Butane source at $bu"
command -v python3 >/dev/null 2>&1 || fail "python3 is required and absent"
python3 -c 'import yaml' >/dev/null 2>&1 || fail "python3 has no PyYAML module"

python3 - "$bu" <<'PY'
import sys

import yaml

path = sys.argv[1]
with open(path) as handle:
    config = yaml.safe_load(handle)

units = (config.get("systemd") or {}).get("units") or []
masked = {u.get("name") for u in units if u.get("mask") is True}

required = {
    "sleep.target",
    "suspend.target",
    "hibernate.target",
    "hybrid-sleep.target",
    "suspend-then-hibernate.target",
}
missing = sorted(required - masked)
if missing:
    raise SystemExit(f"FAIL: sleep targets are not masked: {', '.join(missing)}")

files = (config.get("storage") or {}).get("files") or []
logind = [
    entry.get("contents", {}).get("inline", "")
    for entry in files
    if (entry.get("path") or "").startswith("/etc/systemd/logind.conf.d/")
]
if not logind:
    raise SystemExit("FAIL: no logind drop-in, so an idle policy can suspend the box")

body = "\n".join(logind)
if "IdleAction=ignore" not in body:
    raise SystemExit("FAIL: logind drop-in does not set IdleAction=ignore")
PY

echo "sleep is masked and idle suspend is ignored"
