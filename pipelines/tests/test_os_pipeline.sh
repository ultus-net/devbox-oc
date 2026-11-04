#!/usr/bin/env bash
# pipelines/tests/test_os_pipeline.sh
#
# pipelines/devbox-os.yml runs on an Ubuntu runner and needs four things to be
# true at once, none of which the YAML parser alone can see:
#
#   1. podman is installed, because the script pulls the OS container with it and
#      the builder container reads that same storage
#   2. the builder container is pinned by digest, for the same reason the OS is:
#      a moving tag changes how the image is produced without changing this file
#   3. the credential the AzureCLI task sets up survives the sudo boundary. This
#      is the one that fails only on a real agent: sudo resets the environment, so
#      az runs as root with no AZURE_CONFIG_DIR and reports that nobody is logged
#      in. Nothing local catches it, and the failure arrives after a long build.
#   4. the run targets rg-csh-dev in newzealandnorth and names no storage account,
#      because the deleted account is not coming back for this pipeline.
#
# Usage: test_os_pipeline.sh [pipeline.yml]
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
yml="${1:-$root/pipelines/devbox-os.yml}"
display="${yml#"$root"/}"
fail() { echo "FAIL: $1" >&2; exit 1; }

[ -f "$yml" ] || fail "$display missing"
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
    doc = yaml.safe_load(handle.read())

if not isinstance(doc, dict):
    fail(f"{display} is not a YAML mapping")

steps = [step for job in doc.get("jobs") or [] for step in job.get("steps") or []]


def body(step):
    return f"{step.get('script') or ''}\n{(step.get('inputs') or {}).get('inlineScript') or ''}"


# The builder runs in a container, so the script needs podman on the runner. A
# runner without it fails at the pull, after the job has already spent its time.
# Match the install command, not the word: the same step runs `podman --version`
# and `apt-get update`, so a loose substring check survives deleting the install.
installs_podman = any(
    re.search(r"apt(?:-get)?\s+install[^\n]*\bpodman\b", body(s)) for s in steps
)
if not installs_podman:
    fail(
        f"{display} never installs podman, so the pull cannot happen on an Ubuntu runner"
    )

# The builder container is part of the build, so it is pinned like the OS is.
# Read from the parsed variables, not from the raw text: a comment quoting a
# digest would otherwise satisfy a pin that does not exist.
variables = {}
for job in doc.get("jobs") or []:
    for key, value in (job.get("variables") or {}).items():
        variables[str(key)] = str(value)
for key, value in (doc.get("variables") or {}).items():
    variables.setdefault(str(key), str(value))

builder = variables.get("imageBuilderContainer", "")
if not re.fullmatch(r"\S+@sha256:[0-9a-f]{64}", builder):
    fail(
        f"{display} does not pin imageBuilderContainer by digest "
        f"(got {builder!r}), so the build recipe can change under a fixed name"
    )

# The target is part of the contract. A placeholder here publishes the image to
# a resource group nobody deployed, and the failure looks like a permission bug.
if variables.get("resourceGroup") != "rg-csh-dev":
    fail(
        f"{display} does not target rg-csh-dev "
        f"(got {variables.get('resourceGroup')!r})"
    )
if variables.get("location") != "newzealandnorth":
    fail(
        f"{display} does not target newzealandnorth "
        f"(got {variables.get('location')!r})"
    )

# The publish step must verify the generation it promised. A Gen1 image cannot
# boot this UEFI artifact, and the failure otherwise appears at VM create.
if not any("hyperVGeneration" in body(s) for s in steps):
    fail(f"{display} never checks the published image hyperVGeneration")

# The step that runs the build script is the one whose environment matters. Match
# a command, not a substring: a comment, or an echo whose argument happens to be
# the path, would otherwise satisfy the checks with prose. This is the repo's
# named anti-pattern, so the check tokenises the logical line the way the shell
# would, drops the comment, and requires the path to be in command position with
# sudo in front of it.
import shlex


def logical(text):
    return re.sub(r"\\\n\s*", " ", text)


def tokens(line):
    lex = shlex.shlex(line, posix=True, punctuation_chars="|;&")
    lex.whitespace_split = True
    lex.commenters = "#"
    return list(lex)


CONTROL = {"|", "||", "&&", ";", "&", ";;"}
SILENT = {"echo", "printf", "cat", "true"}


def invocation_of(line):
    """Return the tokens of the command that runs the script, or None."""
    toks = tokens(line)
    for i, tok in enumerate(toks):
        if tok != "./os/build-os-image.sh":
            continue
        prefix = []
        for back in reversed(toks[:i]):
            if back in CONTROL:
                break
            prefix.append(back)
        prefix.reverse()
        words = [w for w in prefix if not w.startswith("-") and "=" not in w]
        if "sudo" not in words or SILENT & set(words):
            continue
        return toks
    return None


candidates = [s for s in steps if "./os/build-os-image.sh" in logical(body(s))]
if not candidates:
    fail(f"{display} never names os/build-os-image.sh")

build = logical(body(candidates[0]))
build_tokens = invocation_of(build)
if build_tokens is None:
    fail(f"{display} never invokes os/build-os-image.sh as a command under sudo")

# sudo --preserve-env with an explicit list means everything not listed is dropped.
# AZURE_CONFIG_DIR is where AzureCLI@2 keeps the token, and HOME is the fallback
# the CLI uses when it is unset, so one of the two has to cross.
preserve = re.search(r"--preserve-env=([^\s\\]+)", build)
if not preserve:
    fail(f"{display} runs sudo without --preserve-env, so every exported variable is dropped")
kept = set(preserve.group(1).split(","))
if not kept & {"AZURE_CONFIG_DIR", "HOME"}:
    fail(
        f"{display} does not preserve AZURE_CONFIG_DIR or HOME through sudo, "
        f"so az runs as root with no credential and reports no login (kept: {sorted(kept)})"
    )

if "RG" not in kept:
    fail(f"{display} does not preserve RG through sudo, so the script refuses for a missing variable")
if "LOCATION" not in kept:
    fail(f"{display} does not preserve LOCATION through sudo, so the script uploads to the wrong region")
if "STORAGE_ACCOUNT" in kept or "STORAGE_ACCOUNT" in build:
    fail(f"{display} still names STORAGE_ACCOUNT, but that account is deleted")
PY

echo "OS pipeline targets rg-csh-dev, installs podman, pins the builder, and keeps credentials across sudo"
