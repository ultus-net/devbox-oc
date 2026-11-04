#!/usr/bin/env bash
# Regenerate os/butane/ucore.ign with the committed placeholder values.
#
# The committed Ignition document holds placeholders on purpose: it is a
# reviewable artifact, not a bootable one. A real install builds its own file and
# the build refuses placeholder values, so a forgotten edit fails before the USB
# is written. This keeps the artifact reproducible in CI.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$here/../.." && pwd)"

export ALLOW_PLACEHOLDERS=1
export IMAGE="ghcr.io/REPLACE_ME/devbox:prod"
export TS_AUTHKEY="tskey-auth-REPLACE_ME"
export SSH_PUBKEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl devbox-placeholder"

exec "$repo_root/os/butane/build.sh" "${1:-$here/ucore.ign}"
