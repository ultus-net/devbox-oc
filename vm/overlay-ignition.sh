#!/usr/bin/env bash
# Merge the VM-only test harness into a compiled devbox Ignition document.
#
# The harness must not fork os/butane/ucore.bu: the whole point is to exercise
# the shipped config. This script takes the real build output and appends a
# serial console, the dogfood check unit, and its script. The base document is
# read-only input and the merge is idempotent, so a retry cannot duplicate keys.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
agent_url="${VM_AGENT_URL:-http://10.0.2.2:8123}"
hostname="${VM_HOSTNAME:-devbox-vm}"
image="${VM_IMAGE:-ghcr.io/ultus-net/devbox:prod}"
registry="${VM_REGISTRY:-}"
rollback_repo="${VM_ROLLBACK_REPO:-}"

if [ "$#" -ne 2 ]; then
  echo "usage: overlay-ignition.sh BASE.ign OUT.ign" >&2
  exit 2
fi

base="$1"
out="$2"
command -v jq >/dev/null || { echo "jq is required" >&2; exit 1; }
[ -s "$base" ] || { echo "base ignition is missing: $base" >&2; exit 1; }

# Prove the input is a compiled Ignition document before touching it.
jq -e '.ignition.version and (.storage.files | type == "array")
       and (.systemd.units | type == "array")' "$base" >/dev/null \
  || { echo "not a compiled Ignition document: $base" >&2; exit 1; }

# ${TERM} is expanded by systemd when it runs agetty, not by this shell.
# shellcheck disable=SC2016
serial_getty='[Service]
ExecStart=
ExecStart=-/usr/sbin/agetty --autologin core --noreset --noclear - ${TERM}'

check_unit='[Unit]
Description=Devbox VM dogfood check
ConditionPathExists=/etc/ucore-autorebase/done
ConditionPathExists=!/var/lib/devbox-vm/checked
Wants=network-online.target
After=network-online.target var-srv.mount oc-paths.service oc-env.service
[Service]
Type=oneshot
RemainAfterExit=yes
StandardOutput=journal+console
ExecStart=/usr/local/sbin/devbox-vm-check
[Install]
WantedBy=multi-user.target'

# The script lives in /etc, not /usr/local/sbin: this unit has
# DefaultDependencies=no and runs before local-fs.target, where /var is not
# mounted yet and /usr/local (a symlink into /var) does not resolve, which makes
# the exec fail with 203/EXEC. /etc is on the root filesystem.
data_unit='[Unit]
Description=Prepare the VM data disk
DefaultDependencies=no
After=dev-vdb.device
Requires=dev-vdb.device
Before=var-srv.mount
ConditionPathExists=!/etc/devbox-vm/data-ready
[Service]
Type=oneshot
RemainAfterExit=yes
StandardOutput=journal+console
StandardError=journal+console
ExecStart=/etc/devbox-vm/devbox-vm-data
[Install]
WantedBy=local-fs.target'

repart_conf='[Partition]
Type=linux-generic
Label=data
Format=ext4
'

# The rollback rehearsal pulls from a plain-HTTP registry on the host loopback,
# reached at the qemu user-network address. Only the harness sets this.
registry_conf=''
if [ -n "$registry" ]; then
  registry_conf="[[registry]]
location = \"$registry\"
insecure = true
"
fi

staged="$out.staged.$$"
trap 'rm -f "$staged"' EXIT

jq --rawfile check "$here/guest-check.sh" \
  --rawfile data_script "$here/guest-data.sh" \
  --arg agent_url "$agent_url" \
  --arg hostname "$hostname" \
  --arg image "$image" \
  --arg registry "$registry" \
  --arg registry_conf "$registry_conf" \
  --arg rollback_repo "$rollback_repo" \
  --arg serial "$serial_getty" \
  --arg unit "$check_unit" \
  --arg data_unit "$data_unit" \
  --arg repart "$repart_conf" '
  # Drop a prior copy of every key this overlay owns, so a second run is a
  # no-op rather than a duplicate. A duplicate file path is an Ignition error.
  def own_file: . == "/usr/local/sbin/devbox-vm-check"
             or . == "/etc/devbox-vm/devbox-vm-data"
             or . == "/etc/devbox-vm/agent.env"
             or . == "/etc/devbox-vm/repart/10-data.conf"
             or . == "/etc/containers/registries.conf.d/000-devbox-vm-registry.conf"
             or . == "/etc/systemd/system/serial-getty@ttyS0.service.d/10-autologin.conf";

  .storage.files = ((.storage.files // []) | map(select(.path | own_file | not)))
  | .storage.links = ((.storage.links // [])
      | map(select(.path != "/etc/systemd/system/getty.target.wants/serial-getty@ttyS0.service")))
  | .systemd.units = ((.systemd.units // [])
      | map(select(.name != "devbox-vm-check.service" and .name != "devbox-vm-data.service")))

  | .storage.files += [
      {
        path: "/usr/local/sbin/devbox-vm-check",
        mode: 493,
        contents: {source: ("data:;base64," + ($check | @base64))}
      },
      {
        path: "/etc/devbox-vm/devbox-vm-data",
        mode: 493,
        contents: {source: ("data:;base64," + ($data_script | @base64))}
      },
      {
        path: "/etc/devbox-vm/repart/10-data.conf",
        mode: 420,
        contents: {source: ("data:;base64," + ($repart | @base64))}
      },
      {
        path: "/etc/devbox-vm/agent.env",
        mode: 420,
        contents: {source: ("data:;base64," + (("AGENT_URL=" + $agent_url
          + "\nEXPECTED_HOSTNAME=" + $hostname
          + "\nEXPECTED_IMAGE=" + $image
          + "\nROLLBACK_REPO=" + $rollback_repo + "\n") | @base64))}
      },
      {
        path: "/etc/systemd/system/serial-getty@ttyS0.service.d/10-autologin.conf",
        mode: 420,
        contents: {source: ("data:;base64," + ($serial | @base64))}
      }
    ] + (if $registry == "" then [] else [{
        path: "/etc/containers/registries.conf.d/000-devbox-vm-registry.conf",
        mode: 420,
        contents: {source: ("data:;base64," + ($registry_conf | @base64))}
      }] end)
  | .storage.links += [{
      path: "/etc/systemd/system/getty.target.wants/serial-getty@ttyS0.service",
      target: "/usr/lib/systemd/system/serial-getty@ttyS0.service",
      hard: false
    }]
  | .systemd.units += [
      {
        name: "devbox-vm-check.service",
        enabled: true,
        contents: $unit
      },
      {
        name: "devbox-vm-data.service",
        enabled: true,
        contents: $data_unit
      }
    ]
' "$base" > "$staged"

# A merge that silently replaced the base instead of appending would produce a
# bootable VM that proves nothing. Compare the key sets before publishing.
jq -e --slurpfile base "$base" '
  (.ignition.version == $base[0].ignition.version)
  and (($base[0].storage.files | map(.path)) - (.storage.files | map(.path)) | length == 0)
  and ((($base[0].storage.links // []) | map(.path)) - ((.storage.links // []) | map(.path)) | length == 0)
  and ((($base[0].storage.directories // []) | map(.path)) - ((.storage.directories // []) | map(.path)) | length == 0)
  and (($base[0].systemd.units | map(.name)) - (.systemd.units | map(.name)) | length == 0)
' "$staged" >/dev/null || { echo "overlay dropped base entries" >&2; exit 1; }

jq -e --arg registry "$registry" '
  (.storage.files | map(select(.path == "/usr/local/sbin/devbox-vm-check")) | length == 1)
  and (.storage.files | map(select(.path == "/etc/devbox-vm/devbox-vm-data")) | length == 1)
  and (.storage.files | map(select(.path == "/etc/devbox-vm/agent.env")) | length == 1)
  and (.storage.files | map(select(.path == "/etc/containers/registries.conf.d/000-devbox-vm-registry.conf")) | length == (if $registry == "" then 0 else 1 end))
  and (.storage.links | map(select(.path == "/etc/systemd/system/getty.target.wants/serial-getty@ttyS0.service")) | length == 1)
  and (.systemd.units | map(select(.name == "devbox-vm-check.service")) | length == 1)
  and (.systemd.units | map(select(.name == "devbox-vm-data.service")) | length == 1)
' "$staged" >/dev/null || { echo "overlay did not add its own entries exactly once" >&2; exit 1; }

chmod 0644 "$staged"
mv "$staged" "$out"
trap - EXIT
echo "vm ignition ready: $out"
