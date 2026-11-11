#!/bin/sh
# host/bin/hermes-health.sh - the Hermes container's podman health check.
#
# Probe the gateway API, not the binary: `hermes --version` answers even when the
# gateway serves nothing, and podman auto-update would keep that build. The API
# answers GET /health with 200 and a payload that names the platform, without
# credentials. /health/detailed needs the Bearer key, so the simple path is the
# probe. The quadlet mounts this script read-only at the same path inside the
# container, where the image ships curl.
set -eu
url="${HERMES_HEALTH_URL:-http://127.0.0.1:8642/health}"
# One request yields both the body and the status: curl appends the code after
# the body. The code is compared rather than left to curl -f, which accepts a
# 3xx, so a redirect that carried a healthy-looking body would pass.
resp="$(curl -sS --max-time 5 -w '\n%{http_code}' "$url" 2>/dev/null || true)"
code="$(printf '%s\n' "$resp" | sed -n '$p')"
body="$(printf '%s\n' "$resp" | sed '$d')"
if [ "$code" != "200" ]; then
  echo "health check: $url answered HTTP ${code:-nothing}" >&2
  exit 1
fi
case "$body" in
  *'"platform":"hermes-agent"'*|*'"platform": "hermes-agent"'*) exit 0 ;;
  *)
    echo "health check: $url answered ${body:-nothing}" >&2
    exit 1
    ;;
esac
