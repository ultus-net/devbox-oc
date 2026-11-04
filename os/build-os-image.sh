#!/usr/bin/env bash
# Build an Azure VHD from the ucore bootc container image, upload it to a managed
# disk, and create a managed image.
#
# Neither Fedora nor ucore publishes an Azure VHD. Building one from the bootc
# container is what lets the VM boot ucore directly: one boot, no rebase, no
# marker files, no second and third reboot. An earlier design published plain
# Fedora CoreOS and rebased it onto ucore at boot, which needed a bare-metal
# install recipe applied to a cloud image. This replaces that.
#
# The container is pinned by digest. A tag moves, and a moving tag makes the
# published image unreproducible, so a tag is refused rather than resolved.
set -euo pipefail

# Pinned from the design's verified facts. Change deliberately, not incidentally.
UCORE_IMAGE="${UCORE_IMAGE:-ghcr.io/ublue-os/ucore-minimal@sha256:7906a70efe7482704fdb232c7e5d2a3068a0c5520ef46d3f7f6b9f8fc0e899b9}"
DRY_RUN="${DRY_RUN:-0}"
# Fedora bootable containers do not declare a root filesystem, so image-builder
# refuses to build one without this. ext4 is what Azure expects.
BUILD_FS="${BUILD_FS:-ext4}"

# The dry run exists so an operator can see the image id it would create before a
# resource group or managed disk exists. Checking those first would make the
# documented command fail, so the dry run answers before any of them are required.
if [ "$DRY_RUN" = "1" ]; then
  # No external command here on purpose. The dry run must work on a machine with
  # nothing installed yet, which is where the operator sees it first.
  echo "dry run: would build a vhd from ${UCORE_IMAGE} with image-builder, then upload it to a managed disk in ${RG:-rg-csh-dev} (${LOCATION:-newzealandnorth})"
  echo "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/<rg>/providers/Microsoft.Compute/images/devbox-ucore-<yyyymmdd>"
  exit 0
fi

RG="${RG:-rg-csh-dev}"
LOCATION="${LOCATION:-newzealandnorth}"

# A tag is not a pin. Accepting one here would publish a different OS on a later
# run while the pipeline reported success and the hash described another image.
# The digest is required in full: `@sha256:` with nothing after it would pass a
# prefix test and resolve to whatever the registry served. Pure bash, because the
# precondition cases below run with a stripped PATH that has no grep.
if [[ ! "$UCORE_IMAGE" =~ @sha256:[0-9a-f]{64}$ ]]; then
  echo "UCORE_IMAGE must be pinned by digest (@sha256:<64 hex>), not a tag: $UCORE_IMAGE" >&2
  exit 1
fi

# Two ways to run the builder. A Fedora host installs the binary; a CI runner on
# another distribution has no package, so it runs the pinned container instead.
# One of the two must be available, or the build below fails obscurely.
if [ -z "${IMAGE_BUILDER_CONTAINER:-}" ]; then
  command -v image-builder >/dev/null \
    || { echo "image-builder not installed and IMAGE_BUILDER_CONTAINER unset; see docs/runbook.md" >&2; exit 1; }
fi
command -v podman >/dev/null || { echo "podman not installed" >&2; exit 1; }
command -v az >/dev/null || { echo "az not installed" >&2; exit 1; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# image-builder reads bootc refs from local container storage, never from a
# registry, so the pull has to happen first or the build fails looking for it.
echo "pulling ${UCORE_IMAGE}" >&2
podman pull "$UCORE_IMAGE"

echo "building a vhd from ${UCORE_IMAGE}" >&2
# The container runs privileged because building a disk needs loop devices and
# mount. It shares the host's container storage so the --bootc-ref pulled above
# is visible; image-builder reads refs from local storage and never from a
# registry. --output-name keeps the artifact name predictable, because the
# default template embeds a distribution identifier a bootc build does not have.
if [ -n "${IMAGE_BUILDER_CONTAINER:-}" ]; then
  podman run --rm --privileged --security-opt label=type:unconfined_t \
    --volume "${work}:/output" \
    --volume /var/lib/containers/storage:/var/lib/containers/storage \
    "$IMAGE_BUILDER_CONTAINER" \
    build --bootc-ref "$UCORE_IMAGE" --bootc-default-fs "$BUILD_FS" \
    --output-dir /output --output-name ucore vhd
else
  image-builder build --bootc-ref "$UCORE_IMAGE" --bootc-default-fs "$BUILD_FS" \
    --output-dir "$work" --output-name ucore vhd
fi

# Exactly one artifact, or the upload would silently ship an arbitrary file. A
# second .vhd means the build output is not what this script assumes.
mapfile -t vhds < <(find "$work" -name '*.vhd')
[ "${#vhds[@]}" -eq 1 ] || {
  echo "expected exactly one vhd, found ${#vhds[@]}: ${vhds[*]:-none}" >&2
  exit 1
}
vhd="${vhds[0]}"

# Provenance next to the artifact. This is what an auditor asks for. It is printed
# rather than written into $work, which the EXIT trap deletes, so the operator
# keeps the hash without this script leaving a file behind.
sha256sum "$vhd" >&2

name="devbox-ucore-$(date -u +%Y%m%d)"
disk="${name}-disk"
# The upload size is the artifact's exact byte count, including the VHD footer.
# A hardcoded value would either pad the disk or truncate the upload.
vhd_size="$(wc -c < "$vhd" | tr -d '[:space:]')"

# No storage account is created or named. The disk is the upload target, and the
# SAS from grant-access carries the credential.
az disk create -g "$RG" -n "$disk" -l "$LOCATION" --os-type Linux \
  --hyper-v-generation V2 --upload-type Upload \
  --upload-size-bytes "$vhd_size" --sku StandardSSD_LRS \
  --only-show-errors -o none

sas="$(az disk grant-access -g "$RG" -n "$disk" --access-level Write \
  --duration-in-seconds 3600 --query accessSas -o tsv)"

# Storage API upload to the disk's staging blob. The CLI defaults to a page blob
# for a .vhd, and chunks the transfer, so a multi-GiB artifact stays well inside
# the single-request limit. A failed upload leaves the staging disk billing until
# someone deletes it, so the failure path names it.
if ! az storage blob upload --blob-url "$sas" --file "$vhd" --type page \
  --overwrite --only-show-errors -o none; then
  echo "upload failed; staging disk ${disk} in ${RG} remains until deleted" >&2
  exit 1
fi

# Until access is revoked the disk cannot be used as an image source.
az disk revoke-access -g "$RG" -n "$disk" --only-show-errors -o none

az image create -g "$RG" -n "$name" --location "$LOCATION" --os-type Linux \
  --hyper-v-generation V2 \
  --source "$(az disk show -g "$RG" -n "$disk" --query id -o tsv)" \
  --only-show-errors -o none

# The image holds its own copy, so the staging disk is safe to delete once the
# image exists. Print its name rather than deleting it here: cleanup stays an
# explicit operator step.
echo "staging disk ${disk} in ${RG} can be deleted after the image is verified" >&2

az image show -g "$RG" -n "$name" --query id -o tsv
