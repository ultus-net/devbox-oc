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
# every interface by default. Read the drop-ins the way resolved does: apply
# them in filename order and keep the last value for each key under [Resolve], so
# a commented-out line or a later override cannot pass.
files = (config.get("storage") or {}).get("files") or []
dropins = sorted(
    (str(f.get("path")), str((f.get("contents") or {}).get("inline") or ""))
    for f in files
    if str(f.get("path") or "").startswith("/etc/systemd/resolved.conf.d/")
)
if not dropins:
    raise SystemExit(
        "FAIL: no resolved.conf.d drop-in disables LLMNR and mDNS, which answer "
        "on 5355 and 5353 on every interface")


def resolve_values(pairs):
    values = {}
    section = ""
    for _path, text in pairs:
        for raw in text.splitlines():
            line = raw.strip()
            if not line or line[0] in "#;":
                continue
            if line.startswith("[") and line.endswith("]"):
                section = line[1:-1].strip()
                continue
            if section != "Resolve" or "=" not in line:
                continue
            key, value = line.split("=", 1)
            values[key.strip()] = value.strip()
    return values


effective = resolve_values(dropins)
still_on = [key for key in ("LLMNR", "MulticastDNS") if effective.get(key) != "no"]
if still_on:
    raise SystemExit(
        "FAIL: the resolved drop-in does not switch off: " + ", ".join(still_on))

print(f"sshd is masked, {len(units)} units declare only loopback listeners, "
      "and LLMNR and mDNS are off")
PY

# Teeth: three mutations, each of which a substring check would accept. Each one
# must make the guard fail, or the guard is reading text rather than the
# effective configuration.
if [ "$#" -eq 0 ]; then
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT

  # 1. Remove the drop-in entirely.
  # 2. Comment out the switch-off, leaving the string in the file.
  # 3. Add a later drop-in that turns LLMNR back on.
  for mode in remove comment override; do
    python3 - "$bu" "$tmp/mutated.bu" "$mode" <<'PY'
import sys

import yaml

mode = sys.argv[3]
with open(sys.argv[1]) as handle:
    config = yaml.safe_load(handle)
files = config["storage"]["files"]


def is_resolved(entry):
    return str(entry.get("path") or "").startswith("/etc/systemd/resolved.conf.d/")


if mode == "remove":
    config["storage"]["files"] = [f for f in files if not is_resolved(f)]
elif mode == "comment":
    for f in (f for f in files if is_resolved(f)):
        inline = (f.get("contents") or {}).get("inline") or ""
        f["contents"]["inline"] = inline.replace("LLMNR=no", "# LLMNR=no")
elif mode == "override":
    files.append({
        "path": "/etc/systemd/resolved.conf.d/99-lan.conf",
        "mode": 0o644,
        "contents": {"inline": "[Resolve]\nLLMNR=yes\n"},
    })
else:
    raise SystemExit("unknown mutation: " + mode)

with open(sys.argv[2], "w") as handle:
    yaml.safe_dump(config, handle, sort_keys=False)
PY
    cmp -s "$bu" "$tmp/mutated.bu" && fail "mutation did not land: $mode"
    if "$0" "$tmp/mutated.bu" >/dev/null 2>&1; then
      fail "the guard accepted a config where LLMNR and mDNS are not switched off ($mode)"
    fi
  done
fi
