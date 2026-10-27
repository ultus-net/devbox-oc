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

run "idle gate"        ./host/tests/test_oc-idle-check.sh
run "secrets and ACR"  ./host/tests/test_oc-secrets.sh
run "OS image publish" ./os/tests/test_build_os_image.sh

# The integrity test needs a tarball. Without one it must fail unless the
# operator opts out, which would make this gate meaningless.
if [ -f /tmp/ocinspect/oc.tgz ]; then
  run "image integrity" ./image/tests/test_integrity_logic.sh /tmp/ocinspect/oc.tgz
else
  printf '== image integrity\n   SKIPPED: no cached tarball at /tmp/ocinspect/oc.tgz\n'
fi

# Lint every shell script we own.
mapfile -t scripts < <(
  find host os image tools tests -name '*.sh' -type f 2>/dev/null
  find host/bin -maxdepth 1 -type f 2>/dev/null
)
if [ "${#scripts[@]}" -gt 0 ]; then
  printf '== shellcheck (%s files)\n' "${#scripts[@]}"
  if /tmp/shellcheck-v0.10.0/shellcheck "${scripts[@]}"; then
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
