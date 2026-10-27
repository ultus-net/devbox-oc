#!/usr/bin/env bash
# host/tests/test_quadlet_persistence.sh
set -euo pipefail
q="$(cd "$(dirname "$0")/../.." && pwd)/host/quadlet/opencode.container"
fail() { echo "FAIL: $1" >&2; exit 1; }
[ -f "$q" ] || fail "quadlet missing"

# podman's generator only reads /etc/containers/systemd/, and the file is not
# executable, so 0644 is the mode the source has to carry.
[ "$(stat -c '%a' "$q")" = "644" ] || fail "quadlet is not mode 0644"

# Named volumes are the specific mistake this guards against, so test them
# first: a named source never starts with /srv/, so the path scan below would
# otherwise be the check that fires and hide this diagnosis.
if grep -Eq '^Volume=[a-z0-9_-]+:/' "$q"; then
  fail "a named volume is used; it would live on the OS disk"
fi

# Every volume that maps a persistent path must be under /srv, i.e. the data disk.
# Read via process substitution, not a pipe: `fail` inside a pipeline runs in a
# subshell, so `exit 1` would not stop the script and the check would pass
# vacuously on the first offending line.
while read -r line; do
  src="$(printf '%s' "${line#Volume=}" | cut -d: -f1)"
  case "$src" in
    /srv/*) ;;
    *) fail "persistent volume outside the data disk: $src" ;;
  esac
done < <(grep -E '^Volume=' "$q")

# The session DB path specifically must be persisted.
grep -q '/home/dev/.local/share/opencode' "$q" || fail "session data is not persisted"

# `After=` only orders the units. If the secret bootstrap fails, the container
# would start with no OPENCODE_PASSWORD and no ACR auth, then serve nothing and
# never idle-stop. Requires= makes a failed bootstrap refuse to start the unit.
#
# The placement matters. podman's generator reads only [Unit] for dependencies, so
# a Requires= sitting in [Container] would satisfy a naive grep and do nothing.
unit_section="$(awk '/^\[Unit\]/{on=1;next} /^\[/{on=0} on' "$q")"
[ -n "$unit_section" ] || fail "quadlet has no [Unit] section"
printf '%s\n' "$unit_section" | grep -Eq '^Requires=.*oc-secrets\.service' \
  || fail "quadlet does not require oc-secrets.service in its [Unit] section"

# Every EnvironmentFile the quadlet names must be written by a component we ship.
# A reference to a file nothing produces is how the tailnet key went missing, and
# the failure surfaces at boot as a variable that is merely unset, not as a
# missing-file error.
while read -r path; do
  grep -rqF "$path" "$(dirname "$q")/../bin" "$(dirname "$q")/../../os/butane/ucore.bu" \
    || fail "no component writes the quadlet's EnvironmentFile: $path"
done < <(grep -E '^EnvironmentFile=' "$q" | cut -d= -f2)

# The container's password comes from that file, so the writer and the reader must
# agree on the name. oc-secrets writes it with printf rather than a literal line,
# so match the variable name in a write, not a line start.
grep -q "OPENCODE_PASSWORD=" "$(dirname "$q")/../bin/oc-secrets" \
  || fail "oc-secrets does not write OPENCODE_PASSWORD"
grep -q 'OPENCODE_PASSWORD' "$(dirname "$q")/../bin/oc-idle-check" \
  || fail "oc-idle-check does not read the password oc-secrets writes"

echo "persistent data is on the data disk"
