#!/usr/bin/env bash
# host/tests/test_oc-idle-check.sh
# Fake curl, date and sleep on PATH, so no network or clock is needed.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
script="$here/../bin/oc-idle-check"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }

setup() {
  rm -rf "${tmp:?}/bin" "${tmp:?}/state"
  mkdir -p "$tmp/bin" "$tmp/state"
  printf 'OPENCODE_PASSWORD=pw\n' > "$tmp/env"
  printf '/subscriptions/x/resourceGroups/r/providers/Microsoft.Compute/virtualMachines/v\n' > "$tmp/vmid"
  : > "$tmp/arm-calls"
  cat > "$tmp/bin/curl" <<'EOF'
#!/usr/bin/env bash
# The URL is not the last argument: the deallocate call ends with `-o /dev/null`,
# so classify every call by the first http argument instead.
url=""
for a in "$@"; do case "$a" in http*) url="$a" ;; esac; done
if [[ "$url" == *"/api/"* ]]; then
  ep="$(printf '%s' "$url" | sed 's|.*/api/||')"
  case " ${FAIL_EPS:-} " in *" $ep "*) exit 28 ;; esac   # timeout, like a real failure
  # Build the default in a variable: ${RESP:-{"data":[]}} eats one brace and
  # emits invalid JSON, which makes jq fail and the gate look busy everywhere.
  body="${RESP:-}"
  [ -n "$body" ] || body='{"data":[]}'
  printf '%s' "$body"
  exit 0
fi
if [[ "$url" == *"169.254.169.254"* ]]; then printf '%s' '{"access_token":"tok"}'; exit 0; fi
if [[ "$url" == *"management.azure.com"* ]]; then echo "$url" >> "$ARM_CALLS"; exit 0; fi
exit 0
EOF
  cat > "$tmp/bin/date" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == "+%s" ]] && { printf '%s' "${NOW:-1000000}"; exit 0; }
exec /bin/date "$@"
EOF
  printf '#!/usr/bin/env bash\nexit 0\n' > "$tmp/bin/sleep"   # skip the 60s second look
  chmod +x "$tmp/bin/curl" "$tmp/bin/date" "$tmp/bin/sleep"
}

# A last-busy old enough that every test would deallocate if its guard failed.
# NOW must be later than it: 2000000 is 1970, which makes now-last negative and
# hides every guard behind the threshold check.
stale() { printf '1700000000\n' > "$tmp/state/last-busy"; }

run_gate() {
  local rc=0
  PATH="$tmp/bin:$PATH" \
  ENV_FILE="$tmp/env" VM_ID_FILE="$tmp/vmid" STATE="$tmp/state/last-busy" \
  PIN_FILE="${PIN_FILE:-$tmp/state/pin}" ARM_CALLS="$tmp/arm-calls" \
  UPTIME_OVERRIDE="${UPTIME:-2000}" IDLE_MIN="${IDLE_MIN:-45}" \
  NOW="${NOW:-2000000000}" \
  bash "$script" >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 0 ] || fail "gate exited ${rc}; it must always exit 0"
}

# T0: the script must be executable, or every other test passes vacuously.
setup
[ -x "$script" ] || fail "T0 oc-idle-check is not executable"

# T1: a running session blocks shutdown.
setup; stale
RESP='{"data":{"ses_1":{"type":"running"}}}' run_gate
[ ! -s "$tmp/arm-calls" ] || fail "T1 deallocated with a running session"

# T2: a partial failure blocks shutdown. pty times out, everything else empty.
setup; stale
RESP='{"data":[]}' FAIL_EPS='pty' run_gate
[ ! -s "$tmp/arm-calls" ] || fail "T2 deallocated after a probe error"

# T3: boot grace blocks shutdown.
setup; stale
RESP='{"data":[]}' UPTIME=100 run_gate
[ ! -s "$tmp/arm-calls" ] || fail "T3 deallocated inside boot grace"

# T4: the pin file blocks shutdown, even when idle and old.
setup; stale
: > "$tmp/state/pin"
RESP='{"data":[]}' run_gate
[ ! -s "$tmp/arm-calls" ] || fail "T4 deallocated while pinned"

# T5: genuinely idle past threshold and unpinned deallocates exactly once.
setup; stale
RESP='{"data":[]}' run_gate
[ "$(wc -l < "$tmp/arm-calls")" -eq 1 ] || fail "T5 expected exactly one deallocate call"

# T6: inside the threshold, no action.
setup
printf '1700000000\n' > "$tmp/state/last-busy"
RESP='{"data":[]}' NOW=1700001000 run_gate
[ ! -s "$tmp/arm-calls" ] || fail "T6 deallocated inside the idle threshold"

echo "all idle-gate tests passed"
