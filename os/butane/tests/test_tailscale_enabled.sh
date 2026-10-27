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

# tailscaled is a shipped unit, not one we write. Enabling it needs a unit
# entry with no contents block, or the contents would shadow the real unit.
#
# The block is taken by line number, not an awk range: the range end pattern
# `^    - name: ` matches the start line itself, so a range collapses to one line
# and the enabled check reads it as absent.
start="$(grep -n -- '- name: tailscaled.service' "$bu" | head -1 | cut -d: -f1 || true)"
[ -n "$start" ] || fail "tailscaled.service is not enabled in the Ignition config"
block="$(tail -n "+$start" "$bu" | awk 'NR > 1 && /^    - name: /{exit} {print}')"
[ -n "$block" ] || fail "tailscaled.service block is empty"
printf '%s\n' "$block" | grep -Eq '^[[:space:]]+enabled: true[[:space:]]*$' \
  || fail "tailscaled.service is present but not enabled"
if printf '%s\n' "$block" | grep -q 'contents:'; then
  fail "tailscaled.service has a contents block, which would shadow the shipped unit"
fi

# Ordering, not just presence. tailscale up contacts the coordination server, so
# it needs a socket that is already listening.
#
# Both patterns are anchored to the directive, not the bare word. An unanchored
# grep is satisfied by a commented-out `#After=...` line, which would report
# success while the unit still starts before the daemon.
nstart="$(grep -n -- '- name: oc-tailnet.service' "$bu" | head -1 | cut -d: -f1 || true)"
[ -n "$nstart" ] || fail "oc-tailnet.service not found in $bu"
net="$(tail -n "+$nstart" "$bu" | awk 'NR > 1 && /^    - name: /{exit} {print}')"
printf '%s\n' "$net" | grep -Eq '^[[:space:]]*After=.*tailscaled\.service' \
  || fail "oc-tailnet.service does not start after tailscaled.service"
printf '%s\n' "$net" \
  | grep -Eq '^[[:space:]]*(Requires|Wants)=.*tailscaled\.service' \
  || fail "oc-tailnet.service does not want or require tailscaled.service"

echo "tailscaled is enabled and orders the tailnet join"
