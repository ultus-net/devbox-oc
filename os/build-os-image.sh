#!/usr/bin/env bash
# Download the Fedora CoreOS Azure VHD, upload it, and create a managed image.
# Fedora publishes no CoreOS image in the Azure marketplace, so this step exists.
set -euo pipefail

STREAM="${STREAM:-stable}"
RG="${RG:?RG is required}"
STORAGE_ACCOUNT="${STORAGE_ACCOUNT:?STORAGE_ACCOUNT is required}"
CONTAINER="${CONTAINER:-images}"
LOCATION="${LOCATION:-westeurope}"
DRY_RUN="${DRY_RUN:-0}"

command -v coreos-installer >/dev/null || { echo "coreos-installer not installed; see docs/runbook.md" >&2; exit 1; }
command -v az >/dev/null || { echo "az not installed" >&2; exit 1; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

echo "downloading FCOS ${STREAM} azure vhd" >&2
coreos-installer download --decompress --stream "$STREAM" --platform azure \
  --format vhd.xz --directory "$work"
vhd="$(find "$work" -name '*.vhd' -print -quit)"
[ -f "$vhd" ] || { echo "no vhd produced" >&2; exit 1; }

# Provenance next to the artifact. This is what an auditor asks for.
sha256sum "$vhd" | tee "$vhd.sha256" >&2

name="devbox-fcos-${STREAM}-$(date -u +%Y%m%d)"
blob="${name}.vhd"

if [ "$DRY_RUN" = "1" ]; then
  echo "dry run: would upload $vhd to $STORAGE_ACCOUNT/$CONTAINER as $blob"
  echo "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/${RG}/providers/Microsoft.Compute/images/${name}"
  exit 0
fi

az storage blob upload --account-name "$STORAGE_ACCOUNT" -c "$CONTAINER" \
  -f "$vhd" -n "$blob" --overwrite --only-show-errors
az image create -g "$RG" -n "$name" --location "$LOCATION" --os-type Linux \
  --source "https://${STORAGE_ACCOUNT}.blob.core.windows.net/${CONTAINER}/${blob}" \
  --only-show-errors -o none

az image show -g "$RG" -n "$name" --query id -o tsv
