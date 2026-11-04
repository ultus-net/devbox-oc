#!/usr/bin/env bash
# os/butane/tests/test_units_have_scripts.sh
#
# Every ExecStart that names one of our scripts must resolve to a file the
# Ignition config installs. A unit pointing at a path that is not shipped fails
# at boot, and a source-level check catches it without a container engine.
#
# With an artifact argument and Butane available, this also rebuilds the
# placeholder Ignition and requires it to be byte-identical. A committed artifact
# that no longer matches its source is a boot config nobody reviewed.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
bu="${1:-$here/../ucore.bu}"
artifact="${2:-}"
fail() { echo "FAIL: $1" >&2; exit 1; }

[ -f "$bu" ] || fail "no such file: $bu"
command -v python3 >/dev/null 2>&1 || fail "python3 is required and absent"
python3 -c 'import yaml' >/dev/null 2>&1 || fail "python3 has no PyYAML module"

python3 - "$bu" <<'PY'
import os
import sys

import yaml

path = sys.argv[1]
with open(path) as handle:
    config = yaml.safe_load(handle)

files = {
    entry.get("path")
    for entry in (config.get("storage") or {}).get("files") or []
}
inline = {
    (entry.get("path") or "").rsplit("/", 1)[-1]
    for entry in (config.get("storage") or {}).get("files") or []
    if (entry.get("contents") or {}).get("inline")
}

# Binaries the OS image ships are not ours to inspect.
SHIPPED = {"/usr/bin/rpm-ostree", "/usr/bin/systemctl", "/usr/bin/touch"}

units = (config.get("systemd") or {}).get("units") or []
if not units:
    raise SystemExit("FAIL: the config declares no systemd units")

missing = []
checked = 0
for unit in units:
    for line in (unit.get("contents") or "").splitlines():
        if not line.startswith("ExecStart="):
            continue
        exec_path = line.split("=", 1)[1].split()[0]
        if exec_path in SHIPPED:
            continue
        checked += 1
        if exec_path.startswith("/usr/local/sbin/") and exec_path not in files:
            missing.append(f"{unit.get('name')}: {exec_path}")
        elif exec_path.rsplit("/", 1)[-1] not in inline and exec_path not in files:
            missing.append(f"{unit.get('name')}: {exec_path}")

if checked == 0:
    raise SystemExit("FAIL: no ExecStart lines were checked")
if missing:
    raise SystemExit("FAIL: units run scripts the config does not install:\n"
                     + "\n".join(missing))
print(f"every ExecStart resolves ({checked} checked)")
PY

if [ -n "$artifact" ]; then
  [ -f "$artifact" ] || fail "no such artifact: $artifact"
  if [ -z "${BUTANE:-}" ]; then
    echo "SKIP: BUTANE is not set, so artifact reproducibility is unchecked"
    exit 0
  fi
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  BUTANE="$BUTANE" "$here/../build-placeholder.sh" "$tmp/ucore.ign" >/dev/null \
    || fail "the placeholder build failed"
  cmp -s "$tmp/ucore.ign" "$artifact" \
    || fail "$artifact does not reproduce from ucore.bu; rebuild it with os/butane/build-placeholder.sh"
  echo "the committed artifact reproduces from its source"
fi
