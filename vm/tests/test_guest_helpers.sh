#!/usr/bin/env bash
# vm/tests/test_guest_helpers.sh
#
# guest-check.sh reports a failure by calling one of its own helpers. An
# undefined helper is not a failure in that script: with no `set -e`, the shell
# prints "command not found" and moves on, so the assertion silently disappears
# and the VM reports a pass. This test fails when a helper is called but never
# defined, and it proves the check catches the defect by running it against a
# copy with one definition deleted.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
vm="$(cd "$here/.." && pwd)"
script="${1:-$vm/guest-check.sh}"
fail() { echo "FAIL: $1" >&2; exit 1; }

[ -s "$script" ] || fail "no guest check script at $script"

defined="$(grep -oE '^[[:space:]]*[a-z_]+\(\)' "$script" \
  | sed -E 's/^[[:space:]]*//; s/\(\)$//' | LC_ALL=C sort -u)"
# A call is a helper name followed by whitespace and its first argument, which
# may be quoted or bare. That skips definitions ("say() {") and path segments
# ("/var/lib/devbox-vm/checked").
used="$(grep -oE '\b(check[a-z_]*|pass|skip|info|fail|say)[[:space:]]+[^[:space:]]' "$script" \
  | sed -E 's/[[:space:]].*$//' | LC_ALL=C sort -u)"
undefined="$(comm -23 <(printf '%s\n' "$used") <(printf '%s\n' "$defined"))"

if [ -n "$undefined" ]; then
  fail "guest check calls undefined helpers: $(echo "$undefined" | tr '\n' ' ')"
fi

# Self-check: the guard above must fail on a script that lost a definition.
if [ "$#" -eq 0 ]; then
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  mutated="$tmp/guest-check.sh"
  awk '
    /^[[:space:]]*check_absent\(\) \{/ { skip = 1; next }
    skip && /^\}[[:space:]]*$/ { skip = 0; next }
    !skip
  ' "$script" > "$mutated"
  cmp -s "$script" "$mutated" && fail "mutation did not land: check_absent is not defined"
  if "$0" "$mutated" >/dev/null 2>&1; then
    fail "mutation survived: an undefined check_absent was accepted"
  fi
fi

echo "guest check defines every helper it calls"
