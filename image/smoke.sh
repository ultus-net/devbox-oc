#!/usr/bin/env bash
# image/smoke.sh - asserts the image is fit to serve, not just to build.
set -euo pipefail
ref="${1:?usage: smoke.sh <image-ref> (env ENGINE, default podman; SMOKE_OC_VERSION required)}"

ENGINE="${ENGINE:-podman}"
# Required, not optional: an unset pin silently accepted any version before, and
# that is the defect this gate exists to close.
want_version="${SMOKE_OC_VERSION:?set SMOKE_OC_VERSION to the OC_VERSION pin in image/Dockerfile}"
name="devbox-smoke-$$"
port="${SMOKE_PORT:-$((20000 + RANDOM % 20000))}"

fail() { echo "FAIL: $1" >&2; exit 1; }
run() { "$ENGINE" run --rm --entrypoint "" "$ref" "$@"; }
cleanup() { "$ENGINE" rm -f "$name" >/dev/null 2>&1 || true; }
trap cleanup EXIT

# 1. The binary exists, runs on this base's libc, and is the version the
#    Dockerfile pins. A mismatch means the artifact moved without a bump.
got="$(run opencode --version | awk '{print $NF}')"
printf '%s\n' "$got" | grep -qE '^v[0-9]+\.[0-9]+\.[0-9]+$' \
  || fail "opencode --version printed no version: ${got:-nothing}"
[ "$got" = "v${want_version}" ] || fail "opencode is $got, the Dockerfile pins v${want_version}"

# 2. The dev user exists with the pinned uid, so bind mounts line up.
run id -u dev | grep -qx 1000

# 3. Runtime tools the agent needs are present. `which` is an executable; a shell
# builtin such as `command` is not something the engine can exec.
for t in git jq rg fd curl restic; do run which "$t" >/dev/null; done

# 4. It does not run as root.
test "$("$ENGINE" image inspect "$ref" --format '{{.Config.User}}')" = "dev" \
  || fail "the image runs as root"

# 5. The serve path answers and the health command agrees with it. A container
#    that boots but serves nothing is the failure auto-update would otherwise
#    keep, and `--version` cannot see it.
command -v curl >/dev/null || fail "curl is required on the runner"
"$ENGINE" run -d --name "$name" -p "127.0.0.1:${port}:4096" "$ref" >/dev/null
code=""
for _ in $(seq 1 30); do
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "http://127.0.0.1:${port}/api/info" || true)"
  [ "$code" = "401" ] && break
  sleep 2
done
[ "$code" = "401" ] \
  || fail "the server did not answer 401 on /api/info within 60s (last: ${code:-none})"
"$ENGINE" exec "$name" /usr/local/bin/devbox-health \
  || fail "the health command rejects a container that serves"
if "$ENGINE" exec "$name" env HEALTH_URL=http://127.0.0.1:1/api/info \
  /usr/local/bin/devbox-health; then
  fail "the health command accepts a container that serves nothing"
fi

echo "smoke ok: $ref"
