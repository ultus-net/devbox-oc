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

# T4d: --help prints the whole header, so a flag documented there is visible. The
# printed range drifted once and nothing failed, because the flag's name happened
# to sit inside the truncated range. The last header line is the real guard.
help="$("$vm/run-vm.sh" --help)"
printf '%s\n' "$help" | grep -q -- '--disks-only' || fail "T4d: --help does not list --disks-only"
printf '%s\n' "$help" | grep -q 'VM_BASE_IMAGE' || fail "T4d: --help omits VM_BASE_IMAGE"
printf '%s\n' "$help" | grep -q 'exits at detach' || fail "T4d: --help stops before the last header line"

# T5: --stop with no pidfile reports that and exits cleanly.
"$vm/run-vm.sh" --stop >"$tmp/stop.out" 2>"$tmp/stop.err" || fail "T5: --stop failed with no VM"
grep -q 'no VM pidfile' "$tmp/stop.err" || fail "T5: --stop did not say why it did nothing"

# T6: on an empty cache the plan names the two writes a real run would make: an
#     OS overlay on the pinned base and a blank data disk. The guest prepares the
#     data disk before var-srv.mount, so the plan must not reach past a blank file.
#     The sizes are not the defaults, so a size baked into the script cannot pass.
export VM_DISK_SIZE=48G VM_DATA_SIZE=12G
release="$(jq -r '.release' "$vm/fcos.json")"
plan="$(KVM_DEVICE=/nonexistent "$vm/run-vm.sh" --dry-run 2>&1 >/dev/null)" || fail "T6: --dry-run failed"
printf '%s\n' "$plan" | grep -F 'plan: ' > "$tmp/plan.actual" || fail "T6: --dry-run printed no disk plan"
printf 'plan: qemu-img create -f qcow2 -F qcow2 -b %s %s 48G\nplan: truncate -s 12G %s\n' \
  "$tmp/cache/fcos-$release.qcow2" "$tmp/cache/vm-disk.qcow2" "$tmp/cache/data.img" \
  > "$tmp/plan.expected"
if ! diff -u "$tmp/plan.expected" "$tmp/plan.actual"; then
  fail "T6: the disk plan is not the two writes an empty cache needs"
fi

# T6b: a populated cache is planned as reuse, not as a write it would not make.
printf 'x' > "$tmp/cache/vm-disk.qcow2"
printf 'x' > "$tmp/cache/data.img"
reuse="$(KVM_DEVICE=/nonexistent "$vm/run-vm.sh" --dry-run 2>&1 >/dev/null)" || fail "T6b: --dry-run failed"
printf '%s\n' "$reuse" | grep -F 'plan: ' > "$tmp/reuse.actual" \
  || fail "T6b: --dry-run printed no disk plan"
printf 'plan: reuse %s\nplan: reuse %s\n' "$tmp/cache/vm-disk.qcow2" "$tmp/cache/data.img" \
  > "$tmp/reuse.expected"
if ! diff -u "$tmp/reuse.expected" "$tmp/reuse.actual"; then
  fail "T6b: a populated cache is still planned as a write"
fi

# T6c: --rebuild plans both writes even when both disks already exist.
rebuild="$(KVM_DEVICE=/nonexistent "$vm/run-vm.sh" --dry-run --rebuild 2>&1 >/dev/null)" \
  || fail "T6c: --dry-run --rebuild failed"
printf '%s\n' "$rebuild" | grep -F 'plan: ' > "$tmp/rebuild.actual" \
  || fail "T6c: --dry-run printed no disk plan"
if ! diff -u "$tmp/plan.expected" "$tmp/rebuild.actual"; then
  fail "T6c: --rebuild did not plan both writes"
fi

# T7: the default run resolves the guest image to the fixture tag, and both
#     opt-outs resolve it to the published tag. The image is what the guest
#     pulls, so an opt-out that still starts the fixture is a defect.
default_says="$(KVM_DEVICE=/nonexistent "$vm/run-vm.sh" --dry-run 2>&1 >/dev/null)" \
  || fail "T7: the default --dry-run failed"
printf '%s\n' "$default_says" | grep -q '^image: 10\.0\.2\.2:5000/devbox:newer' \
  || fail "T7: the default run does not name the fixture image"

no_rollback="$(KVM_DEVICE=/nonexistent "$vm/run-vm.sh" --dry-run --no-rollback 2>&1 >/dev/null)" \
  || fail "T7b: --no-rollback --dry-run failed"
printf '%s\n' "$no_rollback" | grep -q '^image: ghcr\.io/ultus-net/devbox:prod' \
  || fail "T7b: --no-rollback does not name the published image"
if printf '%s\n' "$no_rollback" | grep -q '10\.0\.2\.2'; then
  fail "T7b: --no-rollback still points at the fixture registry"
fi

override="$(VM_IMAGE=127.0.0.1:5000/devbox:newer KVM_DEVICE=/nonexistent \
  "$vm/run-vm.sh" --dry-run 2>&1 >/dev/null)" \
  || fail "T7c: an explicit VM_IMAGE --dry-run failed"
printf '%s\n' "$override" | grep -q '^image: 127\.0\.0\.1:5000/devbox:newer' \
  || fail "T7c: an explicit VM_IMAGE is not the resolved image"
if printf '%s\n' "$override" | grep -q '10\.0\.2\.2'; then
  fail "T7c: an explicit VM_IMAGE still starts the fixture"
fi

# T7d: --console exits at detach, so the cleanup trap would take the registry
#      down before the guest reaches the rehearsal. That run skips the fixture.
console_image="$(KVM_DEVICE=/nonexistent "$vm/run-vm.sh" --dry-run --console 2>&1 >/dev/null)" \
  || fail "T7d: --console --dry-run failed"
printf '%s\n' "$console_image" | grep -q '^image: ghcr\.io/ultus-net/devbox:prod' \
  || fail "T7d: --console does not name the published image"
if printf '%s\n' "$console_image" | grep -q '10\.0\.2\.2'; then
  fail "T7d: --console still points at the fixture registry"
fi

# T8: the default run needs a working podman for the fixture, and must refuse
#     before it touches a disk when podman is unusable. The stub stands in for a
#     host without one, which is every CI runner.
mkdir -p "$tmp/badbin"
cat > "$tmp/badbin/podman" <<'EOF'
#!/bin/sh
exit 1
EOF
chmod 0755 "$tmp/badbin/podman"
if PATH="$tmp/badbin:$PATH" VM_CACHE="$tmp/preflight-cache" \
  "$vm/run-vm.sh" >"$tmp/pf.out" 2>"$tmp/pf.err"; then
  fail "T8: the default run accepted an unusable podman"
fi
grep -qi 'podman' "$tmp/pf.err" || fail "T8: no diagnostic names podman"
if [ -e "$tmp/preflight-cache/vm-disk.qcow2" ]; then
  fail "T8: the preflight ran after disk work"
fi

# T9: a run that fails after the fixture starts still removes it. The stub
#     podman starts the registry and the stubs answer the health poll, then a
#     broken butane fails the ignition build and the EXIT trap must call down.
mkdir -p "$tmp/fixbin"
cat > "$tmp/fixbin/podman" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$PODMAN_LOG"
exit 0
EOF
printf '#!/bin/sh\nexit 0\n' > "$tmp/fixbin/curl"
printf '#!/bin/sh\nexit 0\n' > "$tmp/fixbin/sleep"
chmod 0755 "$tmp/fixbin/podman" "$tmp/fixbin/curl" "$tmp/fixbin/sleep"

PODMAN_LOG="$tmp/teardown.log"
export PODMAN_LOG
: > "$PODMAN_LOG"
if PATH="$tmp/fixbin:$PATH" VM_CACHE="$tmp/teardown-cache" \
  VM_BASE_IMAGE="$tmp/teardown-base.qcow2" BUTANE=/bin/false \
  "$vm/run-vm.sh" >"$tmp/td.out" 2>"$tmp/td.err"; then
  fail "T9: a broken butane did not fail the run"
fi
teardown_rm="$(grep -cx 'rm -f devbox-vm-registry' "$PODMAN_LOG" || true)"
[ "${teardown_rm:-0}" -ge 2 ] \
  || fail "T9: the fixture survived a failure after it started"

echo "vm run command uses the harness Ignition, two disks, and no inbound forward"
