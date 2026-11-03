#!/usr/bin/env bash
# Regenerate os/butane/ucore.ign with the committed placeholder values.
#
# The committed Ignition doc holds placeholders on purpose: Terraform's
# precondition refuses to plan against it, so a forgotten regeneration fails at
# plan time instead of booting a VM with a dummy SSH key. This script keeps that
# property while letting the quadlet and unit text stay reviewable in git.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$here/../.." && pwd)"

export VAULT_NAME="kv-devbox-placeholder"
export ACR_NAME="acrdevboxplaceholder"
export DISK_ID="dc-placeholder"
export RG="rg-devbox-placeholder"
export SUBSCRIPTION_ID="00000000-0000-0000-0000-000000000000"
export SSH_PUBKEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl devbox-placeholder"

exec "$repo_root/os/butane/build.sh" "${1:-$here/ucore.ign}"
