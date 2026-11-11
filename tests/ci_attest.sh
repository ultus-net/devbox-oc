#!/usr/bin/env bash
# tests/ci_attest.sh
#
# The image workflow pushes an attested sha- digest, smoke-tests that digest,
# then promotes :prod to it. These assertions keep that order, keep the
# attestation flags on the push, and keep signing out of the change (#24).
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
fail() { echo "FAIL: $1" >&2; exit 1; }

image="${1:-$root/.github/workflows/image.yml}"
[ -s "$image" ] || fail "no image workflow at $image"
command -v python3 >/dev/null \
  || fail "no python3: the attestation guard parses the workflow"

python3 - "$image" <<'PY'
import re
import sys

import yaml

path = sys.argv[1]
text = open(path).read()
try:
    doc = yaml.safe_load(text)
except yaml.YAMLError as exc:
    sys.exit("FAIL: the workflow is not valid YAML: %s" % exc)


def fail(message):
    print("FAIL: " + message, file=sys.stderr)
    sys.exit(1)


def with_(step):
    return step.get("with") or {}


def env_(step):
    return step.get("env") or {}


def truthy(value):
    return value is True or str(value).strip().lower() in ("true", "1")


build = (doc.get("jobs") or {}).get("build")
if not isinstance(build, dict) or not isinstance(build.get("steps"), list):
    fail("the workflow has no build job with steps")
steps = build["steps"]

buildx_steps = [
    s for s in steps
    if str(s.get("uses", "")).startswith("docker/build-push-action@")
]
push_steps = [s for s in buildx_steps if truthy(with_(s).get("push"))]
if len(push_steps) != 1:
    fail("the build has %d attested push steps, not one (mode=max)" % len(push_steps))
push = push_steps[0]
provenance = str(with_(push).get("provenance", "")).strip()
if provenance != "mode=max":
    fail("the push sets provenance %r, not mode=max (mode=max)" % provenance)
if not truthy(with_(push).get("sbom")):
    fail("the attested push sets no sbom, so the mode=max claim is half (mode=max)")

for step in buildx_steps:
    if truthy(with_(step).get("load")) and (
        with_(step).get("provenance") or with_(step).get("sbom")
    ):
        fail("a load step claims attestations the docker exporter drops (docker exporter)")

prod_steps = [s for s in steps if ":prod" in str(s.get("run", ""))]
if len(prod_steps) != 1:
    fail(
        "the :prod tag moves in %d steps, so it does not move only through "
        "buildx (not through buildx)" % len(prod_steps)
    )
for step in steps:
    if re.search(
        r"(?m)^\s*docker\s+(?:image\s+)?push\b", str(step.get("run", ""))
    ):
        fail(
            "a step runs raw docker push, so a tag can publish untested "
            "(not through buildx)"
        )

digest_ref = str((build.get("outputs") or {}).get("digest", ""))
match = re.search(r"steps\.([A-Za-z0-9_-]+)\.outputs\.digest", digest_ref)
if not match:
    fail("the build digest output names no step output (digest output)")
if match.group(1) != push.get("id"):
    fail(
        "the digest output reads step %r, not the push step %r (digest output)"
        % (match.group(1), push.get("id"))
    )

smoke = [s for s in steps if "image/smoke.sh" in str(s.get("run", ""))]
if len(smoke) != 2:
    fail(
        "the workflow runs %d smoke steps, not the published and local pair "
        "(before it is smoke-tested)" % len(smoke)
    )
pull_steps = [
    s for s in steps
    if re.search(r"(?m)^\s*docker\s+pull\b", str(s.get("run", "")))
]
if len(pull_steps) != 1:
    fail("the workflow does not pull exactly one digest (before it is smoke-tested)")
pull = pull_steps[0]
if "steps.build.outputs.digest" not in str(env_(pull).get("IMAGE_REF", "")):
    fail(
        "the pull does not use the digest the push wrote "
        "(before it is smoke-tested)"
    )
if pull not in smoke:
    fail("the pulled digest is not the one smoke-tested (before it is smoke-tested)")

promote = prod_steps[0]
if steps.index(promote) < steps.index(pull):
    fail("the prod tag is promoted before it is smoke-tested (before it is smoke-tested)")

run = str(promote.get("run", ""))
if "imagetools create" not in run:
    fail("the promotion is not an imagetools create (imagetools create)")
if not re.search(r"(?m)^\s*docker buildx imagetools create\b", run):
    fail("the promotion does not run under buildx (imagetools create)")
if "-t" not in run or ":prod" not in run:
    fail("the promotion does not retag :prod (imagetools create)")
source = re.search(r"@\$\{([A-Za-z_][A-Za-z0-9_]*)\}", run)
if not source:
    fail("the promotion does not copy a digest (imagetools create)")
if str(env_(promote).get(source.group(1), "")) != "${{ steps.build.outputs.digest }}":
    fail(
        "the promotion copies %s, not the tested digest (imagetools create)"
        % source.group(1)
    )
if "--prefer-index=false" in run:
    fail("the promotion would drop the attestation child (imagetools create)")

# The runtime check is shell, so read the uncommented lines only and bind the
# reader to the inspect command. A commented token, or a token on a line away
# from the reader, must not satisfy this.
code = [line for line in run.splitlines() if not line.strip().startswith("#")]
inspect = [i for i, line in enumerate(code) if "{{json .Manifest}}" in line]
if not inspect:
    fail("the promotion does not inspect the promoted index (attestation)")
check = "\n".join(code[inspect[0]:])
for needle in (
    ".annotations[\"vnd.docker.reference.type\"]",
    "attestation-manifest",
    "jq -e",
):
    if needle not in check:
        fail("the promotion does not parse the attestation child (attestation)")

# Pin the two ref conditions exactly. They are the whole fork and dispatch
# safety property, so a broader expression must fail rather than match a
# substring.
login = [
    s for s in steps
    if str(s.get("uses", "")).startswith("docker/login-action@")
]
if len(login) != 1:
    fail("the workflow has %d login steps, not one (fork)" % len(login))
login_if = " ".join(str(login[0].get("if", "")).split())
want_login = (
    "github.ref == 'refs/heads/main' || startsWith(github.ref, 'refs/tags/')"
)
if login_if != want_login:
    fail("the login condition is not exactly main or a tag (fork)")

loads = [s for s in buildx_steps if truthy(with_(s).get("load"))]
if len(loads) != 1:
    fail("the workflow has %d local build steps, not one (manual dispatch)" % len(loads))
load_if = " ".join(str(loads[0].get("if", "")).split())
want_load = (
    "github.ref != 'refs/heads/main' && !startsWith(github.ref, 'refs/tags/')"
)
if load_if != want_load:
    fail("the local build condition is not the exact complement (manual dispatch)")

for block in [doc.get("permissions") or {}] + [
    (job.get("permissions") or {}) for job in (doc.get("jobs") or {}).values()
]:
    if "id-token" in block:
        fail("the workflow grants id-token, so signing crept in (#24)")
if "cosign" in text:
    fail("the workflow names cosign, and signing is not this change (#24)")
PY

# Teeth: with no argument, prove each assertion catches its named mutation.
if [ $# -eq 0 ]; then
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  mutated="$tmp/image.yml"

  mutate() {
    python3 - "$image" "$mutated" "$1" <<'PY'
import sys

import yaml

src, dst, name = sys.argv[1], sys.argv[2], sys.argv[3]
doc = yaml.safe_load(open(src))
steps = doc["jobs"]["build"]["steps"]
if name == "load-carries-attestations":
    step = next(s for s in steps if (s.get("with") or {}).get("load"))
    step.setdefault("with", {})["provenance"] = "mode=max"
    step["with"]["sbom"] = True
elif name == "silent-noop-provenance":
    step = next(s for s in steps if (s.get("with") or {}).get("push"))
    del step["with"]["provenance"]
elif name == "promote-before-smoke":
    index = next(
        i for i, s in enumerate(steps) if "imagetools create" in str(s.get("run", ""))
    )
    steps.insert(0, steps.pop(index))
elif name == "raw-docker-push":
    steps.append(
        {"name": "Raw docker push", "run": 'docker image push --all-tags "$IMAGE_NAME"'}
    )
elif name == "login-reaches-fork":
    step = next(
        s for s in steps
        if str(s.get("uses", "")).startswith("docker/login-action@")
    )
    step["if"] = (
        "github.ref == 'refs/heads/main' || startsWith(github.ref, 'refs/tags/')"
        " || github.event_name == 'pull_request'"
    )
elif name == "dispatch-skips-local":
    step = next(s for s in steps if (s.get("with") or {}).get("load"))
    step["if"] = (
        "github.ref != 'refs/heads/main' && !startsWith(github.ref, 'refs/tags/')"
        " && github.event_name != 'workflow_dispatch'"
    )
elif name == "commented-child-check":
    step = next(s for s in steps if ":prod" in str(s.get("run", "")))
    step["run"] = "\n".join(
        ("# " + line) if "attestation-manifest" in line else line
        for line in str(step["run"]).splitlines()
    )
else:
    sys.exit("unknown mutation: " + name)
with open(dst, "w") as handle:
    yaml.dump(doc, handle)
PY
  }

  caught() {
    local name="$1" token="$2" out
    cp "$image" "$mutated"
    mutate "$name"
    if cmp -s "$image" "$mutated"; then
      fail "$name mutation did not land"
    fi
    if out="$("$0" "$mutated" 2>&1)"; then
      fail "the guard accepted $name"
    fi
    case "$out" in
      *"$token"*) ;;
      *) fail "$name was not caught by its token $token: $out" ;;
    esac
    echo "teeth: caught $name"
  }

  caught load-carries-attestations "docker exporter"
  caught silent-noop-provenance "mode=max"
  caught promote-before-smoke "before it is smoke-tested"
  caught raw-docker-push "not through buildx"
  caught login-reaches-fork "fork"
  caught dispatch-skips-local "manual dispatch"
  caught commented-child-check "attestation"
  echo "teeth: 7 mutations caught"
fi

echo "CI publishes an attested digest and promotes prod only after the smoke gate"
