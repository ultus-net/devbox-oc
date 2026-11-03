#!/usr/bin/env bash
# pipelines/tests/test_pipeline_shape.sh - the PR gate has to be able to run, and
# has to be able to fail.
#
# Each assertion guards one way this pipeline goes wrong. A gate with no `pr:`
# trigger never runs. One that carries a service connection cannot run on a fork.
# One that never installs shellcheck fails tests/verify.sh for a tooling reason
# and hides the code reason.
#
# Usage: test_pipeline_shape.sh [pipeline.yml]
# The argument exists so this can be pointed at another pipeline to prove the
# assertions can fail.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
yml="${1:-$root/pipelines/devbox-verify.yml}"
display="${yml#"$root"/}"
fail() { echo "FAIL: $1" >&2; exit 1; }

[ -f "$yml" ] || fail "$display missing"

# Parse rather than grep: a `pr:` in a comment is not a trigger, and `pr: none`
# is the absence of one.
command -v python3 >/dev/null 2>&1 || fail "python3 is required and absent"
python3 -c 'import yaml' >/dev/null 2>&1 || fail "python3 has no PyYAML module"

python3 - "$yml" "$display" <<'PY' || exit 1
import re
import sys

import yaml

path, display = sys.argv[1], sys.argv[2]


def fail(message):
    print(f"FAIL: {message}", file=sys.stderr)
    sys.exit(1)


with open(path, encoding="utf-8") as handle:
    text = handle.read()

try:
    doc = yaml.safe_load(text)
except yaml.YAMLError as exc:
    fail(f"{display} does not parse as YAML: {exc}")

if not isinstance(doc, dict):
    fail(f"{display} is not a YAML mapping")

pr = doc.get("pr")
if not isinstance(pr, dict) or not (pr.get("paths") or {}).get("include"):
    fail(f"{display} has no pr trigger with path filters (pr is {pr!r})")

# A gate that needs credentials cannot run on a fork, and tests/verify.sh needs
# no Azure access at all.
if "azureSubscription" in text:
    fail(f"{display} references azureSubscription")

steps = [step for job in doc.get("jobs") or [] for step in job.get("steps") or []]


def body(step):
    return f"{step.get('script') or ''}\n{(step.get('inputs') or {}).get('inlineScript') or ''}"


# A step that only mentions the path in an echo would satisfy a substring search, so
# require an invocation: at line start, optionally with a bash prefix.
invoke = re.compile(r"^\s*(?:bash\s+)?\S*tests/verify\.sh\b", re.M)

installs = [i for i, s in enumerate(steps) if "shellcheck" in body(s) and "apt" in body(s)]
runs = [i for i, s in enumerate(steps) if invoke.search(body(s))]

if not installs:
    fail(f"{display} never installs shellcheck, so tests/verify.sh fails for want of a linter")
if not runs:
    fail(f"{display} never runs tests/verify.sh")
if installs[0] > runs[0]:
    fail(f"{display} runs tests/verify.sh before installing shellcheck")
PY

echo "pipeline shape ok: $display"
