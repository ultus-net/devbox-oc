#!/usr/bin/env bash
# os/butane/tests/test_data_mount.sh
#
# On Fedora CoreOS and ucore, /srv is a symlink to var/srv, and systemd refuses
# to mount on a path that contains a symlink ("Mount path /srv is not
# canonical"). A mount unit named srv.mount with Where=/srv therefore fails on
# every boot, /srv stays a plain directory on the OS disk, and the data-disk
# invariant is silently broken.
#
# This reads the Ignition source and requires one mount unit whose name matches
# its canonical Where= path under /var, and requires every dependent unit to use
# that name. Pass a different .bu path to check a mutation.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
bu="${1:-$here/../ucore.bu}"
fail() { echo "FAIL: $1" >&2; exit 1; }

[ -f "$bu" ] || fail "no such file: $bu"
command -v python3 >/dev/null 2>&1 || fail "python3 is required and absent"
python3 -c 'import yaml' >/dev/null 2>&1 || fail "python3 has no PyYAML module"

python3 - "$bu" <<'PY'
import re
import sys

import yaml

with open(sys.argv[1]) as handle:
    config = yaml.safe_load(handle)

units = (config.get("systemd") or {}).get("units") or []
mounts = [u for u in units if str(u.get("name", "")).endswith(".mount")]
if len(mounts) != 1:
    raise SystemExit(f"FAIL: expected exactly one mount unit, found {len(mounts)}")

mount = mounts[0]
name = mount["name"]
contents = mount.get("contents") or ""
match = re.search(r"^Where=(.+)$", contents, re.M)
if not match:
    raise SystemExit(f"FAIL: {name} has no Where=")
where = match.group(1).strip()

if where == "/srv":
    raise SystemExit(
        "FAIL: Where=/srv cannot mount: /srv is a symlink to var/srv on Fedora "
        "CoreOS, and systemd rejects a non-canonical mount path")

expected_name = where.strip("/").replace("/", "-") + ".mount"
if name != expected_name:
    raise SystemExit(
        f"FAIL: unit name {name} does not match Where={where}; expected {expected_name}")

if "What=/dev/disk/by-label/data" not in contents:
    raise SystemExit(f"FAIL: {name} does not mount the data filesystem by label")

if not mount.get("enabled"):
    raise SystemExit(f"FAIL: {name} is not enabled")

# A rule is only as wide as its reader. The mount name can reappear in a unit's
# drop-in or in a storage.files entry (for example a drop-in written by path),
# so walk every scalar document the config carries, not just units[].contents.
documents = []
for unit in units:
    label = unit.get("name") or "unnamed unit"
    documents.append((label, unit.get("contents") or ""))
    for dropin in unit.get("dropins") or []:
        documents.append((f"{label} drop-in {dropin.get('name')}", dropin.get("contents") or ""))

for entry in (config.get("storage") or {}).get("files") or []:
    body = entry.get("contents") or ""
    if isinstance(body, dict):
        body = body.get("inline") or body.get("source") or ""
    documents.append((entry.get("path") or "unnamed file", str(body)))

dependents = 0
for label, body in documents:
    if re.search(r"(?<![\w-])srv\.mount", body):
        raise SystemExit(
            f"FAIL: {label} still depends on srv.mount, which never mounts")
    if re.search(r"^\s*Where=/srv\s*$", body, re.M):
        raise SystemExit(
            f"FAIL: {label} mounts at /srv, which is a symlink on Fedora CoreOS")

for unit in units:
    body = (unit.get("contents") or "") + "".join(
        d.get("contents") or "" for d in unit.get("dropins") or [])
    if re.search(rf"(After|Requires|Wants|WantedBy)=.*{re.escape(name)}", body):
        dependents += 1

if dependents == 0:
    raise SystemExit(f"FAIL: no unit depends on {name}")

print(f"data disk mounts at {where} via {name} ({dependents} dependents)")
PY

# Teeth: a drop-in that reintroduces srv.mount must fail. Without this, a check
# that only reads units[].contents would pass the shipped file and miss the
# regression exactly where it comes back.
if [ "$#" -eq 0 ]; then
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  python3 - "$bu" "$tmp/mutated.bu" <<'PY'
import sys

import yaml

with open(sys.argv[1]) as handle:
    config = yaml.safe_load(handle)
units = config["systemd"]["units"]
units[0].setdefault("dropins", []).append(
    {"name": "10-legacy.conf", "contents": "[Unit]\nAfter=srv.mount\n"})
with open(sys.argv[2], "w") as handle:
    yaml.safe_dump(config, handle, sort_keys=False)
PY
  cmp -s "$bu" "$tmp/mutated.bu" && fail "mutation did not land"
  if "$0" "$tmp/mutated.bu" >/dev/null 2>&1; then
    fail "the guard accepted a drop-in that reintroduces srv.mount"
  fi
fi
