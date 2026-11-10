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
# repeat the whole path.
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

rebuild=0
console=0
dry_run=0
stop_after=0
stop_only=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --rebuild) rebuild=1 ;;
    --console) console=1 ;;
    --dry-run) dry_run=1 ;;
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
    -h|--help) sed -n '2,11p' "$0"; exit 0 ;;
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

for tool in "$qemu" qemu-img jq curl python3; do
  command -v "$tool" >/dev/null || { echo "missing tool: $tool" >&2; exit 1; }
done

mkdir -p "$cache"

# A running VM owns the disks; refuse to stomp it.
if [ -s "$pidfile" ] && kill -0 "$(cat "$pidfile")" 2>/dev/null && [ "$dry_run" = 0 ]; then
  echo "a VM is already running (pid $(cat "$pidfile")); use --stop first" >&2
  exit 1
fi

if [ "$dry_run" = 1 ]; then
  base="$cache/fcos-$(jq -r '.release' "$here/fcos.json").qcow2"
else
  base="$("$here/fetch-fcos.sh")"
  # Keep the guest's report URL on the same port the agent below binds.
  ign="$(VM_AGENT_URL="http://10.0.2.2:$port" "$here/build-ignition.sh")"

  if [ "$rebuild" = 1 ] || [ ! -s "$disk" ]; then
    qemu-img create -f qcow2 -F qcow2 -b "$base" "$disk.new.$$" "$disk_size" >/dev/null
    mv "$disk.new.$$" "$disk"
  fi

  # A blank disk. The guest prepares the partition table and filesystem before
  # var-srv.mount, mirroring the live-media step in docs/install.md.
  if [ "$rebuild" = 1 ] || [ ! -s "$data" ]; then
    truncate -s "$data_size" "$data.new.$$"
    mv "$data.new.$$" "$data"
  fi
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

# The agent holds the port for the life of this script. Stop it on every exit
# path, or a timeout or Ctrl-C leaves a stale listener that the next run collides
# with.
agent_cleanup() {
  if [ -s "$agent_pid" ]; then
    kill "$(cat "$agent_pid")" 2>/dev/null || true
    rm -f "$agent_pid"
  fi
}
trap agent_cleanup EXIT

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
if grep -q '^FAIL ' "$report"; then
  rc=1
fi

echo
cat "$report"
echo
if [ "$rc" -eq 0 ]; then
  echo "VM DOGFOOD: pass"
else
  echo "VM DOGFOOD: failures above"
fi

if [ "$stop_after" = 1 ]; then
  stop_vm
else
  echo "VM is still running. Attach with: socat -,raw,echo=0 UNIX-CONNECT:$serial_sock"
  echo "Stop it with: $here/run-vm.sh --stop"
fi

exit "$rc"
