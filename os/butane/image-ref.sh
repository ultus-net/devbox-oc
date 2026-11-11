#!/usr/bin/env bash
# os/butane/image-ref.sh
#
# Resolve the image reference the Ignition pins.
#
# The installed host runs one digest, not a tag. Podman verifies what it pulls
# against that digest, so a moved :prod cannot change what the box boots. The
# digest comes from image/prod-digest.txt, the record a promotion moves through a
# reviewed PR.
#
# Usage: image-ref.sh [<image-ref>]
#   (no argument)     the default repository at the recorded digest
#   <repo>            that repository at the recorded digest
#   <repo>@sha256:..  that digest, when it is the recorded one
#   <repo>:<tag>      refused, because a tag can move after the media is written
#
# ALLOW_UNPINNED_IMAGE=1 accepts a tag or an unrecorded digest. The VM harness
# sets it for the fixture image and build-placeholder.sh sets it for the
# non-bootable artifact; a real build never does.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
record="${PROD_DIGEST_FILE:-$here/../../image/prod-digest.txt}"
default_repo="ghcr.io/ultus-net/devbox"
allow_unpinned="${ALLOW_UNPINNED_IMAGE:-0}"
fail() { echo "FAIL: $1" >&2; exit 1; }

ref="${1:-$default_repo}"
case "$ref" in
  *[[:space:]]*) fail "the image reference holds whitespace: $ref" ;;
esac

# The last path segment carries the tag or digest; the registry host and its
# port sit before a slash, so 127.0.0.1:5000/devbox:newer is a tag.
last="${ref##*/}"
if [ "$last" != "${last#*@sha256:}" ]; then
  form=digest
  digest="sha256:${last##*@sha256:}"
elif [ "$last" != "${last%%:*}" ]; then
  form=tag
else
  form=bare
fi

# Everything before the tag or digest is the repository. An empty component
# there produces a reference podman cannot pull, so refuse it before a boot
# config is written rather than at first start.
name="$ref"
case "$form" in
  digest) name="${ref%%@*}" ;;
  tag) name="${ref%:*}" ;;
esac
case "$name" in
  "") fail "the image reference names no repository: $ref" ;;
  */) fail "the image reference ends in a slash: $ref" ;;
  *//*) fail "the image reference has an empty path component: $ref" ;;
esac

recorded=""
if [ -s "$record" ]; then
  count="$(grep -cE '^sha256:[0-9a-f]{64}$' "$record" || true)"
  [ "$count" -le 1 ] || fail "the digest record holds $count digests: $record"
  if [ "$count" -eq 1 ]; then
    recorded="$(grep -E '^sha256:[0-9a-f]{64}$' "$record")"
  fi
fi

case "$form" in
  digest)
    printf '%s' "${digest#sha256:}" | grep -qE '^[0-9a-f]{64}$' \
      || fail "the image digest is not 64 hex characters: $ref"
    if [ -z "$recorded" ]; then
      [ "$allow_unpinned" = 1 ] || fail "the record holds no promoted digest: $record"
      echo "WARNING: unpinned image $ref (ALLOW_UNPINNED_IMAGE=1)" >&2
    elif [ "$digest" != "$recorded" ]; then
      [ "$allow_unpinned" = 1 ] || fail "the image pins $digest but the record holds $recorded"
      echo "WARNING: $ref is not the recorded digest (ALLOW_UNPINNED_IMAGE=1)" >&2
    fi
    printf '%s\n' "$ref"
    ;;
  tag)
    [ "$allow_unpinned" = 1 ] \
      || fail "refusing the tag reference $ref: the host runs a digest, not a tag"
    echo "WARNING: unpinned image $ref (ALLOW_UNPINNED_IMAGE=1)" >&2
    printf '%s\n' "$ref"
    ;;
  bare)
    [ -n "$recorded" ] \
      || fail "no promoted digest to pin: $record holds none, so record the build first"
    printf '%s@%s\n' "$ref" "$recorded"
    ;;
esac
