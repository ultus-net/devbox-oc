#!/usr/bin/env bash
# tests/ci_shape.sh
#
# The CI is part of the deploy path. These assertions keep it pointed at the
# right registry, keep the verify gate real, and keep the smoke test before any
# push.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
fail() { echo "FAIL: $1" >&2; exit 1; }

verify="$root/.github/workflows/verify.yml"
image="$root/.github/workflows/image.yml"
[ -s "$verify" ] || fail "no verify workflow"
[ -s "$image" ] || fail "no image workflow"

grep -q './tests/verify.sh' "$verify" || fail "verify workflow does not run the repo gate"
grep -q 'butane' "$verify" || fail "verify workflow does not install Butane"
grep -q 'shellcheck' "$verify" || fail "verify workflow does not install shellcheck"

grep -q 'ghcr.io' "$image" || fail "image workflow does not push to GHCR"
grep -q 'IMAGE_NAME: ghcr.io/' "$image" \
  || fail "the image name does not resolve to a GHCR repository"
grep -q 'packages: write' "$image" || fail "image workflow cannot write packages"
grep -q 'image/smoke.sh' "$image" || fail "image workflow has no smoke gate"
grep -q 'pull_request' "$image" || fail "image workflow does not build on pull requests"

# No Azure, no Docker Hub credentials. The image path moved to GHCR with the
# rest of the pivot.
if grep -qiE 'azure|dockerhub|docker\.io.*login' "$image"; then
  fail "image workflow still names an Azure or Docker Hub registry"
fi

# The smoke step must appear before the push step, or a broken image is already
# in the registry by the time the test fails.
smoke_line="$(grep -n 'name: Smoke test' "$image" | head -1 | cut -d: -f1)"
push_line="$(grep -n 'name: Push' "$image" | head -1 | cut -d: -f1)"
if [ -z "$smoke_line" ] || [ -z "$push_line" ]; then
  fail "image workflow is missing a smoke or push step"
fi
if [ "$smoke_line" -ge "$push_line" ]; then
  fail "the image is pushed before it is smoke-tested"
fi

echo "CI publishes to GHCR behind a smoke gate"
