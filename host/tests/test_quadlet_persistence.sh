#!/usr/bin/env bash
# host/tests/test_quadlet_persistence.sh
set -euo pipefail
q="${1:-$(cd "$(dirname "$0")/../.." && pwd)/host/quadlet/opencode.container}"
fail() { echo "FAIL: $1" >&2; exit 1; }
[ -f "$q" ] || fail "quadlet missing"

# podman's generator only reads /etc/containers/systemd/, and the file is not
# executable, so 0644 is the mode the source has to carry.
[ "$(stat -c '%a' "$q")" = "644" ] || fail "quadlet is not mode 0644"

# Named volumes are the specific mistake this guards against, so test them first:
# a named source never starts with /srv/, so the path scan below would otherwise
# be the check that fires and hide this diagnosis.
if grep -Eq '^Volume=[a-z0-9_-]+:/' "$q"; then
  fail "a named volume is used; it would live on the OS disk"
fi

while read -r line; do
  src="$(printf '%s' "${line#Volume=}" | cut -d: -f1)"
  case "$src" in
    /srv/*) ;;
    *) fail "persistent volume outside the data disk: $src" ;;
  esac
done < <(grep -E '^Volume=' "$q")

# The session DB path specifically must be persisted.
grep -q '/home/dev/.local/share/opencode' "$q" || fail "session data is not persisted"

# `After=` only orders the units. If oc-env fails, the container would start with
# no OPENCODE_PASSWORD and serve nothing. Requires= makes a failed env write stop
# the workload.
unit_section="$(awk '/^\[Unit\]/{on=1;next} /^\[/{on=0} on' "$q")"
[ -n "$unit_section" ] || fail "quadlet has no [Unit] section"
printf '%s\n' "$unit_section" | grep -Eq '^Requires=.*oc-env\.service' \
  || fail "quadlet does not require oc-env.service in its [Unit] section"

# Read from [Container] only: the generator reads EnvironmentFile= there, and the
# same key in [Unit] is parsed by systemd and ignored for the container.
container_section="$(awk '/^\[Container\]/{on=1;next} /^\[/{on=0} on' "$q")"
[ -n "$container_section" ] || fail "quadlet has no [Container] section"
mapfile -t env_paths < <(printf '%s\n' "$container_section" | sed -n 's/^EnvironmentFile=//p')
[ "${#env_paths[@]}" -eq 1 ] \
  || fail "quadlet must load exactly one EnvironmentFile, found ${#env_paths[@]}"
[ "${env_paths[0]}" = "/etc/opencode/env" ] \
  || fail "quadlet loads ${env_paths[0]}, but oc-env writes /etc/opencode/env"

# The container publishes on loopback only. A bare 4096 binds every interface.
grep -Eq '^PublishPort=127\.0\.0\.1:4096:4096$' "$q" \
  || fail "the container port is not bound to loopback"

# No shipped file may define the password. The env file is written at boot from
# /etc/devbox/secrets.env, which is not in git.
if sed ':a;/\\$/N;s/\\\n//;ta' "$q" | grep -q 'OPENCODE_PASSWORD'; then
  fail "the quadlet sets OPENCODE_PASSWORD instead of loading the written env file"
fi

# The image is a build-time substitution, not a hardcoded registry.
grep -q '^Image=__IMAGE__$' "$q" \
  || fail "the quadlet image is not the build-substituted placeholder"

# The Azure registry is gone with the rest of the Azure design.
if grep -qi 'azurecr\|azure' "$q"; then
  fail "the quadlet still names an Azure registry"
fi

echo "persistent data is on the data disk and the workload fails closed"
