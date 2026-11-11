#!/usr/bin/env bash
# Boot the devbox Ignition in a QEMU VM and dogfood it end to end.
#
# The VM uses the pinned Fedora CoreOS qcow2 from vm/fcos.json, applies the
# Ignition compiled from os/butane/ucore.bu, rebases to ucore on first boot, and
# then runs vm/guest-check.sh. The guest posts its report to a host agent bound
# to 127.0.0.1 and reached over the qemu user network, so nothing is exposed on
# the LAN and no shared filesystem is needed.
#
# Ignition runs on first boot only. Use --rebuild to discard the OS overlay and
# repeat the whole path. --disks-only stops after the disk steps, so the gate can
# exercise the write path without QEMU. VM_BASE_IMAGE replaces the pinned base
# image with a path of your own; the disk test uses it to skip the download.
# By default the run also seeds two local tags and rehearses the image rollback.
# --no-rollback boots the published image, VM_IMAGE overrides the image, and
# --console skips the fixture, because that run exits at detach.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
cache="${VM_CACHE:-$repo_root/.vm-cache}"
memory="${VM_MEM:-4096}"
cpus="${VM_CPUS:-4}"
disk_size="${VM_DISK_SIZE:-32G}"
data_size="${VM_DATA_SIZE:-8G}"
port="${VM_AGENT_PORT:-8123}"
timeout="${VM_TIMEOUT:-2400}"
kvm_device="${KVM_DEVICE:-/dev/kvm}"
qemu="${QEMU:-qemu-system-x86_64}"
base_image="${VM_BASE_IMAGE:-}"

rebuild=0
console=0
dry_run=0
disks_only=0
stop_after=0
stop_only=0
rollback="${VM_ROLLBACK:-1}"
registry_port="${VM_REGISTRY_PORT:-5000}"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --rebuild) rebuild=1 ;;
    --console) console=1 ;;
    --dry-run) dry_run=1 ;;
    --disks-only) disks_only=1 ;;
    --no-rollback) rollback=0 ;;
    --stop-after-check) stop_after=1 ;;
    --stop) stop_only=1 ;;
    --timeout)
      shift
      case "${1:-}" in
        ''|*[!0-9]*)
          echo "--timeout needs a whole number of seconds" >&2
          exit 2
          ;;
      esac
      timeout="$1"
      ;;
    -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

disk="$cache/vm-disk.qcow2"
data="$cache/data.img"
ign="$cache/devbox-vm.ign"
pidfile="$cache/qemu.pid"
monitor="$cache/monitor.sock"
serial_sock="$cache/serial.sock"
serial_log="$cache/serial.log"
report="$cache/report.txt"
done_flag="$cache/report.done"
agent_pid="$cache/agent.pid"

stop_vm() {
  if [ ! -s "$pidfile" ]; then
    echo "no VM pidfile at $pidfile" >&2
    return 0
  fi
  local pid
  pid="$(cat "$pidfile")"
  if ! kill -0 "$pid" 2>/dev/null; then
    echo "VM is not running (pid $pid)"
    return 0
  fi
  if command -v socat >/dev/null 2>&1 && [ -S "$monitor" ]; then
    printf 'system_powerdown\n' | socat - "UNIX-CONNECT:$monitor" >/dev/null 2>&1 || true
  fi
  for _ in $(seq 1 60); do
    if ! kill -0 "$pid" 2>/dev/null; then
      echo "VM stopped"
      return 0
    fi
    sleep 2
  done
  kill -TERM "$pid" 2>/dev/null || true
  for _ in $(seq 1 15); do
    if ! kill -0 "$pid" 2>/dev/null; then
      echo "VM stopped after TERM"
      return 0
    fi
    sleep 2
  done
  echo "VM did not stop; pid $pid is still running" >&2
  return 1
}

if [ "$stop_only" = 1 ]; then
  stop_vm || exit 1
  exit 0
fi

# One decision, three readers: the preflight, the dry-run report and the fixture
# start. A rollback run against the published tag would be a production mutation,
# so the fixture runs unless the operator brings an image. A console attach skips
# it: that run exits at detach, before the guest reaches the rehearsal.
fixture=0
if [ "$rollback" = 1 ] && [ "$console" = 0 ] && [ "$disks_only" = 0 ] \
  && [ -z "${VM_IMAGE:-}" ]; then
  fixture=1
fi

# --disks-only stops before QEMU, so it must not demand the QEMU toolchain. Both
# paths create the data disk with truncate, so both check it.
if [ "$disks_only" = 1 ]; then
  tools=(qemu-img truncate)
else
  tools=("$qemu" qemu-img truncate jq curl python3)
fi
for tool in "${tools[@]}"; do
  command -v "$tool" >/dev/null || { echo "missing tool: $tool" >&2; exit 1; }
done

# The fixture is built and served with podman. Fail here rather than midway, but
# keep --dry-run free of the requirement so the plan still prints on a host that
# has no podman.
if [ "$fixture" = 1 ] && [ "$dry_run" = 0 ]; then
  command -v podman >/dev/null \
    || { echo "missing tool: podman (needed for the rollback fixture)" >&2; exit 1; }
  podman --version >/dev/null 2>&1 \
    || { echo "podman is not usable; the rollback fixture needs it" >&2; exit 1; }
fi

mkdir -p "$cache"

# The fixture registry and the report agent belong to this run. Stop both on
# every exit path, including a failed fixture start or a failed disk create, or
# the next run collides with a stale listener. Neither starts on a dry run.
registry_up=0
agent_started=0
# shellcheck disable=SC2317  # invoked by the EXIT trap
agent_cleanup() {
  if [ "${agent_started:-0}" = 1 ] && [ -s "$agent_pid" ]; then
    kill "$(cat "$agent_pid")" 2>/dev/null || true
    rm -f "$agent_pid"
  fi
}
# shellcheck disable=SC2317  # invoked by the EXIT trap
cleanup() {
  agent_cleanup
  if [ "${registry_up:-0}" = 1 ]; then
    "$here/fixture-registry.sh" down >&2 || true
  fi
}
trap cleanup EXIT

# A running VM owns the disks; refuse to stomp it.
if [ -s "$pidfile" ] && kill -0 "$(cat "$pidfile")" 2>/dev/null && [ "$dry_run" = 0 ]; then
  echo "a VM is already running (pid $(cat "$pidfile")); use --stop first" >&2
  exit 1
fi

# One argv per disk step. --dry-run prints it on stderr instead of running it, so
# the plan and the real path cannot drift. The write lands on a temporary name
# and is renamed, so a failed create never leaves a disk a later run trusts. The
# OS disk is a qcow2 overlay on the pinned base. The data disk stays blank: the
# guest prepares it before var-srv.mount, mirroring the live-media step in
# docs/install.md.
run_step() {
  if [ "$dry_run" = 1 ]; then
    printf 'plan: %s\n' "$*" >&2
    return 0
  fi
  "$@"
}

create_os_disk() {
  local dest="$disk"
  [ "$dry_run" = 1 ] || dest="$disk.new.$$"
  # A failed create must not leave the temporary behind, because nothing else
  # ever removes it.
  if ! run_step qemu-img create -f qcow2 -F qcow2 -b "$base" "$dest" "$disk_size" >/dev/null; then
    [ "$dry_run" = 1 ] || rm -f "$dest"
    return 1
  fi
  [ "$dry_run" = 1 ] || mv "$dest" "$disk"
}

create_data_disk() {
  local dest="$data"
  [ "$dry_run" = 1 ] || dest="$data.new.$$"
  if ! run_step truncate -s "$data_size" "$dest"; then
    [ "$dry_run" = 1 ] || rm -f "$dest"
    return 1
  fi
  [ "$dry_run" = 1 ] || mv "$dest" "$data"
}

# Rehearse the rollback against two local tags unless the operator brings an
# image. The guest pulls the fixture, so no published tag is mutated, and the
# fixture is built FROM the image the host runs.
if [ "$fixture" = 1 ]; then
  registry_host="10.0.2.2:$registry_port"
  export VM_REGISTRY="$registry_host"
  export VM_ROLLBACK_REPO="$registry_host/devbox"
  export VM_IMAGE="$registry_host/devbox:newer"
  if [ "$dry_run" = 1 ]; then
    echo "image: $VM_IMAGE (fixture registry)" >&2
  else
    # Mark the container as ours before it exists, so a failed start still runs
    # the cleanup trap.
    registry_up=1
    "$here/fixture-registry.sh" up >&2
  fi
elif [ "$dry_run" = 1 ] && [ "$disks_only" = 0 ]; then
  echo "image: ${VM_IMAGE:-ghcr.io/ultus-net/devbox:prod} (published)" >&2
fi

if [ "$dry_run" = 1 ]; then
  base="${base_image:-$("$here/fetch-fcos.sh" --print-base)}"
else
  base="${base_image:-$("$here/fetch-fcos.sh")}"
  if [ "$disks_only" = 0 ]; then
    # Keep the guest's report URL on the same port the agent below binds.
    ign="$(VM_AGENT_URL="http://10.0.2.2:$port" "$here/build-ignition.sh")"
  fi
fi

if [ "$rebuild" = 1 ] || [ ! -s "$disk" ]; then
  create_os_disk
elif [ "$dry_run" = 1 ]; then
  echo "plan: reuse $disk" >&2
fi

if [ "$rebuild" = 1 ] || [ ! -s "$data" ]; then
  create_data_disk
elif [ "$dry_run" = 1 ]; then
  echo "plan: reuse $data" >&2
fi

if [ "$disks_only" = 1 ]; then
  echo "disks ready: $disk $data"
  exit 0
fi

if [ -r "$kvm_device" ]; then
  accel_args=(-accel kvm -cpu host)
else
  accel_args=(-accel tcg -cpu max)
  echo "no readable $kvm_device; falling back to tcg (slow)" >&2
fi

# qemu separates device options with commas inside one argv element, which is
# not the list separator shellcheck assumes.
# shellcheck disable=SC2054
qemu_args=(
  -name devbox-vm
  -smp "$cpus"
  -m "$memory"
  "${accel_args[@]}"
  -display none
  -chardev "socket,id=serial0,path=$serial_sock,server=on,wait=off,logfile=$serial_log"
  -serial chardev:serial0
  -monitor "unix:$monitor,server=on,wait=off"
  -fw_cfg "name=opt/com.coreos/config,file=$ign"
  -drive "if=virtio,file=$disk,format=qcow2"
  -drive "if=virtio,file=$data,format=raw"
  -nic user,model=virtio
  -daemonize
  -pidfile "$pidfile"
)

if [ "$dry_run" = 1 ]; then
  printf '%s\n' "$qemu" "${qemu_args[@]}"
  exit 0
fi

if [ -f "$done_flag" ]; then
  mv "$done_flag" "$done_flag.old"
fi

python3 "$here/report-agent.py" \
  --port "$port" \
  --report "$report" \
  --done "$done_flag" >"$cache/agent.log" 2>&1 &
echo "$!" > "$agent_pid"
agent_started=1

echo "booting the VM (serial log: $serial_log)" >&2
"$qemu" "${qemu_args[@]}"

# qemu removes its pidfile on exit, so read the pid once. Re-reading it in the
# wait loop makes a stopped VM look alive until the timeout.
qemu_pid="$(cat "$pidfile" 2>/dev/null || true)"
if [ -z "$qemu_pid" ]; then
  echo "qemu started but wrote no pidfile at $pidfile" >&2
  exit 1
fi

if [ "$console" = 1 ]; then
  echo "attaching to the serial console; detach with Ctrl-a x" >&2
  # No exec: replacing the shell would skip the agent cleanup trap.
  socat -,raw,echo=0 "UNIX-CONNECT:$serial_sock" || true
  exit 0
fi

echo "waiting for the guest report (includes the ucore rebase; up to ${timeout}s)" >&2
waited=0
while [ ! -f "$done_flag" ]; do
  if [ "$waited" -ge "$timeout" ]; then
    echo "timed out waiting for $done_flag" >&2
    echo "last serial output:" >&2
    tail -n 40 "$serial_log" >&2 || true
    exit 1
  fi
  if ! kill -0 "$qemu_pid" 2>/dev/null; then
    echo "qemu exited before the guest reported" >&2
    tail -n 40 "$serial_log" >&2 || true
    exit 1
  fi
  sleep 5
  waited=$((waited + 5))
done

agent_cleanup

rc=0
"$here/report-verdict.sh" "$report" || rc=1

echo
cat "$report"
echo

if [ "$stop_after" = 1 ]; then
  stop_vm || rc=1
else
  echo "VM is still running. Attach with: socat -,raw,echo=0 UNIX-CONNECT:$serial_sock"
  echo "Stop it with: $here/run-vm.sh --stop"
fi

# The verdict comes last, after any shutdown attempt, so it is the run's exit
# status the operator reads.
if [ "$rc" -eq 0 ]; then
  echo "VM DOGFOOD: pass"
else
  echo "VM DOGFOOD: fail (see the report above)"
fi

exit "$rc"
