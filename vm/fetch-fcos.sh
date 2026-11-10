#!/usr/bin/env bash
# Download and verify the pinned Fedora CoreOS QEMU image used by the dogfood VM.
#
# The pin lives in vm/fcos.json so a harness run is reproducible. `--update`
# refreshes the pin from the stable stream and rewrites that file; it is the
# only path that moves the base image.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
cache="${VM_CACHE:-$repo_root/.vm-cache}"
pin="$here/fcos.json"
update=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --update) update=1 ;;
    -h|--help) sed -n '2,8p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

command -v jq >/dev/null || { echo "jq is required" >&2; exit 1; }
command -v curl >/dev/null || { echo "curl is required" >&2; exit 1; }

mkdir -p "$cache"

if [ "$update" = 1 ]; then
  stream="$(jq -r '.stream' "$pin")"
  arch="$(jq -r '.arch' "$pin")"
  meta="$cache/fcos-stream-$stream.json"
  curl -fsSL --retry 3 -o "$meta" \
    "https://builds.coreos.fedoraproject.org/streams/$stream.json"
  release="$(jq -r --arg arch "$arch" '.architectures[$arch].artifacts.qemu.release' "$meta")"
  jq --arg stream "$stream" --arg arch "$arch" --arg release "$release" \
    '.architectures[$arch].artifacts.qemu.formats["qcow2.xz"].disk as $d
     | {
         _comment: ._comment,
         stream: $stream,
         release: $release,
         arch: $arch,
         qcow2: {
           url: $d.location,
           sha256: $d.sha256,
           uncompressed_sha256: $d["uncompressed-sha256"]
         }
       }' "$meta" | jq --indent 2 . > "$pin.new"
  mv "$pin.new" "$pin"
  echo "pinned FCOS $release into $pin" >&2
fi

release="$(jq -r '.release' "$pin")"
url="$(jq -r '.qcow2.url' "$pin")"
want="$(jq -r '.qcow2.sha256' "$pin")"
want_raw="$(jq -r '.qcow2.uncompressed_sha256' "$pin")"
compressed="$cache/fcos-$release.qcow2.xz"
base="$cache/fcos-$release.qcow2"

if [ ! -s "$base" ]; then
  if [ ! -s "$compressed" ]; then
    echo "downloading FCOS $release" >&2
    curl -fL --retry 3 --retry-delay 5 -o "$compressed.part" "$url"
    mv "$compressed.part" "$compressed"
  fi
  echo "verifying compressed image" >&2
  printf '%s  %s\n' "$want" "$compressed" | sha256sum -c - >/dev/null
  echo "decompressing" >&2
  xz -dc "$compressed" > "$base.part"
  mv "$base.part" "$base"
fi

echo "verifying uncompressed image" >&2
printf '%s  %s\n' "$want_raw" "$base" | sha256sum -c - >/dev/null
echo "FCOS $release ready: $base" >&2
printf '%s\n' "$base"
