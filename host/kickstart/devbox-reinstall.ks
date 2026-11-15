# host/kickstart/devbox-reinstall.ks
#
# Reinstall of the OS partition on a box whose data partition already exists.
# Three rules make this safe, and host/tests/test_kickstart_data.sh asserts all
# three:
#
#   1. clearpart --none: no partition table is rewritten, so no partition can be
#      silently recreated.
#   2. every partition is named with --onpart, so the installer reformats the
#      partition it is told to and no other.
#   3. the data partition is mounted with --noformat --useexisting, so it is
#      attached and never written.
#
# The trade is explicit: the data partition is now a partition on the same disk
# as the OS, so this file is the only thing standing between a reinstall and
# /srv. That is why the guard tests this file rather than the procedure.
#
# As with the first install, confirm the device names with `lsblk` before
# starting, and edit the four `nvme0n1pN` references if they differ.

#version=DEVEL
text
lang en_GB.UTF-8
keyboard us
timezone Europe/London --utc
network --bootproto=dhcp --device=link --activate --hostname=devbox

ignoredisk --only-use=nvme0n1
clearpart --none

part /boot/efi --fstype=efi  --onpart=nvme0n1p1
part /boot     --fstype=ext4 --onpart=nvme0n1p2
part /         --fstype=xfs  --onpart=nvme0n1p3
part /srv      --onpart=nvme0n1p4 --noformat --useexisting

%packages
@^minimal-environment
podman
git
chrony
firewalld
%end
