#!/usr/bin/env bash
# host/tests/test_hermes_quadlet.sh
#
# The Hermes control plane is the one non-Fedora container in the repo. That
# waiver is scoped: the container still has to keep every other invariant the
# OpenCode quadlet keeps. This asserts the Hermes quadlet and the shared network
# definition carry the same persistence, loopback and fail-closed properties.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
q="$root/host/quadlet/hermes.container"
net="$root/host/quadlet/devbox.network"
oc="$root/host/quadlet/opencode.container"
bu="$root/os/butane/ucore.bu"
fail() { echo "FAIL: $1" >&2; exit 1; }

[ -f "$q" ] || fail "hermes quadlet missing"
[ -f "$net" ] || fail "shared network definition missing"

# podman's generator reads these from /etc/containers/systemd/, and they are not
# executable, so 0644 is the mode the sources have to carry.
[ "$(stat -c '%a' "$q")" = "644" ] || fail "hermes quadlet is not mode 0644"
[ "$(stat -c '%a' "$net")" = "644" ] || fail "network definition is not mode 0644"

# A named volume would land on the OS disk and be lost on reinstall.
if grep -Eq '^Volume=[a-z0-9_-]+:/' "$q"; then
  fail "hermes uses a named volume; it would live on the OS disk"
fi

# Persisted state stays on the data disk. The one other mount allowed is the
# health script: a single file installed by Ignition, mounted read-only at the
# same path inside the container so the HealthCmd can run it.
health_bin="$(sed -n 's/^HealthCmd=//p' "$q")"
[ -n "$health_bin" ] || fail "hermes quadlet declares no HealthCmd"
while read -r line; do
  spec="${line#Volume=}"
  src="$(printf '%s' "$spec" | cut -d: -f1)"
  dst="$(printf '%s' "$spec" | cut -d: -f2)"
  opts="$(printf '%s' "$spec" | cut -d: -f3)"
  case "$src" in
    /srv/*) [ "$dst" = "/opt/data" ] || fail "hermes state mounts at $dst, not /opt/data" ;;
    "$health_bin")
      [ "$src" = "$dst" ] || fail "the health script mounts at $dst, not $src"
      case ",$opts," in
        *,ro,*) ;;
        *) fail "the health script mount is writable" ;;
      esac
      ;;
    *) fail "hermes volume outside the data disk: $src" ;;
  esac
done < <(grep -E '^Volume=' "$q")

# The agent's state database lives under /opt/data in the official image, so the
# bind mount has to land exactly there.
grep -q '^Volume=/srv/hermes/data:/opt/data' "$q" \
  || fail "hermes state is not persisted to /srv/hermes/data"

# Fail closed on a missing environment file, the same way OpenCode does.
unit_section="$(awk '/^\[Unit\]/{on=1;next} /^\[/{on=0} on' "$q")"
[ -n "$unit_section" ] || fail "hermes quadlet has no [Unit] section"
printf '%s\n' "$unit_section" | grep -Eq '^Requires=.*hermes-env\.service' \
  || fail "hermes quadlet does not require hermes-env.service in its [Unit] section"

container_section="$(awk '/^\[Container\]/{on=1;next} /^\[/{on=0} on' "$q")"
[ -n "$container_section" ] || fail "hermes quadlet has no [Container] section"
mapfile -t env_paths < <(printf '%s\n' "$container_section" | sed -n 's/^EnvironmentFile=//p')
[ "${#env_paths[@]}" -eq 1 ] \
  || fail "hermes quadlet must load exactly one EnvironmentFile, found ${#env_paths[@]}"
[ "${env_paths[0]}" = "/etc/hermes/env" ] \
  || fail "hermes quadlet loads ${env_paths[0]}, but hermes-env writes /etc/hermes/env"

# Every published port is loopback only. A bare 8642 binds every interface.
if grep -E '^PublishPort=' "$q" | grep -vq '^PublishPort=127\.0\.0\.1:'; then
  fail "a hermes port is not bound to loopback"
fi
grep -q '^PublishPort=127\.0\.0\.1:8642:8642$' "$q" || fail "gateway port is not published"
grep -q '^PublishPort=127\.0\.0\.1:9119:9119$' "$q" || fail "dashboard port is not published"

# The shared network is what gives name resolution to the OpenCode server.
grep -q '^Network=devbox\.network$' "$q" || fail "hermes does not join devbox.network"
grep -q '^Network=devbox\.network$' "$oc" || fail "opencode does not join devbox.network"
grep -q '^NetworkName=devbox$' "$net" || fail "network name is not devbox"

# No secret may be baked into a shipped file. It arrives through the written env
# file at boot from /etc/devbox/secrets.env.
if grep -q 'API_SERVER_KEY\|OPENROUTER_API_KEY' "$q"; then
  fail "the hermes quadlet sets a secret instead of loading the written env file"
fi

# The image is a build-time substitution, and the official image is the waiver.
grep -q '^Image=__HERMES_IMAGE__$' "$q" \
  || fail "the hermes image is not the build-substituted placeholder"

# The interactive CLI exits under a service manager, so the long-running gateway
# subcommand has to be the exec line.
grep -q '^Exec=gateway run$' "$q" || fail "hermes does not run the gateway server"

install_section="$(awk '/^\[Install\]/{on=1;next} /^\[/{on=0} on' "$q")"
[ -n "$install_section" ] || fail "hermes quadlet has no [Install] section"
printf '%s\n' "$install_section" | grep -Eq '^WantedBy=default\.target$' \
  || fail "hermes quadlet is not wanted by default.target, so it will not start at boot"

# The backup has to stop both SQLite stores and start both again afterwards.
python3 - "$bu" <<'PY'
import sys
import yaml

cfg = yaml.safe_load(open(sys.argv[1]))
units = (cfg.get("systemd") or {}).get("units") or []
backup = [u for u in units if u.get("name") == "oc-backup.service"]
if not backup:
    raise SystemExit("FAIL: oc-backup.service is not declared")
body = backup[0].get("contents") or ""
for needle in (
    "ExecStartPre=-/usr/bin/systemctl stop hermes.service",
    "ExecStartPre=-/usr/bin/systemctl stop opencode.service",
    "ExecStopPost=-/usr/bin/systemctl start opencode.service",
    "ExecStopPost=-/usr/bin/systemctl start hermes.service",
):
    if needle not in body:
        raise SystemExit(f"FAIL: oc-backup.service is missing: {needle}")
print("backup stops and restarts both workloads")
PY

echo "hermes persists on the data disk, fails closed and stays on loopback"
