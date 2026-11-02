#!/usr/bin/env bash
# os/butane/tests/test_tailscale_enabled.sh
#
# ucore ships the tailscale RPM and vendors its repo disabled, but enables no
# service. Its services doc says added services are enabled deliberately. Without
# this block, tailscale up fails at boot and the box is unreachable except by
# Bastion.
#
# Source-level, not .ign-level: the .ign needs a container engine to compile, and
# a guard that skips on a machine without one protects nothing.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
bu="${1:-$here/../ucore.bu}"
fail() { echo "FAIL: $1" >&2; exit 1; }

[ -f "$bu" ] || fail "no such file: $bu"

# Take a unit's block by line number. An awk range whose end pattern matches the
# start line collapses to one line and reads as absent.
block_of() {
  local name="$1" start
  start="$(grep -n -- "- name: ${name}\$" "$bu" | head -1 | cut -d: -f1 || true)"
  [ -n "$start" ] || return 1
  tail -n "+$start" "$bu" | awk 'NR > 1 && /^    - name: /{exit} {print}'
}

# tailscaled is a shipped unit, not one we write. Enabling it needs a unit entry
# with no contents block, or the contents would shadow the real unit.
#
# The flag is read by the shared YAML helper rather than by matching an indent, so
# `enabled: yes`, `enabled: on`, and a trailing comment all count. This was the third
# copy of that derivation; keeping one copy is why the other two no longer disagree.
command -v python3 >/dev/null 2>&1 || fail "python3 is required and absent"
python3 -c 'import yaml' >/dev/null 2>&1 || fail "python3 has no PyYAML module"
block="$(block_of tailscaled.service)" \
  || fail "tailscaled.service is not enabled in the Ignition config"
[ "$(python3 "$here/unit_enabled.py" "$bu" tailscaled.service)" = "true" ] \
  || fail "tailscaled.service is present but not enabled"
if printf '%s\n' "$block" | grep -q 'contents:'; then
  fail "tailscaled.service has a contents block, which would shadow the shipped unit"
fi

# Ordering, not just presence. tailscale up contacts the coordination server, so
# it needs a socket that is already listening.
net="$(block_of oc-tailnet.service)" || fail "oc-tailnet.service not found in $bu"

# Checked inside [Unit], because systemd ignores After= anywhere else and warns
# `Unknown key 'After' in section [Service], ignoring`. A section-blind grep
# passes on a unit that carries no ordering at all.
unit_section="$(printf '%s\n' "$net" \
  | awk '/^[[:space:]]*\[Unit\]/{on=1;next} /^[[:space:]]*\[/{on=0} on')"
[ -n "$unit_section" ] || fail "oc-tailnet.service has no [Unit] section"

# Both patterns are anchored to the directive, so a commented line cannot satisfy
# them.
printf '%s\n' "$unit_section" | grep -Eq '^[[:space:]]*After=.*tailscaled\.service' \
  || fail "oc-tailnet.service does not start after tailscaled.service in [Unit]"
printf '%s\n' "$unit_section" \
  | grep -Eq '^[[:space:]]*(Requires|Wants)=.*tailscaled\.service' \
  || fail "oc-tailnet.service does not want or require tailscaled.service in [Unit]"

# `enabled: true` is enough because the image boots ucore, which ships
# tailscaled, so the unit exists on the first boot. The earlier design needed a
# rebase stage to enable it, because that first boot was plain FCOS with no
# tailscaled to enable. Both the stage and this workaround are gone.

echo "tailscaled is enabled and orders the tailnet join"
