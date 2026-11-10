#!/usr/bin/env bash
# vm/tests/test_run_args.sh
#
# The harness boots a VM with two disks and the harness Ignition, and it must
# never open an inbound port. --dry-run prints the exact argv without booting,
# so these assertions run on a machine with no KVM and no qemu installed.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
vm="$(cd "$here/.." && pwd)"
fail() { echo "FAIL: $1" >&2; exit 1; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/cache"

# qemu-img is a prerequisite for a real boot; a stub keeps --dry-run free of it.
cat > "$tmp/bin/qemu-img" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod 0755 "$tmp/bin/qemu-img"

export PATH="$tmp/bin:$PATH"
export VM_CACHE="$tmp/cache"
export QEMU=true

# T1: --dry-run prints one argument per line, with both disks and the fw_cfg
#     Ignition.
cmd="$(KVM_DEVICE=/nonexistent "$vm/run-vm.sh" --dry-run)" || fail "T1: --dry-run failed"
grep -Fqx -- "-fw_cfg" <<<"$cmd" || fail "T1: no -fw_cfg"
grep -Fqx -- "name=opt/com.coreos/config,file=$tmp/cache/devbox-vm.ign" <<<"$cmd" \
  || fail "T1: no fw_cfg pointing at the harness Ignition"
grep -Fqx -- "if=virtio,file=$tmp/cache/vm-disk.qcow2,format=qcow2" <<<"$cmd" \
  || fail "T1: no qcow2 OS disk"
grep -Fqx -- "if=virtio,file=$tmp/cache/data.img,format=raw" <<<"$cmd" \
  || fail "T1: no raw data disk"

# T2: no inbound port forward. Reachability is the guest's outbound user net.
if grep -Fq -- "hostfwd" <<<"$cmd"; then
  fail "T2: the VM command forwards an inbound port"
fi

# T3: acceleration follows the KVM device instead of assuming it exists.
grep -Fqx -- "-accel" <<<"$cmd" || fail "T3: no -accel argument"
if ! grep -Fqx -- "tcg" <<<"$cmd"; then
  fail "T3: a missing KVM device did not fall back to tcg"
fi
touch "$tmp/kvm"
kvm_cmd="$(KVM_DEVICE="$tmp/kvm" "$vm/run-vm.sh" --dry-run)" || fail "T3: --dry-run with KVM failed"
if ! grep -Fqx -- "kvm" <<<"$kvm_cmd"; then
  fail "T3: a readable KVM device did not select kvm"
fi

# T4: an unknown flag is rejected, not silently ignored.
if "$vm/run-vm.sh" --no-such-flag >"$tmp/out" 2>"$tmp/err"; then
  fail "T4: an unknown flag exited zero"
fi
grep -q 'unknown argument' "$tmp/err" || fail "T4: no diagnostic for the unknown flag"
if grep -q 'qemu-system' "$tmp/out"; then
  fail "T4: an unknown flag still produced a boot command"
fi

# T4b: --timeout without a value must fail, not reach an empty arithmetic test.
if "$vm/run-vm.sh" --timeout >"$tmp/to.out" 2>"$tmp/to.err"; then
  fail "T4b: --timeout with no value exited zero"
fi
grep -q 'whole number' "$tmp/to.err" || fail "T4b: no diagnostic for the missing timeout value"

# T4c: --help prints the header comment only, not the first code line.
if "$vm/run-vm.sh" --help | grep -q 'set -euo pipefail'; then
  fail "T4c: --help ran past the header comment"
fi

# T5: --stop with no pidfile reports that and exits cleanly.
"$vm/run-vm.sh" --stop >"$tmp/stop.out" 2>"$tmp/stop.err" || fail "T5: --stop failed with no VM"
grep -q 'no VM pidfile' "$tmp/stop.err" || fail "T5: --stop did not say why it did nothing"

# T6: the host creates the data disk as a blank file. Partitioning and
#     formatting belong to the guest, where a separate device is the invariant
#     under test. The only host-side disk image tool creates the OS overlay, and
#     the data disk is a truncate.
qemu_img_lines="$(grep -n 'qemu-img' "$vm/run-vm.sh" || true)"
[ -n "$qemu_img_lines" ] || fail "T6: no qemu-img call, so the OS overlay is not created"
if printf '%s\n' "$qemu_img_lines" | grep -qF "\$data"; then
  fail "T6: qemu-img is applied to the data disk"
fi
grep -qF "truncate -s \"\$data_size\" \"\$data.new" "$vm/run-vm.sh" \
  || fail "T6: the data disk is not created as a blank file"

echo "vm run command uses the harness Ignition, two disks, and no inbound forward"
