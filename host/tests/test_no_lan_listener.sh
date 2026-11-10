#!/usr/bin/env bash
# host/tests/test_no_lan_listener.sh
#
# The box has one door: the tailnet. Fedora CoreOS enables sshd, and ucore's
# server firewalld profile lets it through on the wired LAN, so sshd must be
# masked. Tailscale SSH runs inside tailscaled and does not need it.
#
# The guard parses the Ignition source and walks every declared Listener, so a
# listener added to a drop-in later cannot slip past a named-unit check. It also
# requires the systemd-resolved drop-in that turns off LLMNR and mDNS, which are
# responders on every interface but are not units.
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

# LLMNR (5355) and mDNS (5353) are not systemd sockets and never appear as
# ListenStream, so a unit scan cannot see them. systemd-resolved answers both on
# every interface by default. Require the global switch-off in a drop-in.
files = (config.get("storage") or {}).get("files") or []
resolved_dropins = [
    f for f in files
    if str(f.get("path") or "").startswith("/etc/systemd/resolved.conf.d/")
]
if not resolved_dropins:
    raise SystemExit(
        "FAIL: no resolved.conf.d drop-in disables LLMNR and mDNS, which answer "
        "on 5355 and 5353 on every interface")

resolved_text = "\n".join(
    str((f.get("contents") or {}).get("inline") or "") for f in resolved_dropins)
for key in ("LLMNR=no", "MulticastDNS=no"):
    if key not in resolved_text:
        raise SystemExit(f"FAIL: the resolved drop-in does not set {key}")

print(f"sshd is masked, {len(units)} units declare only loopback listeners, "
      "and LLMNR and mDNS are off")
PY

# Teeth: drop the resolved drop-in and the guard must fail. A unit-only scan
# passes the mutated config, which is the defect this check exists to catch.
if [ "$#" -eq 0 ]; then
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  python3 - "$bu" "$tmp/mutated.bu" <<'PY'
import sys

import yaml

with open(sys.argv[1]) as handle:
    config = yaml.safe_load(handle)
files = config["storage"]["files"]
config["storage"]["files"] = [
    f for f in files
    if not str(f.get("path") or "").startswith("/etc/systemd/resolved.conf.d/")
]
with open(sys.argv[2], "w") as handle:
    yaml.safe_dump(config, handle, sort_keys=False)
PY
  cmp -s "$bu" "$tmp/mutated.bu" && fail "mutation did not land"
  if "$0" "$tmp/mutated.bu" >/dev/null 2>&1; then
    fail "the guard accepted a config with LLMNR and mDNS still answering"
  fi
fi
