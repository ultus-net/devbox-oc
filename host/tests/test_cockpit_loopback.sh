#!/usr/bin/env bash
# host/tests/test_cockpit_loopback.sh
#
# ucore-minimal ships Cockpit and switches firewalld to the server profile so it
# is reachable. The shipped cockpit.socket listens on 9090 across every
# interface, and the service behind it runs privileged with / mounted. This box
# has one door, the tailnet, so the socket must be rebound to loopback and must
# not be published by oc-tailnet.
#
# Configuration is read with a YAML parser, so a comment mentioning 9090 is not a
# definition.
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

dropins="$(dropins_of cockpit.socket)"
[ -n "$dropins" ] \
  || fail "no cockpit.socket drop-in: the shipped socket listens on 9090 on every interface"

printf '%s\n' "$dropins" | grep -Eq '^[[:space:]]*ListenStream=[[:space:]]*$' \
  || fail "the cockpit.socket drop-in does not reset ListenStream, so the shipped 9090 listener stays open"

printf '%s\n' "$dropins" | grep -Eq '^[[:space:]]*ListenStream=(127\.0\.0\.1|\[::1\]):9090[[:space:]]*$' \
  || fail "the cockpit.socket drop-in does not add a loopback listener for 9090"

reset_line="$(printf '%s\n' "$dropins" | grep -nE '^[[:space:]]*ListenStream=[[:space:]]*$' | head -1 | cut -d: -f1)"
loop_line="$(printf '%s\n' "$dropins" | grep -nE '^[[:space:]]*ListenStream=(127\.0\.0\.1|\[::1\]):9090[[:space:]]*$' | head -1 | cut -d: -f1)"
[ "$reset_line" -lt "$loop_line" ] \
  || fail "the loopback ListenStream appears before the reset, so 9090 stays open"

wrong_unit="$(listen_stream_dropins | grep -v '^cockpit\.socket/' || true)"
[ -z "$wrong_unit" ] \
  || fail "a ListenStream drop-in is attached to a unit other than cockpit.socket:
$wrong_unit"

# The publisher serves the two workloads only. Publishing Cockpit as well would
# reopen a second door, and the design deliberately has one.
if grep -q 'COCKPIT' "$tailnet"; then
  fail "oc-tailnet still publishes Cockpit"
fi

grep -Eq 'tailscale serve --bg --https="\$\{OC_HTTPS_PORT\}" "http://127\.0\.0\.1:\$\{OC_TCP_PORT\}"' "$tailnet" \
  || fail "oc-tailnet does not publish OpenCode on its loopback port"
grep -Eq 'tailscale serve --bg --https="\$\{HERMES_DASH_HTTPS_PORT\}" "http://127\.0\.0\.1:\$\{HERMES_DASH_TCP_PORT\}"' "$tailnet" \
  || fail "oc-tailnet does not publish the Hermes dashboard on its loopback port"
grep -Eq 'tailscale serve --bg --https="\$\{HERMES_API_HTTPS_PORT\}" "http://127\.0\.0\.1:\$\{HERMES_API_TCP_PORT\}"' "$tailnet" \
  || fail "oc-tailnet does not publish the Hermes gateway on its loopback port"

# Funnel is the public counterpart of Serve. A funnel mount here would put the
# box on the internet, which is the one property the tailnet exists to keep.
if grep -Eq 'tailscale[[:space:]]+funnel' "$tailnet"; then
  fail "oc-tailnet enables Funnel, which would publish the box to the internet"
fi

# Every serve target must be one of the approved loopback ports. A mount such as
# Cockpit on 9090 would reopen the door the loopback drop-in closes. Read-only
# subcommands are not targets and are allowed. The approved set is the three
# surfaces this repo publishes; each one is checked to proxy 127.0.0.1 only.
serve_lines="$(sed 's/#.*//' "$tailnet" | grep -E 'tailscale[[:space:]]+serve' || true)"
target_lines="$(printf '%s\n' "$serve_lines" \
  | grep -vE 'tailscale[[:space:]]+serve[[:space:]]+(status|reset|drain|advertise|get-config|set-config)([[:space:]]|$)' \
  || true)"
approved='OC_TCP_PORT\|HERMES_DASH_TCP_PORT\|HERMES_API_TCP_PORT'
stray_serve="$(printf '%s\n' "$target_lines" | grep -v "$approved" || true)"
[ -z "$stray_serve" ] \
  || fail "oc-tailnet serves a target other than an approved loopback port:
$stray_serve"

non_loopback="$(printf '%s\n' "$target_lines" | grep -v 'http://127\.0\.0\.1:' || true)"
[ -z "$non_loopback" ] \
  || fail "oc-tailnet serves a target that is not loopback:
$non_loopback"

echo "cockpit listens on loopback only and is not published"
