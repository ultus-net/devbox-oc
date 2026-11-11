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

# The linter is pinned by version and sha256, like Butane. A package from the
# runner image moves with that image, so the same commit can change verdict.
# Parse the workflow: a grep for the pin still passes when the line is
# commented out, which is how a disabled checksum would ship.
python3 - "$verify" "$root/tests/verify.sh" <<'PY'
import re
import sys

import yaml

workflow, gate = sys.argv[1], sys.argv[2]
doc = yaml.safe_load(open(workflow))
steps = doc["jobs"]["verify"]["steps"]
step = next((s for s in steps if s.get("name") == "Install shellcheck"), None)
if step is None:
    sys.exit("FAIL: verify workflow has no Install shellcheck step")


def fail(message):
    print("FAIL: " + message, file=sys.stderr)
    sys.exit(1)


env = step.get("env") or {}
version = env.get("SHELLCHECK_VERSION", "")
if not re.fullmatch(r"v\d+\.\d+\.\d+", version):
    fail("SHELLCHECK_VERSION is not a fixed semver tag: " + repr(version))
if not re.fullmatch(r"[0-9a-f]{64}", env.get("SHELLCHECK_SHA256", "")):
    fail("SHELLCHECK_SHA256 is not a sha256 hex digest")

run = step.get("run") or ""


def executed(text):
    # A commented line does not run, so a "temporarily disabled" step is gone.
    return "\n".join(
        line for line in text.splitlines() if not line.strip().startswith("#")
    )


def logical_lines(text):
    # A trailing backslash continues a command onto the next line, so join those
    # before matching. A per-line reader misses an install split after install.
    lines, pending = [], ""
    for line in executed(text).splitlines():
        # Only a backslash in the last column continues the command. A trailing
        # space escapes that space instead, so the next line runs on its own.
        if line.endswith("\\"):
            pending += line[:-1] + " "
            continue
        lines.append(pending + line)
        pending = ""
    if pending.strip():
        lines.append(pending)
    return lines


body = executed(run)

# The install step is a fixed sequence, so compare it to that sequence instead
# of blocklisting constructs. A text reader cannot prove a command runs, and any
# extra line can shadow a command or skip the checksum, so an unlisted line
# fails here until this list moves with it in the same commit. Proving execution
# needs the step run, which CI does on every pull request.
PINNED = (
    r"set -euo pipefail",
    r'url="https://github\.com/koalaman/shellcheck/releases/download/'
    r"\$\{SHELLCHECK_VERSION\}/shellcheck-\$\{SHELLCHECK_VERSION\}\.linux\.x86_64"
    r'\.tar\.gz"',
    r'curl -fsSL -o /tmp/shellcheck\.tar\.gz "\$url"',
    r'echo "\$\{SHELLCHECK_SHA256\}  /tmp/shellcheck\.tar\.gz" \| sha256sum -c -',
    r"tar -xzf /tmp/shellcheck\.tar\.gz -C /tmp",
    r'sudo install -m 0755 "/tmp/shellcheck-\$\{SHELLCHECK_VERSION\}/shellcheck" '
    r"/usr/local/bin/shellcheck",
    r"shellcheck --version",
    r"\[ \"\$\(shellcheck --version \| awk '/\^version:/ \{print \$2\}'\)\" = "
    r'"\$\{SHELLCHECK_VERSION#v\}" \]',
)

lines = [line.strip() for line in logical_lines(body) if line.strip()]
if len(lines) != len(PINNED):
    fail(
        "the shellcheck install runs %d commands, the pinned sequence has %d"
        % (len(lines), len(PINNED))
    )
for number, (line, pattern) in enumerate(zip(lines, PINNED), start=1):
    if not re.fullmatch(pattern, line):
        fail("the shellcheck install line %d is not the pinned command: %s" % (number, line))

for other in steps:
    for line in logical_lines(other.get("run") or ""):
        if re.search(r"apt(-get)?(\s+-\S+)*\s+install\b.*shellcheck", line):
            fail("a workflow step installs shellcheck with apt: " + line.strip())

if "SHELLCHECK_VERSION" not in open(gate).read():
    fail("the gate does not read the shellcheck pin")
PY

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
# Without this condition the write token would sit on pull_request runs too. Any
# mention of pull_request fails: a widened OR would reintroduce that. A safe
# tightening to push events names push instead, and still passes.
gate = str(record.get("if", ""))
if "refs/heads/main" not in gate:
    fail("the record job is not limited to main")
if "pull_request" in gate:
    fail("the record job condition names a pull request event: " + gate)
# A negation such as event_name != 'push' also admits pull requests, so any
# event narrowing must be the positive push form.
if "event_name" in gate and "event_name == 'push'" not in gate:
    fail("the record job narrows by an event other than push: " + gate)

for scope in ("contents",):
    if scopes(record.get("permissions")).get(scope) != "write":
        fail("the record job cannot write " + scope)
# The repair pushes a branch and prints a compare URL; it does not open the PR.
# The token cannot, and asking for the scope only hides that.
if "write" in str(scopes(record.get("permissions")).get("pull-requests", "")):
    fail("the record job holds pull-requests write, but the repair cannot open a PR")
for scope in ("contents", "pull-requests", "packages"):
    if "write" in str(scopes(build.get("permissions")).get(scope, "")):
        fail("the build job holds a write scope on the PR code path: " + scope)

if "image/promote-digest.sh" not in runs_in(record):
    fail("the record job does not run the digest repair script")
if "promote-digest.sh" in runs_in(build):
    fail("the digest repair still runs inside the build job")

# The repair produces an operator PR that changes only the record. A main push
# that rewrites it must not rebuild: the new build stamps a fresh digest and
# re-stales the record the merge just fixed. YAML 1.1 parses the key "on" as a
# boolean, so accept either form rather than silently reading no trigger.
triggers = doc.get(True) or doc.get("on") or {}
paths = ((triggers.get("push") or {}).get("paths")) or []
if "image/**" not in paths:
    fail("a main push no longer builds the image paths")
if "!image/prod-digest.txt" not in paths:
    fail("a main push that only rewrites the digest record still rebuilds")
# GitHub applies paths in order: a negation only excludes what a positive pattern
# matched before it. Listing the exclusion first re-includes the record.
if paths.index("!image/prod-digest.txt") < paths.index("image/**"):
    fail("the record exclusion comes before the image paths, so it does not exclude")

# The repair PR changes only the record, so its build is the only CI it gets.
# Copying the push exclusion here would leave that PR unchecked.
pr_paths = ((triggers.get("pull_request") or {}).get("paths")) or []
if "image/**" not in pr_paths:
    fail("a pull request no longer builds the image paths")
if "!image/prod-digest.txt" in pr_paths:
    fail("a repair pull request excludes the digest record, so it has no CI")
PY

echo "CI publishes to GHCR behind a smoke gate"
