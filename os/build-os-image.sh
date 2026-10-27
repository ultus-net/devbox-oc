#!/usr/bin/env bash
# Download the Fedora CoreOS Azure VHD, upload it, and create a managed image.
# Fedora publishes no CoreOS image in the Azure marketplace, so this step exists.
set -euo pipefail

STREAM="${STREAM:-stable}"
DRY_RUN="${DRY_RUN:-0}"
CONTAINER="${CONTAINER:-images}"
LOCATION="${LOCATION:-westeurope}"

# The dry run exists so an operator can see the image id it would create before
# a resource group or storage account exists. Checking those first would make the
# documented command fail, so the dry run answers before any of them are required.
if [ "$DRY_RUN" = "1" ]; then
  # No external command here on purpose. The dry run must work on a machine with
  # nothing installed yet, which is where the operator sees it first.
  name="devbox-fcos-${STREAM}-<yyyymmdd>"
  echo "dry run: would upload a FCOS ${STREAM} vhd to <storage-account>/${CONTAINER} as ${name}.vhd"
  echo "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/<rg>/providers/Microsoft.Compute/images/${name}"
  exit 0
fi

RG="${RG:?RG is required}"
STORAGE_ACCOUNT="${STORAGE_ACCOUNT:?STORAGE_ACCOUNT is required}"

command -v coreos-installer >/dev/null || { echo "coreos-installer not installed; see docs/runbook.md" >&2; exit 1; }
command -v az >/dev/null || { echo "az not installed" >&2; exit 1; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

echo "downloading FCOS ${STREAM} azure vhd" >&2
coreos-installer download --decompress --stream "$STREAM" --platform azure \
  --format vhd.xz --directory "$work"

# Exactly one artifact, or the upload would silently ship an arbitrary file. A
# second .vhd means the download directory is not what this script assumes.
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

name="devbox-fcos-${STREAM}-$(date -u +%Y%m%d)"
blob="${name}.vhd"

az storage blob upload --account-name "$STORAGE_ACCOUNT" -c "$CONTAINER" \
  -f "$vhd" -n "$blob" --overwrite --only-show-errors
az image create -g "$RG" -n "$name" --location "$LOCATION" --os-type Linux \
  --source "https://${STORAGE_ACCOUNT}.blob.core.windows.net/${CONTAINER}/${blob}" \
  --only-show-errors -o none

az image show -g "$RG" -n "$name" --query id -o tsv
