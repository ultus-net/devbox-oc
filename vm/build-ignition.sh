#!/usr/bin/env bash
# Build the VM Ignition: the real repo build, then the harness overlay.
#
# The base Ignition is compiled from os/butane/ucore.bu by the repo's own
# build.sh, so the VM exercises the shipped config. Nothing here writes the
# committed os/butane/ucore.ign artifact.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
cache="${VM_CACHE:-$repo_root/.vm-cache}"
image="${VM_IMAGE:-ghcr.io/ultus-net/devbox:prod}"
hostname="${VM_HOSTNAME:-devbox-vm}"

command -v jq >/dev/null || { echo "jq is required" >&2; exit 1; }
command -v ssh-keygen >/dev/null || { echo "ssh-keygen is required" >&2; exit 1; }

mkdir -p "$cache"

# A throwaway key for the VM console/SSH door. It is never a real credential and
# it lives in the ignored cache, never in the repository.
key="$cache/id_ed25519"
if [ ! -s "$key" ]; then
  ssh-keygen -q -t ed25519 -N '' -C devbox-vm-dogfood -f "$key"
fi

butane="${BUTANE:-}"
if [ -z "$butane" ]; then
  if [ -x "$repo_root/.tools/butane" ]; then
    butane="$repo_root/.tools/butane"
  elif command -v butane >/dev/null 2>&1; then
    butane="$(command -v butane)"
  fi
fi
if [ -z "$butane" ]; then
  echo "butane is required: set BUTANE or install it on PATH" >&2
  exit 1
fi

base="$cache/devbox-vm-base.ign"
out="$cache/devbox-vm.ign"

# The fixture and the published rehearsal both boot an image the record does not
# name, so the harness asks the pin to stand down. It is loud on stderr, and the
# shipped build never sets it: design decision 15 records why the rehearsal
# needs the escape.
ALLOW_UNPINNED_IMAGE=1 \
SSH_PUBKEY="$(cat "$key.pub")" \
TS_AUTHKEY="" \
OC_HOSTNAME="$hostname" \
IMAGE="$image" \
BUTANE="$butane" \
  "$repo_root/os/butane/build.sh" "$base" >&2

VM_AGENT_URL="${VM_AGENT_URL:-http://10.0.2.2:8123}" \
VM_HOSTNAME="$hostname" \
VM_IMAGE="$image" \
  "$here/overlay-ignition.sh" "$base" "$out" >&2

printf '%s\n' "$out"
