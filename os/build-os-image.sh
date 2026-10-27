#!/usr/bin/env bash
# Turn the published ucore bootc image into an Azure managed image.
#
# Fedora publishes an Azure VHD for plain CoreOS, and ucore publishes none. Booting
# plain CoreOS gives a host this repo's Ignition does not match: no tailscaled
# package, no ucore podman autostart contract, and zincati in place of ucore's
# update path. Every host unit assumes ucore, so the image has to be built from it.
#
# image-builder produces a disk image from any bootc image, which is the supported
# way to get ucore onto Azure without forking it (design decision 1). The source is
# pinned by digest, so a rebuild is reproducible and a bump is deliberate.
set -euo pipefail

# Digest from the design's verified-facts table (ucore-minimal stable). Bumping it
# rolls every VM, so it is a reviewed change, not a routine refresh.
UCORE_IMAGE="${UCORE_IMAGE:-ghcr.io/ublue-os/ucore@sha256:7906a70efe7482704fdb232c7e5d2a3068a0c5520ef46d3f7f6b9f8fc0e899b9}"
# Pinned by digest, not `:latest`. The pipeline runs weekly on a cron, so a moving
# tag would swap the builder underneath an unchanged config and make the published
# image non-reproducible with nothing in the diff to review.
IMAGE_BUILDER="${IMAGE_BUILDER:-ghcr.io/osbuild/image-builder-cli@sha256:37b7c22483b03013f54030094683d8af8a83ee642c2a4dc9a51dcd9a79be6b6f}"
RG="${RG:?RG is required}"
STORAGE_ACCOUNT="${STORAGE_ACCOUNT:?STORAGE_ACCOUNT is required}"
CONTAINER="${CONTAINER:-images}"
LOCATION="${LOCATION:-westeurope}"
DRY_RUN="${DRY_RUN:-0}"

command -v podman >/dev/null || { echo "podman not installed; image-builder needs a privileged container" >&2; exit 1; }
command -v az >/dev/null || { echo "az not installed" >&2; exit 1; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

echo "building a vhd from ${UCORE_IMAGE}" >&2
vhd=""
if [ "$DRY_RUN" != "1" ]; then
  mkdir -p "$work/output"
  # --privileged and the container-storage mount are what image-builder documents
  # for its container path: it needs to mount loop devices and read the source
  # image out of the same storage it runs from.
  podman run --rm --privileged \
    --security-opt label=type:unconfined_t \
    --volume "$work/output:/output" \
    --volume /var/lib/containers/storage:/var/lib/containers/storage \
    "$IMAGE_BUILDER" build \
    --output-dir /output \
    --bootc-ref "$UCORE_IMAGE" \
    vhd
  vhd="$(find "$work/output" -name '*.vhd' -print -quit)"
  [ -f "$vhd" ] || { echo "no vhd produced" >&2; exit 1; }
  # Provenance next to the artifact. This is what an auditor asks for.
  sha256sum "$vhd" | tee "$vhd.sha256" >&2
fi

name="devbox-ucore-$(date -u +%Y%m%d)"
blob="${name}.vhd"

if [ "$DRY_RUN" = "1" ]; then
  echo "dry run: would build ${UCORE_IMAGE} and upload to ${STORAGE_ACCOUNT}/${CONTAINER} as ${blob}"
  echo "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/${RG}/providers/Microsoft.Compute/images/${name}"
  exit 0
fi

az storage blob upload --account-name "$STORAGE_ACCOUNT" -c "$CONTAINER" \
  -f "$vhd" -n "$blob" --overwrite --only-show-errors
# Gen2: image-builder emits a UEFI layout with an ESP, so the VM must be Gen2.
az image create -g "$RG" -n "$name" --location "$LOCATION" --os-type Linux \
  --hyper-v-generation V2 \
  --source "https://${STORAGE_ACCOUNT}.blob.core.windows.net/${CONTAINER}/${blob}" \
  --only-show-errors -o none

az image show -g "$RG" -n "$name" --query id -o tsv
