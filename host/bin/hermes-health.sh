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
body="$(curl -fsS --max-time 5 "$url" 2>/dev/null || true)"
case "$body" in
  *'"platform"'*'"hermes-agent"'*) exit 0 ;;
  *)
    echo "health check: $url answered ${body:-nothing}" >&2
    exit 1
    ;;
esac
