# host/kickstart/devbox-first.ks
#
# First install of the devbox. This file claims the whole disk, so boot it only
# on a box whose data partition does not hold anything yet. A reinstall uses
# devbox-reinstall.ks instead, which never formats the data partition.
#
# The disk is addressed by name rather than by id because the kickstart runs
# before the operator can inspect it. Confirm the device in the installer with
# `lsblk` and edit the five `nvme0n1` references if it differs.
#
# Deliberately absent: rootpw, user, and any key. Anaconda prompts for the root
# password on the console, and the box has no SSH key because the only shell
# path is Tailscale SSH, which authorises a tailnet identity rather than a file.

#version=DEVEL
text
lang en_GB.UTF-8
keyboard us
timezone Europe/London --utc
network --bootproto=dhcp --device=link --activate --hostname=devbox

ignoredisk --only-use=nvme0n1
zerombr
clearpart --all --initlabel --disklabel=gpt

part /boot/efi --fstype=efi      --size=1024  --ondisk=nvme0n1 --asprimary
part /boot     --fstype=ext4     --size=1024  --ondisk=nvme0n1
part /         --fstype=xfs      --size=40960 --ondisk=nvme0n1
# The data partition takes the rest of the device and is created exactly once.
part /srv      --fstype=xfs      --label=data --size=1024 --grow --ondisk=nvme0n1

# Fedora Server is the host only. Applications run as containers, so the package
# set is podman, the tailnet client, the clock, and the firewall. No cockpit, no
# web server, and no toolchain: the toolchain is the image in image/.
%packages
@^minimal-environment
podman
git
chrony
firewalld
# Tailscale is not in Fedora's repositories. It is installed at the console in
# step F3 of docs/install.md, because a third-party repository pinned in a
# kickstart is a network dependency during the install and a key to import.
%end

# No %post. Every unit, drop-in, and script is written by devbox-apply from
# host/, so there is exactly one place that owns host configuration.
