#!/usr/bin/env bash
# tools/tests/test_oc.sh - the wrapper starts the box, waits for health, then execs.
#
# Fakes az, curl, opencode, date and sleep on PATH, so the suite needs no Azure
# account, no network, and no 60 to 120 second cold start.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
script="$here/../oc"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }

# Knobs, reset by every setup() so one case cannot leak into the next.
setup() {
  rm -rf "${tmp:?}/bin" "${tmp:?}/counts" "${tmp:?}/clock"
  mkdir -p "$tmp/bin" "$tmp/counts"
  : > "$tmp/log"
  AZ_POWER=PowerState/deallocated
  HEALTHY_AFTER=1
  TIMEOUT=10

  cat > "$tmp/bin/az" <<'EOF'
#!/usr/bin/env bash
printf 'az %s\n' "$*" >> "$LOG"
case "$*" in *get-instance-view*) printf '%s\n' "$AZ_POWER" ;; esac
EOF

  # Scan every argument for the URL. The wrapper passes -o /dev/null after it, so
  # reading the last argument would never see it.
  cat > "$tmp/bin/curl" <<'EOF'
#!/usr/bin/env bash
url=""
for a in "$@"; do case "$a" in http*) url="$a" ;; esac; done
printf 'curl %s\n' "$url" >> "$LOG"
n=0
[ -f "$COUNTS/curl" ] && n="$(cat "$COUNTS/curl")"
n=$(( n + 1 ))
printf '%s' "$n" > "$COUNTS/curl"
[ "$n" -ge "$HEALTHY_AFTER" ]
EOF

  cat > "$tmp/bin/opencode" <<'EOF'
#!/usr/bin/env bash
printf 'opencode %s\n' "$*" >> "$LOG"
EOF

  # Count one second per call once a clock file exists, so the timeout case does
  # not wait for wall time. Without one, defer to the real date.
  cat > "$tmp/bin/date" <<'EOF'
#!/usr/bin/env bash
[ -n "${CLOCK:-}" ] && [ -f "$CLOCK" ] || exec /bin/date "$@"
n=$(( $(cat "$CLOCK") + 1 ))
printf '%s' "$n" > "$CLOCK"
printf '%s' "$n"
EOF

  printf '#!/usr/bin/env bash\nexit 0\n' > "$tmp/bin/sleep"
  chmod +x "$tmp/bin/az" "$tmp/bin/curl" "$tmp/bin/opencode" \
    "$tmp/bin/date" "$tmp/bin/sleep"
}

rc=0
run_wrapper() {
  rc=0
  env PATH="$tmp/bin:$PATH" LOG="$tmp/log" COUNTS="$tmp/counts" \
    CLOCK="$tmp/clock" OC_VM=vm OC_RG=rg OC_URL="https://oc.test" \
    POLL_INTERVAL=0 TIMEOUT="$TIMEOUT" AZ_POWER="$AZ_POWER" \
    HEALTHY_AFTER="$HEALTHY_AFTER" \
    "$script" "$@" > "$tmp/out" 2> "$tmp/err" || rc=$?
}

count() { grep -c "$1" "$tmp/log" || true; }

# T0: the script must be executable, or an unexecutable commit passes vacuously.
[ -x "$script" ] || fail "T0 tools/oc is not executable"

# T1: deallocated starts the VM, polls to health, then execs against the URL.
setup
HEALTHY_AFTER=3
run_wrapper
[ "$rc" -eq 0 ] || fail "T1 wrapper exited ${rc}: $(cat "$tmp/err")"
grep -q '^az vm start -g rg -n vm' "$tmp/log" || fail "T1 did not start the VM"
[ "$(count '^curl ')" -ge 3 ] || fail "T1 did not poll to health"
grep -qx 'opencode --server https://oc.test' "$tmp/log" \
  || fail "T1 did not exec opencode with the server URL"

# T2: a running VM is not started again, but it is still polled and exec'd.
setup
AZ_POWER=PowerState/running
HEALTHY_AFTER=2
run_wrapper
[ "$rc" -eq 0 ] || fail "T2 wrapper exited ${rc}: $(cat "$tmp/err")"
if grep -q '^az vm start' "$tmp/log"; then
  fail "T2 started the VM although it is running"
fi
[ "$(count '^curl ')" -ge 2 ] || fail "T2 did not poll to health"
grep -qx 'opencode --server https://oc.test' "$tmp/log" \
  || fail "T2 did not exec opencode with the server URL"

# T3: never healthy exits non-zero once TIMEOUT passes, and names the URL.
setup
printf '1' > "$tmp/clock"
HEALTHY_AFTER=999
TIMEOUT=3
run_wrapper
[ "$rc" -ne 0 ] || fail "T3 exited 0 although health never answered"
grep -q 'https://oc.test' "$tmp/err" \
  || fail "T3 timeout message does not name the URL: $(cat "$tmp/err")"
[ "$(count '^curl ')" -le 6 ] || fail "T3 kept polling past TIMEOUT"
if grep -q '^opencode ' "$tmp/log"; then
  fail "T3 exec'd the TUI although health never answered"
fi

# T4: --print-server prints the URL and never execs the TUI.
setup
run_wrapper --print-server
[ "$rc" -eq 0 ] || fail "T4 --print-server exited ${rc}: $(cat "$tmp/err")"
[ "$(cat "$tmp/out")" = "https://oc.test" ] \
  || fail "T4 --print-server printed '$(cat "$tmp/out")'"
if grep -q '^opencode ' "$tmp/log"; then
  fail "T4 exec'd the TUI in --print-server mode"
fi

echo "wrapper starts, waits, then execs"
