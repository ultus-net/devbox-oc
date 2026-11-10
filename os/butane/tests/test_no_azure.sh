#!/usr/bin/env bash
# os/butane/tests/test_no_azure.sh
#
# The Azure VM design was deleted, not parked. This asserts the shipped code,
# images and CI no longer name any Azure endpoint or module, and that the deleted
# trees stay deleted. Docs are out of scope: the design record explains the pivot
# and is allowed to say "Azure" in prose.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../../.." && pwd)"
fail() { echo "FAIL: $1" >&2; exit 1; }

cd "$root"

for path in terraform pipelines tools host/bin/lib-imds.sh host/bin/oc-secrets \
            host/bin/oc-acr-login host/bin/oc-idle-check host/bin/oc-snapshot; do
  [ ! -e "$path" ] || fail "$path still exists; the Azure design was meant to be deleted"
done

# Scan code, images and CI. test_no_azure.sh is excluded because the pattern is
# the assertion, not a finding.
scan_dirs=(host os image vm .github)
[ -d .github ] || fail "no .github directory, so there is no CI to check"

matches="$(grep -rInE 'azurecr\.io|vault\.azure\.net|169\.254\.169\.254|lib-imds|oc-idle|oc-snapshot|az vm ' \
  "${scan_dirs[@]}" --exclude=test_no_azure.sh || true)"
[ -z "$matches" ] || fail "Azure-era code survives:
$matches"

echo "no Azure endpoint or deleted module survives in shipped code"
