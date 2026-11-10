#!/usr/bin/env bash
# Compile Butane to Ignition, substituting placeholders, then assert the output
# is Ignition rather than YAML wearing a .ign extension.
#
# local: paths in ucore.bu are relative to --files-dir, so that has to be the
# repo root. Butane rejects a path that escapes it (ErrFilesDirEscape).
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
: "${SSH_PUBKEY:?set SSH_PUBKEY to the public key of the operator}"
: "${TS_AUTHKEY:=}"
: "${IMAGE:?set IMAGE to the GHCR image reference}"
# The Hermes control plane is the official Nous Research image. It is the one
# non-Fedora container this repo allows; docs/design.md records the waiver.
: "${HERMES_IMAGE:=docker.io/nousresearch/hermes-agent:latest}"

# A keyless build ships no usable secret and the operator joins from the console
# after first boot. Say it loudly, because a typo in the variable name would
# otherwise produce keyless media by accident.
if [ -z "$TS_AUTHKEY" ]; then
  echo "KEYLESS build: no TS_AUTHKEY. The host stays off the tailnet until you" >&2
  echo "run tailscale up from the console after first boot." >&2
fi

OC_HOSTNAME="${OC_HOSTNAME:-devbox}"
UCORE_IMAGE="${UCORE_IMAGE:-ghcr.io/ublue-os/ucore-minimal:stable}"

# The placeholder build calls this script with dummy values so the committed
# artifact stays reproducible. A real build must never ship one by accident.
if [ "${ALLOW_PLACEHOLDERS:-0}" != "1" ]; then
  case "${TS_AUTHKEY}${IMAGE}${HERMES_IMAGE:-}" in
    *REPLACE_ME*|*placeholder*)
      echo "refusing to build with placeholder values" >&2
      exit 1
      ;;
  esac
fi

out="${1:-$here/ucore.ign}"
repo_root="$(cd "$here/../.." && pwd)"

work_bu="$here/.ucore.tmp.bu"
# Butane can only read local: files from inside the files dir, so each rendered
# quadlet is written next to the source first.
work_quadlet="$here/.opencode.container.ign.tmp"
work_hermes="$here/.hermes.container.ign.tmp"
work_network="$here/.devbox.network.ign.tmp"

sed -e "s|__SSH_PUBKEY__|${SSH_PUBKEY}|g" \
    -e "s|__OC_HOSTNAME__|${OC_HOSTNAME}|g" \
    -e "s|__TS_AUTHKEY__|${TS_AUTHKEY}|g" \
    -e "s|__UCORE_IMAGE__|${UCORE_IMAGE}|g" \
    -e "s|__IMAGE__|${IMAGE}|g" \
    "$here/ucore.bu" > "$work_bu"

sed -e "s|__IMAGE__|${IMAGE}|g" \
  "$repo_root/host/quadlet/opencode.container" > "$work_quadlet"

# The Hermes control plane runs the official image, which is not a Fedora build.
# It is the one non-Fedora container this repo allows; docs/design.md records the
# waiver. It still publishes on loopback only and still fails closed on secrets.
HERMES_IMAGE="${HERMES_IMAGE:-docker.io/nousresearch/hermes-agent:latest}"
sed -e "s|__HERMES_IMAGE__|${HERMES_IMAGE}|g" \
  "$repo_root/host/quadlet/hermes.container" > "$work_hermes"

# The shared network has no placeholders, but it is staged the same way so the
# local: path always resolves inside the files dir.
cp "$repo_root/host/quadlet/devbox.network" "$work_network"

# Compile to a temp file and move it into place only after the assertions pass. A
# redirection straight into "$out" truncates the committed Ignition before Butane
# runs, so a compile error would leave an empty file where a bootable one was.
staged="${out}.staged.$$"
trap 'rm -f "$work_bu" "$work_quadlet" "$work_hermes" "$work_network" "$staged"' EXIT

# The container path needs the repo mounted; the local binary path (BUTANE) is
# the same compiler version and the same flags, for a host with no podman.
if [ -n "${BUTANE:-}" ]; then
  "$BUTANE" --pretty --strict --files-dir "$repo_root" < "$work_bu" > "$staged"
else
  podman run --interactive --rm \
    --volume "${repo_root}:/work:ro" --workdir /work \
    quay.io/coreos/butane:release \
    --pretty --strict --files-dir /work \
    < "$work_bu" > "$staged"
fi

jq -e '.ignition.version' "$staged" >/dev/null || { echo "not valid ignition" >&2; exit 1; }
jq -e '.systemd.units | map(.name) | index("ucore-autorebase.service")' "$staged" >/dev/null \
  || { echo "autorebase unit missing" >&2; exit 1; }
jq -e '.systemd.units | map(.name) | index("var-srv.mount")' "$staged" >/dev/null \
  || { echo "var-srv.mount missing" >&2; exit 1; }
jq -e '.storage.files | map(.path) | index("/etc/containers/systemd/opencode.container")' \
  "$staged" >/dev/null || { echo "quadlet is not baked into the image" >&2; exit 1; }
jq -e '.storage.files | map(.path) | index("/etc/containers/systemd/hermes.container")' \
  "$staged" >/dev/null || { echo "hermes quadlet is not baked into the image" >&2; exit 1; }
jq -e '.storage.files | map(.path) | index("/etc/containers/systemd/devbox.network")' \
  "$staged" >/dev/null || { echo "shared network is not baked into the image" >&2; exit 1; }
# A forgotten substitution ships a unit that cannot run. Catch it before the USB.
if jq -r '.. | strings' "$staged" | grep -qE '__[A-Z_]+__'; then
  echo "unsubstituted placeholder remains in the compiled Ignition" >&2
  exit 1
fi
chmod 0644 "$staged"
mv "$staged" "$out"
echo "ignition ok: $out"
