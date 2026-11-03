#!/usr/bin/env bash
# image/smoke.sh - asserts the image is fit to serve, not just to build.
set -euo pipefail
ref="${1:?usage: smoke.sh <image-ref> (env ENGINE, default podman)}"

ENGINE="${ENGINE:-podman}"

run() { "$ENGINE" run --rm --entrypoint "" "$ref" "$@"; }

# 1. The binary exists and runs on this base's libc.
run opencode --version | grep -q '^opencode v'

# 2. The dev user exists with the pinned uid, so bind mounts line up.
run id -u dev | grep -qx 1000

# 3. Runtime tools the agent needs are present.
for t in git jq rg fd curl; do run command -v "$t" >/dev/null; done

# 4. It does not run as root.
test "$("$ENGINE" image inspect "$ref" --format '{{.Config.User}}')" = "dev"

echo "smoke ok: $ref"
