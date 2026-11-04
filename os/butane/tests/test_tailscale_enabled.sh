#!/usr/bin/env bash
# os/butane/tests/test_tailscale_enabled.sh
#
# ucore ships the tailscale RPM and vendors its repo disabled, but enables no
# service. The first boot is Fedora CoreOS, where `enabled: true` on a unit that
# does not exist yet does not produce a usable symlink. So the config writes the
# wants symlink directly, and it takes effect after the rebase.
#
# The guard reads the source with a YAML parser rather than matching indents, so
# a comment or a quoted scalar cannot satisfy it.
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

links = (config.get("storage") or {}).get("links") or []
want_path = "/etc/systemd/system/multi-user.target.wants/tailscaled.service"
want_target = "/usr/lib/systemd/system/tailscaled.service"
matches = [link for link in links if link.get("path") == want_path]
if not matches:
    raise SystemExit(f"FAIL: no wants symlink at {want_path}")
if matches[0].get("target") != want_target:
    raise SystemExit(
        f"FAIL: the tailscaled link points at {matches[0].get('target')}, "
        f"not {want_target}"
    )
if matches[0].get("hard") is True:
    raise SystemExit("FAIL: the tailscaled wants entry must be a symlink, not hard")

units = (config.get("systemd") or {}).get("units") or []
shadow = [u for u in units if u.get("name") == "tailscaled.service" and u.get("contents")]
if shadow:
    raise SystemExit(
        "FAIL: tailscaled.service has a contents block, which would shadow the shipped unit"
    )

join = [u for u in units if u.get("name") == "oc-tailnet.service"]
if not join:
    raise SystemExit("FAIL: oc-tailnet.service not found")
body = join[0].get("contents") or ""
unit_section = ""
for line in body.splitlines():
    if line.strip().startswith("["):
        unit_section = line.strip().strip("[]")
        continue
    if unit_section != "Unit":
        continue
    if line.startswith("After=") and "tailscaled.service" in line:
        break
else:
    raise SystemExit("FAIL: oc-tailnet.service does not start after tailscaled.service")

if not any(
    line.startswith(("Wants=", "Requires=")) and "tailscaled.service" in line
    for line in body.splitlines()
):
    raise SystemExit(
        "FAIL: oc-tailnet.service does not want or require tailscaled.service"
    )
PY

echo "tailscaled is enabled by link and orders the tailnet join"
