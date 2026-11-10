#!/bin/sh
# image/healthcheck.sh - the container's podman health check.
#
# The API answers 401 without a password, which is the healthy state: the server
# is up and asking for credentials. The HTML shell on / is unauthenticated and
# proves nothing, so the check is the API. The runbook documents the same probe.
# 200 is accepted too: the API answered, but authentication is off, which this
# build never configures.
set -eu
url="${HEALTH_URL:-http://127.0.0.1:4096/api/info}"
code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$url" || true)"
case "$code" in
  401|200) exit 0 ;;
  *)
    echo "health check: $url answered ${code:-nothing}" >&2
    exit 1
    ;;
esac
