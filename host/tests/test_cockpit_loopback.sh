#!/usr/bin/env bash
# host/tests/test_cockpit_loopback.sh
#
# ucore-minimal ships Cockpit and switches firewalld to the server profile so it
# is reachable. Its cockpit.socket listens on 9090 across every interface, and
# the service behind it runs privileged with / mounted. This box's design has one
# door, so Cockpit must listen on loopback only and be published over the tailnet
# the same way OpenCode already is.
#
# Assertions, because there is more than one way to get this wrong:
#   1. a drop-in rebinds the shipped socket to loopback, rather than leaving 9090
#      open on every interface
#   2. the drop-in belongs to cockpit.socket, and it resets the listen list before
#      adding the loopback listener (a second ListenStream without a reset
#      appends, so 9090 stays open beside it)
#   3. the tailnet publisher serves that loopback port, on a port that does not
#      collide with the one OpenCode already holds
#
# Configuration is read with the YAML parser the other suites use, so a comment
# mentioning 9090 is not a definition.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
bu="$root/os/butane/ucore.bu"
tailnet="$root/host/bin/oc-tailnet"

fail() { echo "FAIL: $1" >&2; exit 1; }

[ -f "$bu" ] || fail "no Butane source at $bu"
[ -f "$tailnet" ] || fail "no oc-tailnet at $tailnet"
command -v python3 >/dev/null 2>&1 || fail "python3 is required and absent"
python3 -c 'import yaml' >/dev/null 2>&1 || fail "python3 has no PyYAML module"

# Print the drop-ins attached to one unit, each body verbatim, separated by a line
# of ===. A tab-separated record cannot carry a multi-line body: awk reads only the
# first line of the record and the rest looks like a different field.
dropins_of() {
  python3 - "$bu" "$1" <<'PY'
import sys, yaml
cfg = yaml.safe_load(open(sys.argv[1]))
want = sys.argv[2]
for unit in (cfg.get("systemd") or {}).get("units") or []:
    if (unit.get("name") or "") != want:
        continue
    for drop in unit.get("dropins") or []:
        print(drop.get("contents") or "")
        print("===")
PY
}

# Any drop-in anywhere that sets ListenStream, with its owning unit, so a drop-in
# attached to the wrong unit can be named.
listen_stream_dropins() {
  python3 - "$bu" <<'PY'
import sys, yaml
cfg = yaml.safe_load(open(sys.argv[1]))
for unit in (cfg.get("systemd") or {}).get("units") or []:
    name = unit.get("name") or ""
    for drop in unit.get("dropins") or []:
        body = drop.get("contents") or ""
        if "ListenStream" in body:
            print(f"{name}/{drop.get('name')}")
PY
}

# T1/T2: a drop-in on cockpit.socket that rebinds the socket to loopback.
dropins="$(dropins_of cockpit.socket)"
[ -n "$dropins" ] \
  || fail "no cockpit.socket drop-in: the shipped socket listens on 9090 on every interface, so Cockpit is reachable from the VNet and the tailnet"

printf '%s\n' "$dropins" | grep -Eq '^[[:space:]]*ListenStream=[[:space:]]*$' \
  || fail "the cockpit.socket drop-in does not reset ListenStream, so the shipped 9090 listener stays open:
$dropins"

printf '%s\n' "$dropins" | grep -Eq '^[[:space:]]*ListenStream=(127\.0\.0\.1|\[::1\]):9090[[:space:]]*$' \
  || fail "the cockpit.socket drop-in does not add a loopback listener for 9090:
$dropins"

# The reset must come first. systemd resets a list option when the empty string is
# assigned, so without it the loopback address is appended and 9090 stays open.
reset_line="$(printf '%s\n' "$dropins" | grep -nE '^[[:space:]]*ListenStream=[[:space:]]*$' | head -1 | cut -d: -f1)"
loop_line="$(printf '%s\n' "$dropins" | grep -nE '^[[:space:]]*ListenStream=(127\.0\.0\.1|\[::1\]):9090[[:space:]]*$' | head -1 | cut -d: -f1)"
[ "$reset_line" -lt "$loop_line" ] \
  || fail "the loopback ListenStream appears before the reset, so systemd appends it and 9090 stays open"

# T3: the drop-in must be attached to cockpit.socket. systemd ignores a drop-in
# for a unit that does not exist, and cockpit.service is a different unit.
wrong_unit="$(listen_stream_dropins | grep -v '^cockpit\.socket/' || true)"
[ -z "$wrong_unit" ] \
  || fail "a ListenStream drop-in is attached to a unit other than cockpit.socket, so it never applies:
$wrong_unit"

# T4: read the defaults the publisher actually uses. Parsing them keeps the test
# honest when a port moves; matching literals would pass on a stale copy.
default_of() {
  # Both assignment forms are equivalent in bash; the repo uses `:=`.
  grep -oE ": \"\\\$\{$1:[-=][0-9]+\}\"" "$tailnet" | grep -oE '[0-9]+' | head -1
}
oc_https="$(default_of OC_HTTPS_PORT)"
cockpit_https="$(default_of COCKPIT_HTTPS_PORT)"
cockpit_tcp="$(default_of COCKPIT_TCP_PORT)"
[ -n "$cockpit_https" ] || fail "oc-tailnet does not default COCKPIT_HTTPS_PORT"
[ -n "$cockpit_tcp" ] || fail "oc-tailnet does not default COCKPIT_TCP_PORT"
[ -n "$oc_https" ] || fail "oc-tailnet does not default OC_HTTPS_PORT"

# The proxied port must be the one the socket binds, or the publish succeeds
# against a port nothing listens on and Cockpit stays unreachable.
[ "$cockpit_tcp" = "9090" ] \
  || fail "COCKPIT_TCP_PORT defaults to $cockpit_tcp, but the socket listens on 9090"

# T5: the serve target must be loopback. tailscale serve proxies only to
# 127.0.0.1, so any other target cannot work.
grep -Eq 'tailscale serve --bg --https="\$\{COCKPIT_HTTPS_PORT\}" "http://127\.0\.0\.1:\$\{COCKPIT_TCP_PORT\}"' "$tailnet" \
  || fail "oc-tailnet does not publish Cockpit over the tailnet on its loopback port:
$(grep -n 'tailscale serve' "$tailnet" || echo '(no tailscale serve line)')"

# T6: the two HTTPS listeners must not collide. tailscale serve refuses a second
# bind on one port, so a collision leaves Cockpit unpublished while the unit still
# reports success for OpenCode.
[ "$oc_https" != "$cockpit_https" ] \
  || fail "OpenCode and Cockpit both bind --https=$cockpit_https, so tailscale serve cannot publish both"

echo "cockpit listens on loopback and is published over the tailnet only"
