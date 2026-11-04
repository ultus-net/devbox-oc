#!/usr/bin/env bash
# host/tests/test_no_lan_listener.sh
#
# The box has one door: the tailnet. Fedora CoreOS enables sshd, and ucore's
# server firewalld profile lets it through on the wired LAN, so sshd must be
# masked. Tailscale SSH runs inside tailscaled and does not need it.
#
# The guard parses the Ignition source and walks every declared Listener, so a
# listener added to a drop-in later cannot slip past a named-unit check.
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

with open(sys.argv[1]) as handle:
    config = yaml.safe_load(handle)

units = (config.get("systemd") or {}).get("units") or []
masked = {u.get("name") for u in units if u.get("mask") is True}

required = {"sshd.service", "sshd.socket"}
missing = sorted(required - masked)
if missing:
    raise SystemExit(
        "FAIL: the LAN ssh listener is not masked: " + ", ".join(missing)
    )

# Walk every listener in every unit body and drop-in.
offenders = []
for unit in units:
    bodies = [(unit.get("name"), unit.get("contents") or "")]
    bodies += [
        (f"{unit.get('name')}/{drop.get('name')}", drop.get("contents") or "")
        for drop in unit.get("dropins") or []
    ]
    for name, body in bodies:
        for line in body.splitlines():
            stripped = line.strip()
            if not stripped.startswith("ListenStream="):
                continue
            value = stripped.split("=", 1)[1].strip()
            if value == "":
                continue
            if value.startswith("127.0.0.1:") or value.startswith("[::1]:"):
                continue
            offenders.append(f"{name}: {stripped}")

if offenders:
    raise SystemExit(
        "FAIL: a non-loopback listener is declared:\n  " + "\n  ".join(offenders)
    )

print(f"sshd is masked and {len(units)} units declare only loopback listeners")
PY
