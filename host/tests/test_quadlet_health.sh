#!/usr/bin/env bash
# host/tests/test_quadlet_health.sh
#
# The quadlet health command decides whether podman auto-update keeps a new
# image, so it must be the command the image installs, not one that only proves
# the binary runs. The files are static config, so the check parses both and ties
# them together: a change on either side fails here.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
quadlet="$root/host/quadlet/opencode.container"
dockerfile="$root/image/Dockerfile"
fail() { echo "FAIL: $1" >&2; exit 1; }

[ -s "$quadlet" ] || fail "no quadlet at $quadlet"
[ -s "$dockerfile" ] || fail "no Dockerfile at $dockerfile"

cmd="$(sed -n 's/^HealthCmd=//p' "$quadlet")"
[ -n "$cmd" ] || fail "the quadlet declares no HealthCmd"
bin="${cmd%% *}"

# A version probe answers "is the binary there", not "is it serving". That was
# the defect: a container that booted but served nothing reported healthy.
case "$cmd" in
  *--version*) fail "the health command only prints a version: $cmd" ;;
esac

case "$bin" in
  /usr/local/bin/*) ;;
  *) fail "the health command is not an absolute path under /usr/local/bin: $bin" ;;
esac

grep -q "COPY .* $bin\$" "$dockerfile" \
  || fail "the image does not install $bin, so the health check would always fail"

echo "the quadlet health command is the API probe the image installs"
