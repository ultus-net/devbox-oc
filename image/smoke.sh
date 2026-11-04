#!/usr/bin/env bash
# image/smoke.sh - asserts the image is fit to serve, not just to build.
set -euo pipefail
ref="${1:?usage: smoke.sh <image-ref> (env ENGINE, default podman)}"

ENGINE="${ENGINE:-podman}"

run() { "$ENGINE" run --rm --entrypoint "" "$ref" "$@"; }

# 1. The binary exists and runs on this base's libc. Accept either the bare
# version string or a prefix, so an output format change does not fail the gate.
run opencode --version | grep -qE '[0-9]+\.[0-9]+\.[0-9]+'

# 2. The dev user exists with the pinned uid, so bind mounts line up.
run id -u dev | grep -qx 1000

# 3. Runtime tools the agent needs are present. `which` is an executable; a shell
# builtin such as `command` is not something the engine can exec.
for t in git jq rg fd curl restic; do run which "$t" >/dev/null; done

# 4. It does not run as root.
test "$("$ENGINE" image inspect "$ref" --format '{{.Config.User}}')" = "dev"

echo "smoke ok: $ref"
