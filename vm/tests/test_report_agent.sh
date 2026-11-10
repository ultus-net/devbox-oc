#!/usr/bin/env bash
# vm/tests/test_report_agent.sh
#
# A truncated POST has no FAIL line, so before the length check it produced a
# report that read as a pass. Drive the real agent over a loopback socket: a
# short body must be refused and must not create the report or the done flag.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
agent="${1:-$here/../report-agent.py}"
fail() { echo "FAIL: $1" >&2; exit 1; }

[ -f "$agent" ] || fail "no report agent at $agent"
command -v python3 >/dev/null 2>&1 || fail "python3 is required and absent"

tmp="$(mktemp -d)"
agent_pid=""
cleanup() {
  if [ -n "$agent_pid" ]; then
    kill "$agent_pid" 2>/dev/null || true
  fi
  rm -rf "$tmp"
}
trap cleanup EXIT

# Start the agent on an ephemeral port and read the port it actually bound.
"$agent" --port 0 --report "$tmp/report.txt" --done "$tmp/done" \
  >"$tmp/out" 2>"$tmp/err" &
agent_pid=$!
port=""
for _ in $(seq 1 100); do
  port="$(sed -n 's/.*listening on 127\.0\.0\.1:\([0-9][0-9]*\).*/\1/p' "$tmp/err")"
  [ -n "$port" ] && break
  sleep 0.1
done
[ -n "$port" ] || { cat "$tmp/err" >&2; fail "the agent never reported a listening port"; }

# post BODY_LENGTH BODY: send one request and print the status code.
post() {
  python3 - "$port" "$1" "$2" <<'PY'
import socket
import sys

port, declared, body = int(sys.argv[1]), int(sys.argv[2]), sys.argv[3].encode()
request = (
    b"POST /report HTTP/1.1\r\nHost: devbox-vm\r\n"
    b"Content-Type: text/plain\r\n"
    b"Content-Length: " + str(declared).encode() + b"\r\n\r\n" + body
)
with socket.create_connection(("127.0.0.1", port), timeout=10) as sock:
    sock.sendall(request)
    sock.shutdown(socket.SHUT_WR)
    reply = sock.recv(4096)
print(reply.split(b"\r\n", 1)[0].split(b" ")[1].decode())
PY
}

short='PASS booted-image: ucore-minimal
SUMMARY failures=0
'
code="$(post 1000 "$short")"
[ "$code" = 400 ] || fail "a truncated POST was answered $code, not 400"
[ ! -e "$tmp/report.txt" ] || fail "a truncated POST wrote the report"
[ ! -e "$tmp/done" ] || fail "a truncated POST raised the done flag"

clean='PASS booted-image: ucore-minimal
SUMMARY failures=0
'
code="$(post "${#clean}" "$clean")"
[ "$code" = 200 ] || fail "a complete POST was answered $code, not 200"
[ -s "$tmp/report.txt" ] || fail "a complete POST wrote no report"
[ -e "$tmp/done" ] || fail "a complete POST raised no done flag"
grep -qx 'SUMMARY failures=0' "$tmp/report.txt" \
  || fail "the stored report lost its summary line"

# Teeth: remove the length check and the truncated POST must be accepted. The
# false pass is the whole reason the check exists, so the mutation has to change
# the answer before the 400 above is trusted.
if [ "$#" -eq 0 ]; then
  mutated="$tmp/agent-nolength.py"
  sed 's|if len(body) != length:|if False and len(body) != length:|' \
    "$agent" > "$mutated"
  cmp -s "$agent" "$mutated" && fail "mutation did not land"
  rm -f "$tmp/report.txt" "$tmp/done"
  kill "$agent_pid" 2>/dev/null || true
  wait "$agent_pid" 2>/dev/null || true
  agent_pid=""
  python3 "$mutated" --port 0 --report "$tmp/report.txt" --done "$tmp/done" \
    >"$tmp/out2" 2>"$tmp/err2" &
  agent_pid=$!
  port=""
  for _ in $(seq 1 100); do
    port="$(sed -n 's/.*listening on 127\.0\.0\.1:\([0-9][0-9]*\).*/\1/p' "$tmp/err2")"
    [ -n "$port" ] && break
    sleep 0.1
  done
  [ -n "$port" ] || fail "the mutated agent never reported a listening port"
  code="$(post 1000 "$short")"
  if [ "$code" = 400 ]; then
    fail "mutation survived: the truncated POST was still refused without the length check"
  fi
fi

echo "report agent refuses a truncated post"
