#!/usr/bin/env bash
# host/tests/test_quadlet_health.sh
#
# The quadlet health command decides whether podman auto-update keeps a new
# image, so it must probe the workload, not print a version. Both quadlets are
# checked here, and each is tied to how its script is installed: the OpenCode
# image copies it, and the Hermes host script is written by Ignition and mounted
# read-only into the container.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
dockerfile="$root/image/Dockerfile"
bu="$root/os/butane/ucore.bu"
fail() { echo "FAIL: $1" >&2; exit 1; }

[ -s "$dockerfile" ] || fail "no Dockerfile at $dockerfile"
[ -s "$bu" ] || fail "no Butane source at $bu"

# Prints the HealthCmd binary for one quadlet after the checks both share.
health_bin() {
  local quadlet="$1" label="$2" cmd bin
  [ -s "$quadlet" ] || fail "no $label quadlet at $quadlet"
  cmd="$(sed -n 's/^HealthCmd=//p' "$quadlet")"
  [ -n "$cmd" ] || fail "the $label quadlet declares no HealthCmd"
  bin="${cmd%% *}"

  # A version probe answers "is the binary there", not "is it serving". Checked
  # before the argument rule because `--version` needs an argument to appear.
  case "$cmd" in
    *--version*) fail "the $label health command only prints a version: $cmd" ;;
  esac

  # The health command must be exactly the installed path. A trailing shell
  # operator such as `|| true` would report healthy for any result, which is the
  # failure this guard exists to prevent.
  [ "$cmd" = "$bin" ] || fail "the $label health command carries extra arguments: $cmd"

  case "$bin" in
    /usr/local/bin/*) ;;
    *) fail "the $label health command is not an absolute path under /usr/local/bin: $bin" ;;
  esac
  printf '%s\n' "$bin"
}

oc_bin="$(health_bin "$root/host/quadlet/opencode.container" opencode)"
# The COPY must be a real instruction, install the executable bit, and come from
# the health script. A commented-out line or a 0644 install would leave the probe
# failing or absent. -F keeps the dots in /usr/local literal.
grep -qxF "COPY --chmod=0755 healthcheck.sh $oc_bin" "$dockerfile" \
  || fail "the image does not install $oc_bin as an executable from healthcheck.sh"

hermes_bin="$(health_bin "$root/host/quadlet/hermes.container" hermes)"
# The upstream image ships no health check, so the script arrives from the host:
# Ignition writes it at the path the command names, and the quadlet mounts that
# one file read-only at the same path inside the container.
python3 - "$bu" "$hermes_bin" <<'PY'
import os
import sys
import yaml

bu, binpath = sys.argv[1], sys.argv[2]
cfg = yaml.safe_load(open(bu))
files = (cfg.get("storage") or {}).get("files") or []
matches = [f for f in files if f.get("path") == binpath]
if len(matches) != 1:
    raise SystemExit(f"FAIL: {bu} does not install {binpath} exactly once")
entry = matches[0]
if int(str(entry.get("mode"))) != 0o755:
    raise SystemExit(f"FAIL: {binpath} is not mode 0755 in the Ignition source")
local = (entry.get("contents") or {}).get("local")
expected = "host/bin/" + os.path.basename(binpath)
if local != expected:
    raise SystemExit(f"FAIL: {binpath} comes from {local}, not {expected}")
PY
grep -qxF "Volume=$hermes_bin:$hermes_bin:ro,Z" "$root/host/quadlet/hermes.container" \
  || fail "the hermes quadlet does not mount $hermes_bin read-only at the same path"

echo "both quadlet health commands probe the API their image serves"
