#!/usr/bin/env bash
# image/tests/test_healthcheck.sh
#
# The health command decides whether podman auto-update keeps a new image, so its
# answer is checked here without a container engine: a stub curl stands in for
# the server, and each status must land on the documented side.
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
script="$here/healthcheck.sh"
fail() { echo "FAIL: $1" >&2; exit 1; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"

# The stub prints FAKE_CODE and records the arguments curl was called with.
cat > "$tmp/bin/curl" <<'EOF'
#!/bin/sh
if [ -n "${FAKE_ARGS:-}" ]; then printf '%s\n' "$*" >> "$FAKE_ARGS"; fi
printf '%s' "${FAKE_CODE:-}"
EOF
chmod 0755 "$tmp/bin/curl"
export PATH="$tmp/bin:$PATH"

code_of() { FAKE_CODE="$1" sh "$script" >/dev/null 2>&1; }

# 401 is the documented healthy state: the API is up and asking for a password.
code_of 401 || fail "a 401 from the API must be healthy"
# 200 means the API answered and authentication is off. Still serving.
code_of 200 || fail "a 200 from the API must be healthy"

if code_of 000; then fail "a server that answers nothing must be unhealthy"; fi
if code_of 500; then fail "a 500 from the API must be unhealthy"; fi
if code_of 302; then fail "a redirect must be unhealthy"; fi

# An empty status is what a refused connection leaves behind.
if FAKE_CODE='' sh "$script" >/dev/null 2>&1; then
  fail "an empty status must be unhealthy"
fi

# The probe must be the URL the quadlet's container serves: the API, on the
# server's own loopback and port. The HTML shell on / would pass on a server
# whose API is broken, and another port would never be the one in production.
FAKE_ARGS="$tmp/args" FAKE_CODE=401 sh "$script" >/dev/null 2>&1 \
  || fail "the 401 probe failed"
grep -Fq 'http://127.0.0.1:4096/api/info' "$tmp/args" \
  || fail "the health check does not probe http://127.0.0.1:4096/api/info"

echo "health command accepts a serving API and rejects everything else"
