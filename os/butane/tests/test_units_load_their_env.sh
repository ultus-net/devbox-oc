#!/usr/bin/env bash
# os/butane/tests/test_units_load_their_env.sh
#
# A systemd unit does not inherit another unit's EnvironmentFile. So a script that
# needs VAULT_NAME or TS_AUTHKEY_SECRET must have the env file that defines them
# loaded by its own unit, or it runs with those variables unset.
#
# That is exactly how the tailnet join broke: the Terraform secret existed, the
# script read the right name, and the unit never loaded the file that says which
# vault to ask.
#
# Every check here is derived from the config and the scripts, not from a list of
# expected values, so it keeps working when a unit is added.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
bu="${1:-$here/../ucore.bu}"
# Three levels up: os/butane/tests -> repo root -> host/bin.
bindir="${2:-$here/../../../host/bin}"
fail() { echo "FAIL: $1" >&2; exit 1; }

[ -f "$bu" ] || fail "no such file: $bu"
# Without this the script reads nothing, every unit looks satisfied, and the check
# passes vacuously. Fail loudly instead.
[ -d "$bindir" ] || fail "no such directory: $bindir"
[ -f "$bindir/oc-tailnet-up" ] || fail "bindir does not hold the host scripts: $bindir"
command -v python3 >/dev/null 2>&1 || fail "python3 is required and absent"
python3 -c 'import yaml' >/dev/null 2>&1 || fail "python3 has no PyYAML module"

python3 - "$bu" "$bindir" <<'PY'
import re
import sys

import yaml

bu_path, bindir = sys.argv[1], sys.argv[2]

with open(bu_path) as handle:
    config = yaml.safe_load(handle)

# Map each env file the config creates to the variable names it defines. A line
# like `VAULT_NAME=__VAULT_NAME__` defines VAULT_NAME; a comment does not.
env_files = {}
for entry in (config.get("storage") or {}).get("files") or []:
    path = entry.get("path") or ""
    if not path.endswith(".env"):
        continue
    names = set()
    inline = (entry.get("contents") or {}).get("inline") or ""
    for line in inline.splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        names.add(line.split("=", 1)[0].strip())
    env_files[path] = names

units = (config.get("systemd") or {}).get("units") or []

def script_vars(exec_path):
    """Variables a script references, following its lib-imds.sh include."""
    base = exec_path.rsplit("/", 1)[-1]
    sources = [f"{bindir}/{base}", f"{bindir}/lib-imds.sh"]
    seen = set()
    for source in sources:
        try:
            with open(source) as handle:
                text = handle.read()
        except OSError:
            continue
        seen |= set(re.findall(r"\$\{([A-Z_][A-Z0-9_]*)", text))
        seen |= set(re.findall(r"\$([A-Z_][A-Z0-9_]*)", text))
    return seen

failures = []
for unit in units:
    contents = unit.get("contents") or ""
    if not contents:
        continue
    name = unit.get("name", "<unnamed>")
    loaded = set(
        line.split("=", 1)[1].strip()
        for line in contents.splitlines()
        if line.startswith("EnvironmentFile=")
    )
    execs = [
        line.split("=", 1)[1].split()[0]
        for line in contents.splitlines()
        if line.startswith("ExecStart=") and len(line.split("=", 1)) == 2
    ]
    needed = set()
    for exec_path in execs:
        needed |= script_vars(exec_path)
    if not needed:
        continue
    for env_path, names in env_files.items():
        if env_path in loaded:
            continue
        missing = sorted(needed & names)
        if missing:
            failures.append(
                f"{name} runs a script needing {', '.join(missing)} "
                f"but does not load {env_path}"
            )

if failures:
    for failure in failures:
        print(f"FAIL: {failure}", file=sys.stderr)
    sys.exit(1)
PY

echo "every unit loads the env file its scripts need"
