#!/usr/bin/env bash
# host/tests/test_hermes_health.sh
#
# The Hermes health command decides whether podman auto-update keeps a new image,
# so it has to answer for the API, not for the binary. This runs the script
# against a real HTTP server on loopback: a 200 with the gateway payload is
# healthy, and a 401, a wrong body, or nothing listening is not.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
script="$here/../bin/hermes-health.sh"
fail() { echo "FAIL: $1" >&2; exit 1; }

[ -x "$script" ] || fail "host/bin/hermes-health.sh is not executable"

tmp="$(mktemp -d)"
pid=""
cleanup() {
  [ -z "$pid" ] || kill "$pid" 2>/dev/null || true
  rm -rf "$tmp"
}
trap cleanup EXIT

# Three routes: the healthy answer, a 401 that carries the same body (so a
# missing -f would pass), and a 200 with a body from some other server.
cat > "$tmp/server.py" <<'PY'
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

ROUTES = {
    "/health": (200, b'{"status": "ok", "platform": "hermes-agent"}'),
    "/health-unauthorized": (401, b'{"status": "ok", "platform": "hermes-agent"}'),
    "/health-wrong": (200, b'{"status": "ok"}'),
}


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        code, body = ROUTES.get(self.path, (404, b"not found"))
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


server = HTTPServer(("127.0.0.1", 0), Handler)
with open(sys.argv[1], "w", encoding="utf-8") as port_file:
    port_file.write(str(server.server_port))
server.serve_forever()
PY

python3 "$tmp/server.py" "$tmp/port" &
pid="$!"
for _ in $(seq 1 50); do
  [ -s "$tmp/port" ] && break
  sleep 0.1
done
[ -s "$tmp/port" ] || fail "the loopback test server did not start"
base="http://127.0.0.1:$(cat "$tmp/port")"

HERMES_HEALTH_URL="$base/health" sh "$script" \
  || fail "a 200 with the platform payload must be healthy"

if HERMES_HEALTH_URL="$base/health-unauthorized" sh "$script" >/dev/null 2>&1; then
  fail "a 401 must be unhealthy, even when the body looks healthy"
fi
if HERMES_HEALTH_URL="$base/health-wrong" sh "$script" >/dev/null 2>&1; then
  fail "a 200 from another server must be unhealthy"
fi
# Port 1 on loopback is not listening, which is what a gateway that never bound
# its port leaves behind.
if HERMES_HEALTH_URL="http://127.0.0.1:1/health" sh "$script" >/dev/null 2>&1; then
  fail "a refused connection must be unhealthy"
fi

# The default probe must be the gateway API on the container's own loopback. A
# stub curl records the arguments, so the URL is checked without a server.
mkdir -p "$tmp/bin"
cat > "$tmp/bin/curl" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$FAKE_ARGS"
printf '%s' '{"status": "ok", "platform": "hermes-agent"}'
EOF
chmod 0755 "$tmp/bin/curl"
FAKE_ARGS="$tmp/args" PATH="$tmp/bin:$PATH" sh "$script" \
  || fail "the default probe did not accept the gateway payload"
grep -Fq 'http://127.0.0.1:8642/health' "$tmp/args" \
  || fail "the default probe is not http://127.0.0.1:8642/health: $(cat "$tmp/args")"

echo "the Hermes health command accepts the gateway API and rejects everything else"
