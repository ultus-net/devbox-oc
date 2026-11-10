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
cmd="$(KVM_DEVICE=/nonexistent "$vm/run-vm.sh" --dry-run 2>/dev/null)" || fail "T1: --dry-run failed"
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
kvm_cmd="$(KVM_DEVICE="$tmp/kvm" "$vm/run-vm.sh" --dry-run 2>/dev/null)" || fail "T3: --dry-run with KVM failed"
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

# T6: on an empty cache the plan names the two writes a real run would make: an
#     OS overlay on the pinned base and a blank data disk. The guest prepares the
#     data disk before var-srv.mount, so the plan must not reach past a blank file.
export VM_DISK_SIZE=32G VM_DATA_SIZE=8G
release="$(jq -r '.release' "$vm/fcos.json")"
plan="$(KVM_DEVICE=/nonexistent "$vm/run-vm.sh" --dry-run 2>&1 >/dev/null)" || fail "T6: --dry-run failed"
printf '%s\n' "$plan" | grep -F 'plan: ' > "$tmp/plan.actual" || fail "T6: --dry-run printed no disk plan"
printf 'plan: qemu-img create -f qcow2 -F qcow2 -b %s %s 32G\nplan: truncate -s 8G %s\n' \
  "$tmp/cache/fcos-$release.qcow2" "$tmp/cache/vm-disk.qcow2" "$tmp/cache/data.img" \
  > "$tmp/plan.expected"
if ! diff -u "$tmp/plan.expected" "$tmp/plan.actual"; then
  fail "T6: the disk plan is not the two writes an empty cache needs"
fi

# T6b: a populated cache is planned as reuse, not as a write it would not make.
printf 'x' > "$tmp/cache/vm-disk.qcow2"
printf 'x' > "$tmp/cache/data.img"
reuse="$(KVM_DEVICE=/nonexistent "$vm/run-vm.sh" --dry-run 2>&1 >/dev/null)" || fail "T6b: --dry-run failed"
printf '%s\n' "$reuse" | grep -F 'plan: ' > "$tmp/reuse.actual"
printf 'plan: reuse %s\nplan: reuse %s\n' "$tmp/cache/vm-disk.qcow2" "$tmp/cache/data.img" \
  > "$tmp/reuse.expected"
if ! diff -u "$tmp/reuse.expected" "$tmp/reuse.actual"; then
  fail "T6b: a populated cache is still planned as a write"
fi

echo "vm run command uses the harness Ignition, two disks, and no inbound forward"
