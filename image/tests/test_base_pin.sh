#!/usr/bin/env bash
# image/tests/test_base_pin.sh
#
# The toolbox base is consumed by digest, and the tag it came from is not a
# version signal: the 46 tag is labelled rawhide while 45 is the released
# stream. A repin to a tag would read as reviewed and then move underneath the
# build, so the pin shape is checked here.
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
dockerfile="$here/Dockerfile"
fail() { echo "FAIL: $1" >&2; exit 1; }

[ -s "$dockerfile" ] || fail "no Dockerfile at $dockerfile"

base="$(sed -n 's/^ARG BASE=//p' "$dockerfile")"
[ -n "$base" ] || fail "the Dockerfile declares no ARG BASE"
count="$(printf '%s\n' "$base" | grep -c . || true)"
[ "$count" = "1" ] || fail "the Dockerfile declares ARG BASE $count times"

case "$base" in
  registry.fedoraproject.org/fedora-toolbox@sha256:*) ;;
  *) fail "the base is not the Fedora toolbox image by digest: $base" ;;
esac
printf '%s' "${base##*@sha256:}" | grep -qE '^[0-9a-f]{64}$' \
  || fail "the base digest is not 64 lowercase hex characters: $base"

# The pin must be the image the build starts from, not a leftover argument.
from_line="$(grep -m1 '^FROM ' "$dockerfile")"
[ "$from_line" = "FROM \${BASE}" ] \
  || fail "the Dockerfile does not build FROM the pinned base: $from_line"

echo "the toolbox base is pinned by digest to a Fedora image"
