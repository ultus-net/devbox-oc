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

# A promoted digest that differs from the record is a silent rollback fault. The
# repair runs in its own job so the write token never sits on the job that
# executes PR-controlled code. Assert the parsed structure, because a grep for
# "check-prod-digest.sh" still passes when the line is commented out.
python3 - "$image" <<'PY'
import sys, yaml

doc = yaml.safe_load(open(sys.argv[1]))


def fail(message):
    print("FAIL: " + message, file=sys.stderr)
    sys.exit(1)


def scopes(block):
    return block or {}


def runs_in(job):
    # A shebang-style run block can carry comments, and a commented-out command
    # still matches a substring. Drop those lines before matching.
    lines = []
    for step in job.get("steps", []):
        for line in str(step.get("run", "")).splitlines():
            if not line.lstrip().startswith("#"):
                lines.append(line)
    return "\n".join(lines)


build = doc["jobs"].get("build")
record = doc["jobs"].get("record-digest")
if build is None or record is None:
    fail("the image workflow needs a build job and a record-digest job")

global_scopes = scopes(doc.get("permissions"))
for scope in ("contents", "pull-requests"):
    if "write" in str(global_scopes.get(scope, "")):
        fail("the workflow grants write " + scope + " to every job")

if "digest" not in (build.get("outputs") or {}):
    fail("the build job does not publish the promoted digest")
if record.get("needs") != "build":
    fail("the record job does not depend on the build job")
# Without this condition the write token would sit on pull_request runs too. A
# widened condition can reintroduce that, so reject the event names outright.
gate = str(record.get("if", ""))
if "refs/heads/main" not in gate:
    fail("the record job is not limited to main")
if "pull_request" in gate or "event_name" in gate:
    fail("the record job condition can run on a pull request: " + gate)

for scope in ("contents", "pull-requests"):
    if scopes(record.get("permissions")).get(scope) != "write":
        fail("the record job cannot write " + scope)
for scope in ("contents", "pull-requests", "packages"):
    if "write" in str(scopes(build.get("permissions")).get(scope, "")):
        fail("the build job holds a write scope on the PR code path: " + scope)

if "image/promote-digest.sh" not in runs_in(record):
    fail("the record job does not run the digest repair script")
if "promote-digest.sh" in runs_in(build):
    fail("the digest repair still runs inside the build job")
PY

echo "CI publishes to GHCR behind a smoke gate"
