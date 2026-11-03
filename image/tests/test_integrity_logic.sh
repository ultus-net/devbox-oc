#!/usr/bin/env bash
# Verify the Dockerfile's integrity-check logic without a container engine.
# The Dockerfile decodes the base64 sha512 to hex, then compares it against a
# sha512 of the downloaded tarball. This runs exactly that sequence.
#
# Why this exists: the image cannot be built on a machine with no usable
# container engine, but the integrity check is the load-bearing part of the
# build. This proves it without Docker or Podman.
set -euo pipefail

cleanup() { rm -f "${temp_tarball:-}" "${corrupt:-}"; }
trap cleanup EXIT

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

oc_version="$(sed -n 's/^ARG OC_VERSION=//p' "$repo_root/image/Dockerfile" | head -1)"
[ -n "$oc_version" ] || { echo "cannot read OC_VERSION from Dockerfile" >&2; exit 1; }

OC_SHA512='o8EJ0ZsT4dzDKN+0mpG2EKbNGzJyp+F1++Av28UReRVfiEv+N34eZEnN/unkiMoerKHad6W6Ii7k4ukTnPNmNQ=='

check() {
  local digest="$1" file="$2" expected actual
  expected="$(printf '%s' "$digest" | base64 -d | od -An -tx1 | tr -d ' \n')"
  actual="$(sha512sum "$file" | cut -d' ' -f1)"
  [ "$actual" = "$expected" ]
}

miss() {
  echo "integrity check could not run: $1" >&2
  if [ "${ALLOW_INTEGRITY_SKIP:-0}" = "1" ]; then
    echo "ALLOW_INTEGRITY_SKIP=1, skipping" >&2
    exit 0
  fi
  echo "set ALLOW_INTEGRITY_SKIP=1 to skip explicitly, or fetch the tarball" >&2
  exit 1
}

# An explicit argument is authoritative: a typo must fail, never be replaced.
if [ -n "${1:-}" ]; then
  [ -f "$1" ] || { echo "no such file: $1" >&2; exit 1; }
  tarball="$1"
else
  tarball="${CACHED_TARBALL:-/tmp/ocinspect/oc.tgz}"
  if [ ! -f "$tarball" ]; then
    if command -v curl >/dev/null 2>&1; then
      temp_tarball="$(mktemp)"
      if curl -fsSL --retry 3 --output "$temp_tarball" \
        "https://registry.npmjs.org/@opencode/cli-linux-x64/-/cli-linux-x64-${oc_version}.tgz"; then
        tarball="$temp_tarball"
      else
        miss "no cached tarball and download failed"
      fi
    else
      miss "no cached tarball and no curl"
    fi
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
