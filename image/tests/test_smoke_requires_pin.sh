#!/usr/bin/env bash
# image/tests/test_smoke_requires_pin.sh
#
# The smoke gate decides which served version passes, so a missing pin must fail
# before any container engine is touched. An unset variable used to mean "accept
# any version", which is the defect the pin exists to close.
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
smoke="$here/smoke.sh"
fail() { echo "FAIL: $1" >&2; exit 1; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# A stub engine that would succeed proves no container call happens first.
cat > "$tmp/podman" <<'EOF'
#!/bin/sh
echo "engine was called without a pin" >&2
exit 0
EOF
chmod 0755 "$tmp/podman"

# Unset the variable explicitly, so a developer's exported pin cannot hide it.
if env -u SMOKE_OC_VERSION PATH="$tmp:$PATH" ENGINE=podman bash "$smoke" devbox:test \
  >"$tmp/out" 2>"$tmp/err"; then
  fail "smoke.sh passed with no SMOKE_OC_VERSION"
fi
if grep -q 'engine was called' "$tmp/err"; then
  fail "the engine ran before the pin was checked"
fi
grep -q 'SMOKE_OC_VERSION' "$tmp/err" || fail "no diagnostic for the missing pin"

echo "smoke gate refuses to run without a version pin"
