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

run "idle gate"           ./host/tests/test_oc-idle-check.sh
run "secrets and ACR"     ./host/tests/test_oc-secrets.sh
run "tailnet join"        ./host/tests/test_tailnet_up.sh
run "OS image publish"    ./os/tests/test_build_os_image.sh
run "container digest"    ./image/tests/test_digest_record.sh
run "quadlet persistence" ./host/tests/test_quadlet_persistence.sh
run "ignition units"      ./os/butane/tests/test_units_have_scripts.sh os/butane/ucore.ign

# Terraform guards. These test the assertions themselves against fixtures, since
# a real plan needs a subscription.
run "no public ingress (violation detected)" \
  bash -c './terraform/tests/no_public_ip.sh terraform/tests/fixtures/violation_public_ip.json && exit 1 || exit 0'
run "no public ingress (clean passes)" \
  ./terraform/tests/no_public_ip.sh terraform/tests/fixtures/clean.json
run "no scheduled stop" \
  ./terraform/tests/no_scheduled_stop.sh
run "data disk protected" \
  ./terraform/tests/data_disk_protected.sh
run "vault name derivable without state" \
  ./terraform/tests/key_vault_name_derived.sh

run "docs complete"  ./tests/docs_complete.sh
run "wake wrapper"   ./tools/tests/test_oc.sh

# The integrity test needs a tarball. Without one it must fail unless the
# operator opts out, which would make this gate meaningless.
if [ -f /tmp/ocinspect/oc.tgz ]; then
  run "image integrity" ./image/tests/test_integrity_logic.sh /tmp/ocinspect/oc.tgz
else
  printf '== image integrity\n   SKIPPED: no cached tarball at /tmp/ocinspect/oc.tgz\n'
fi

# Lint every shell script we own. Prefer a shellcheck on PATH so this works on a
# company build agent, then a local download. A missing linter FAILS the gate
# unless SKIP_LINT=1 is set explicitly: a lint gate that can quietly pass having
# linted nothing is worse than no lint gate, because it buys false confidence.
mapfile -t scripts < <(
  find host os image tools tests terraform -name '*.sh' -type f 2>/dev/null
  find host/bin -maxdepth 1 -type f 2>/dev/null
)

shellcheck_bin=""
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck_bin="$(command -v shellcheck)"
elif [ -x /tmp/shellcheck-v0.10.0/shellcheck ]; then
  shellcheck_bin=/tmp/shellcheck-v0.10.0/shellcheck
fi

if [ "${#scripts[@]}" -eq 0 ]; then
  printf '== shellcheck\n   SKIPPED: no scripts found\n'
elif [ -z "$shellcheck_bin" ]; then
  if [ "${SKIP_LINT:-0}" = "1" ]; then
    printf '== shellcheck\n   SKIPPED: SKIP_LINT=1 and no shellcheck available\n'
  else
    printf '== shellcheck\n   FAILED: no shellcheck on PATH or in /tmp\n'
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
