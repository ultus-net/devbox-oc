#!/usr/bin/env bash
# Verify the Dockerfile's integrity-check logic without a container engine.
# The Dockerfile decodes the base64 sha512 to hex, then compares it against a
# sha512sum of the downloaded tarball. This runs exactly that sequence.
#
# Why this exists: the image cannot be built on a machine with no usable
# container engine, but the integrity check is the load-bearing part of the
# build. This proves it without Docker or Podman.
set -euo pipefail

OC_SHA512='o8EJ0ZsT4dzDKN+0mpG2EKbNGzJyp+F1++Av28UReRVfiEv+N34eZEnN/unkiMoerKHad6W6Ii7k4ukTnPNmNQ=='
tarball="${1:-/tmp/ocinspect/oc.tgz}"

[ -f "$tarball" ] || { echo "missing tarball: $tarball" >&2; exit 1; }

expected="$(printf '%s' "$OC_SHA512" | base64 -d | od -An -tx1 | tr -d ' \n')"
actual="$(sha512sum "$tarball" | cut -d' ' -f1)"

echo "expected: $expected"
echo "actual:   $actual"

if [ "$actual" = "$expected" ]; then
  echo "integrity check PASSES"
else
  echo "integrity check FAILS" >&2
  exit 1
fi

# Negative control: a corrupted tarball must not match.
corrupt="$(mktemp)"
trap 'rm -f "$corrupt"' EXIT
cp "$tarball" "$corrupt"
printf 'x' >> "$corrupt"
if [ "$(sha512sum "$corrupt" | cut -d' ' -f1)" = "$expected" ]; then
  echo "negative control FAILED: corrupted input still matched" >&2
  exit 1
fi
echo "negative control passes: corruption is detected"
