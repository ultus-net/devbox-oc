#!/usr/bin/env bash
# Compile Butane to Ignition, substituting placeholders, then assert the output
# is Ignition rather than YAML wearing a .ign extension.
#
# local: paths in ucore.bu are relative to --files-dir, so that has to be the
# repo root. Butane rejects a path that escapes it (ErrFilesDirEscape).
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
: "${VAULT_NAME:?}" "${ACR_NAME:?}" "${DISK_ID:?}" "${RG:?}" "${SUBSCRIPTION_ID:?}" "${SSH_PUBKEY:?}"
out="${1:-$here/ucore.ign}"
repo_root="$(cd "$here/../.." && pwd)"

work_bu="$here/.ucore.tmp.bu"
# The quadlet carries __ACR__ too, and Butane can only read local: files from
# inside the files dir, so render it next to the source first.
work_quadlet="$here/.opencode.container.ign.tmp"
trap 'rm -f "$work_bu" "$work_quadlet"' EXIT

sed -e "s|__VAULT_NAME__|${VAULT_NAME}|g" \
    -e "s|__ACR_NAME__|${ACR_NAME}|g" \
    -e "s|__ACR__|${ACR_NAME}|g" \
    -e "s|__DISK_ID__|${DISK_ID}|g" \
    -e "s|__RG__|${RG}|g" \
    -e "s|__SUBSCRIPTION_ID__|${SUBSCRIPTION_ID}|g" \
    -e "s|__SSH_PUBKEY__|${SSH_PUBKEY}|g" \
    "$here/ucore.bu" > "$work_bu"

sed -e "s|__ACR__|${ACR_NAME}|g" \
  "$repo_root/host/quadlet/opencode.container" > "$work_quadlet"

# The container path needs the repo mounted; the local binary path (BUTANE) is
# the same compiler version and the same flags, for a host with no podman.
if [ -n "${BUTANE:-}" ]; then
  "$BUTANE" --pretty --strict --files-dir "$repo_root" < "$work_bu" > "$out"
else
  podman run --interactive --rm \
    --volume "${repo_root}:/work:ro" --workdir /work \
    quay.io/coreos/butane:release \
    --pretty --strict --files-dir /work \
    < "$work_bu" > "$out"
fi

jq -e '.ignition.version' "$out" >/dev/null || { echo "not valid ignition" >&2; exit 1; }
jq -e '.systemd.units | map(.name) | index("oc-idle.timer")' "$out" >/dev/null \
  || { echo "idle timer missing" >&2; exit 1; }
jq -e '.storage.files | map(.path) | index("/etc/containers/systemd/opencode.container")' \
  "$out" >/dev/null || { echo "quadlet is not baked into the image" >&2; exit 1; }
echo "ignition ok: $out"
