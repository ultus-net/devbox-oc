#!/usr/bin/env bash
# image/tests/test_base_pin.sh
#
# The base is consumed by digest, because a tag is not a version signal (see
# docs/design.md decision 12). The gate is offline, so this checks the pin shape
# and the build's use of it, not the tag the digest came from.
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
dockerfile="$here/Dockerfile"
fail() { echo "FAIL: $1" >&2; exit 1; }

[ -s "$dockerfile" ] || fail "no Dockerfile at $dockerfile"

# Count declarations before parsing, so a bare ARG BASE or a trailing = cannot
# hide behind a count that only sees assignments.
declared="$(grep -cE '^[[:space:]]*ARG[[:space:]]+BASE([[:space:]]|=|$)' "$dockerfile" || true)"
[ "$declared" = "1" ] || fail "the Dockerfile declares ARG BASE $declared times"

base="$(sed -n 's/^[[:space:]]*ARG[[:space:]]*BASE=//p' "$dockerfile")"
[ -n "$base" ] || fail "the Dockerfile declares no ARG BASE with a value"

case "$base" in
  registry.fedoraproject.org/fedora-toolbox@sha256:*) ;;
  *) fail "the base is not the Fedora toolbox image by digest: $base" ;;
esac
printf '%s' "${base##*@sha256:}" | grep -qE '^[0-9a-f]{64}$' \
  || fail "the base digest is not 64 lowercase hex characters: $base"

# The pin must be the image the build starts from, not a leftover argument. One
# stage only, so a second FROM cannot pull something else in beside it.
stages="$(grep -c '^FROM ' "$dockerfile" || true)"
[ "$stages" = "1" ] || fail "the Dockerfile has $stages FROM lines; this guard expects one"

from_line="$(grep -m1 '^FROM ' "$dockerfile")"
[ "$from_line" = "FROM \${BASE}" ] \
  || fail "the Dockerfile does not build FROM the pinned base: $from_line"

echo "the toolbox base is pinned by digest to a Fedora image"
