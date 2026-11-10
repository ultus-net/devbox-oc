#!/usr/bin/env bash
# Run every test suite this repo owns, then lint every shell script.
# This is the repo's verification gate; it is what a reviewer runs.
set -uo pipefail

rc=0

run() {
  printf '== %s\n' "$1"
  shift
  if "$@"; then
    printf '   ok\n'
  else
    printf '   FAILED (exit %s)\n' "$?"
    rc=1
  fi
}

run "oc-env writes 0600"     ./host/tests/test_oc-env.sh
run "hermes-env writes 0600" ./host/tests/test_hermes-env.sh
run "hermes quadlet"         ./host/tests/test_hermes_quadlet.sh
run "restic backup"          ./host/tests/test_oc_backup.sh
run "tailnet join"           ./host/tests/test_tailnet_up.sh
run "cockpit loopback"       ./host/tests/test_cockpit_loopback.sh
run "no LAN listener"        ./host/tests/test_no_lan_listener.sh
run "no suspend"             ./host/tests/test_nosleep.sh
run "quadlet persistence"    ./host/tests/test_quadlet_persistence.sh
run "container digest"       ./image/tests/test_digest_record.sh
run "autorebase"             ./os/butane/tests/test_autorebase.sh
run "no Azure leftovers"     ./os/butane/tests/test_no_azure.sh
run "tailscale enabled"      ./os/butane/tests/test_tailscale_enabled.sh

# The artifact check compiles the committed Ignition again, which needs Butane.
# Look for a local binary so the reproducibility assertion is active here; the
# suite reports a SKIP when none is available rather than pretending it ran.
if [ -z "${BUTANE:-}" ]; then
  for candidate in "$(command -v butane 2>/dev/null || true)" "$PWD/.tools/butane"; do
    if [ -n "$candidate" ] && [ -x "$candidate" ]; then
      BUTANE="$candidate"
      export BUTANE
      break
    fi
  done
fi

run "ignition units"         ./os/butane/tests/test_units_have_scripts.sh os/butane/ucore.bu os/butane/ucore.ign
run "data disk mount"        ./os/butane/tests/test_data_mount.sh
run "keyless build"          ./os/butane/tests/test_keyless_build.sh

# The integrity test needs the pinned npm tarball. It fails rather than silently
# passing when it cannot obtain one. ALLOW_INTEGRITY_SKIP=1 is a local opt-out for
# an offline machine; CI sets it to "0" so a download failure is a real failure.
run "image integrity"        ./image/tests/test_integrity_logic.sh

run "vm overlay merge"       ./vm/tests/test_overlay_merge.sh
run "vm run command"         ./vm/tests/test_run_args.sh
run "vm guest helpers"       ./vm/tests/test_guest_helpers.sh
run "vm guest assertions"    ./vm/tests/test_guest_assertions.sh
run "vm guest data"          ./vm/tests/test_guest_data.sh
run "docs complete"          ./tests/docs_complete.sh
run "CI shape"               ./tests/ci_shape.sh

# Lint every shell script we own. Prefer a shellcheck on PATH so this works on a
# build agent, then a local download. A missing linter FAILS the gate unless
# SKIP_LINT=1 is set explicitly: a lint gate that can quietly pass having linted
# nothing is worse than no lint gate, because it buys false confidence.
mapfile -t scripts < <(
  find host os image tests vm -name '*.sh' -type f 2>/dev/null
  find host/bin -maxdepth 1 -type f 2>/dev/null
)

shellcheck_bin=""
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck_bin="$(command -v shellcheck)"
elif [ -x .tools/shellcheck ]; then
  shellcheck_bin=.tools/shellcheck
fi

if [ "${#scripts[@]}" -eq 0 ]; then
  printf '== shellcheck\n   FAILED: no scripts found\n'
  rc=1
elif [ -z "$shellcheck_bin" ]; then
  if [ "${SKIP_LINT:-0}" = "1" ]; then
    printf '== shellcheck\n   SKIPPED: SKIP_LINT=1 and no shellcheck available\n'
  else
    printf '== shellcheck\n   FAILED: no shellcheck on PATH or in .tools\n'
    printf '   install shellcheck, or set SKIP_LINT=1 to skip explicitly\n'
    rc=1
  fi
else
  printf '== shellcheck (%s files)\n' "${#scripts[@]}"
  if "$shellcheck_bin" "${scripts[@]}"; then
    printf '   ok\n'
  else
    printf '   FAILED\n'
    rc=1
  fi
fi

printf '\n'
if [ "$rc" -eq 0 ]; then
  echo "VERIFY: all suites pass"
else
  echo "VERIFY: failures above"
fi
exit "$rc"
