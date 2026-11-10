#!/usr/bin/env bash
# Prepare the harness data disk before srv.mount runs.
#
# Production formats the second disk once from the live install media; a VM has
# no live-media step. This does the same declarative work with systemd-repart,
# which creates the GPT partition and the ext4 filesystem with the label the
# mount unit looks up. Ignition still only mounts by label and never touches the
# partition table, so the invariant under test is unchanged.
set -euo pipefail

# True when the device is the whole disk or the partition that backs /. A wrong
# VM_DATA_DEVICE would destroy the OS instead of failing, and the mount unit
# would then look satisfied while /srv sat on the system disk.
refuses_root_device() {
  local dev="$1" root_src="$2" root_disk="$3"
  if [ -z "$root_src" ]; then
    return 1
  fi
  if [ "$dev" = "$root_src" ]; then
    return 0
  fi
  if [ -n "$root_disk" ] && [ "$dev" = "$root_disk" ]; then
    return 0
  fi
  return 1
}

main() {
  local dev="${VM_DATA_DEVICE:-/dev/vdb}"
  [ -b "$dev" ] || { echo "devbox-vm-data: no block device at $dev" >&2; exit 1; }

  local dev_real root_src root_real root_disk
  dev_real="$(readlink -f "$dev")"
  root_src="$(findmnt -n -o SOURCE / 2>/dev/null || true)"
  root_real=""
  if [ -n "$root_src" ]; then
    root_real="$(readlink -f "$root_src")"
  fi
  root_disk=""
  if [ -n "$root_real" ]; then
    root_disk="/dev/$(lsblk -no PKNAME "$root_real" 2>/dev/null || true)"
    [ "$root_disk" = /dev/ ] && root_disk=""
  fi
  if refuses_root_device "$dev_real" "$root_real" "$root_disk"; then
    echo "devbox-vm-data: refusing to repartition $dev, it backs /" >&2
    exit 1
  fi

  local present
  present="$(blkid -s TYPE -o value "$dev" 2>/dev/null || true)"
  if [ "$present" = ext4 ]; then
    echo "devbox-vm-data: $dev already carries ext4, leaving it alone"
  else
    systemd-repart --dry-run=no --empty=allow \
      --definitions=/etc/devbox-vm/repart "$dev"
  fi

  install -d -m 0755 /etc/devbox-vm
  touch /etc/devbox-vm/data-ready
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
