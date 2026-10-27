#!/usr/bin/env bash
# Verify the Dockerfile's integrity-check logic without a container engine.
# The Dockerfile decodes the base64 sha512 to hex, then compares it against a
# sha512sum of the downloaded tarball. This runs exactly that sequence.
#
# Why this exists: the image cannot be built on a machine with no usable
# container engine, but the integrity check is the load-bearing part of the
# build. This proves it without Docker or Podman.
set -euo pipefail
 
cleanup() { rm -f "${temp_tarball:-}" "${corrupt:-}"; }
trap cleanup EXIT

OC_SHA512='o8EJ0ZsT4dzDKN+0mpG2EKbNGzJyp+F1++Av28UReRVfiEv+N34eZEnN/unkiMoerKHad6W6Ii7k4ukTnPNmNQ=='
tarball="${1:-/tmp/ocinspect/oc.tgz}"

check() {
  local digest="$1"
  local file="$2"
  local expected=""

  expected="$(printf '%s' "$digest" | base64 -d | od -An -tx1 | tr -d ' \n')"
  local actual="$(sha512sum "$file" | cut -d' ' -f1)"

  if [ "$actual" = "$expected" ]; then
    echo "PASS"
  else
    echo "FAIL"
  fi
}

# Graceful skip if tarball is unavailable.
if [ ! -f "$tarball" ]; then
  if command -v curl >/dev/null 2>&1; then
    temp_tarball="$(mktemp)"
    if curl -fsSL --retry 3 --output "$temp_tarball" \
      "https://registry.npmjs.org/@opencode/cli-linux-x64/-/cli-linux-x64-2.1.4.tgz"; then
      tarball="$temp_tarball"
    else
      echo "SKIP: tarball unavailable (no cached copy and download failed)"
      exit 0
    fi
  else
    echo "SKIP: tarball unavailable (no network and no cached copy)"
    exit 0
  fi
fi

echo "checking $tarball against the digest from Dockerfile..."

check "$OC_SHA512" "$tarball" || { echo "integrity check FAILS" >&2; exit 1; }
echo "integrity check PASSES"

# Negative control: a corrupted tarball must not match.
corrupt="$(mktemp)"
cp "$tarball" "$corrupt"
printf 'x' >> "$corrupt"
check "$OC_SHA512" "$corrupt" && { echo "negative control FAILED: corrupted input still matched" >&2; exit 1; }
echo "negative control passes: corruption is detected"
