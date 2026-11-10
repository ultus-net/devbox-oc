#!/usr/bin/env bash
# vm/tests/test_disk_write.sh
#
# Runs the disk write path itself, not only its plan. Stub qemu-img and truncate
# record the argv they received, so these assertions see the command that ran,
# the file it landed on, and that the temporary name was renamed into place.
#
# The gap this closes: every other suite passed with either `mv` deleted, so a
# create that never landed could leave a disk a later run silently ignored.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
vm="$(cd "$here/.." && pwd)"
fail() { echo "FAIL: $1" >&2; exit 1; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
cache="$tmp/cache"
logs="$tmp/log"
mkdir -p "$cache" "$logs" "$tmp/bin"

# The stubs create the destination they are given, because the real path renames
# it into place and a missing file would fail the mv for the wrong reason.
cat > "$tmp/bin/qemu-img" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$logs/qemu-img"
printf 'stub\n' > "\$8"
if [ "\${STUB_FAIL:-0}" = 1 ]; then exit 1; fi
EOF

cat > "$tmp/bin/truncate" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$logs/truncate"
printf 'stub\n' > "\$3"
EOF
chmod 0755 "$tmp/bin/qemu-img" "$tmp/bin/truncate"

# A base the overlay can name. Its content is never read: qemu-img is a stub.
base="$tmp/base.qcow2"
printf 'stub base\n' > "$base"

final_os="$cache/vm-disk.qcow2"
final_data="$cache/data.img"

run_vm() {
  env PATH="$tmp/bin:$PATH" VM_CACHE="$cache" VM_BASE_IMAGE="$base" \
    VM_DISK_SIZE=48G VM_DATA_SIZE=12G "$vm/run-vm.sh" --disks-only "$@"
}

if ! run_vm >"$tmp/run.log" 2>&1; then
  cat "$tmp/run.log" >&2
  fail "the disk write path did not complete"
fi

# The overlay names the base and the size it was given, and it lands on a
# temporary name rather than the file a later run would trust.
read -r -a argv <<< "$(cat "$logs/qemu-img")"
[ "${argv[0]:-}" = create ] || fail "qemu-img was not asked to create: ${argv[*]:-}"
[ "${argv[1]:-} ${argv[2]:-}" = "-f qcow2" ] || fail "the overlay format is not qcow2: ${argv[*]}"
[ "${argv[3]:-} ${argv[4]:-}" = "-F qcow2" ] || fail "the base format is not qcow2: ${argv[*]}"
[ "${argv[5]:-}" = -b ] || fail "the overlay names no base: ${argv[*]}"
[ "${argv[6]:-}" = "$base" ] || fail "the overlay base is not the one given: ${argv[6]:-none}"
os_dest="${argv[7]:-}"
[ "${argv[8]:-}" = 48G ] || fail "the overlay size is not the one requested: ${argv[8]:-none}"
[ "$os_dest" != "$final_os" ] || fail "the overlay was written straight to the final name"
case "$os_dest" in
  "$final_os".*) ;;
  *) fail "the overlay did not land beside its final name: $os_dest" ;;
esac

read -r -a argv <<< "$(cat "$logs/truncate")"
[ "${argv[0]:-}" = -s ] || fail "truncate was not asked for a size: ${argv[*]:-}"
[ "${argv[1]:-}" = 12G ] || fail "the data size is not the one requested: ${argv[1]:-none}"
data_dest="${argv[2]:-}"
[ "$data_dest" != "$final_data" ] || fail "the data disk was written straight to the final name"
case "$data_dest" in
  "$final_data".*) ;;
  *) fail "the data disk did not land beside its final name: $data_dest" ;;
esac

# A temporary name that survives is a disk the next run would silently reuse.
leftovers="$(compgen -G "$cache/*.new.*" || true)"
[ -z "$leftovers" ] || fail "temporary disk names survived: $leftovers"

[ -s "$final_os" ] || fail "no OS disk after the create path"
[ -s "$final_data" ] || fail "no data disk after the create path"

# Reuse: a disk that exists is not recreated, so neither stub is called.
: > "$logs/qemu-img"
: > "$logs/truncate"
if ! run_vm >"$tmp/run2.log" 2>&1; then
  cat "$tmp/run2.log" >&2
  fail "the reuse path did not complete"
fi
[ ! -s "$logs/qemu-img" ] || fail "the OS disk was recreated without --rebuild"
[ ! -s "$logs/truncate" ] || fail "the data disk was recreated without --rebuild"

# --rebuild discards both, so the write path runs again.
if ! run_vm --rebuild >"$tmp/run3.log" 2>&1; then
  cat "$tmp/run3.log" >&2
  fail "the rebuild path did not complete"
fi
grep -q ' 48G$' "$logs/qemu-img" || fail "--rebuild did not recreate the OS disk"
grep -q '^-s 12G ' "$logs/truncate" || fail "--rebuild did not recreate the data disk"

# A create that fails must not leave its temporary behind; nothing else ever
# removes it.
rm -rf "$cache"
mkdir -p "$cache"
if STUB_FAIL=1 run_vm >"$tmp/run4.log" 2>&1; then
  fail "an aborted create exited zero"
fi
leftovers="$(compgen -G "$cache/*.new.*" || true)"
[ -z "$leftovers" ] || fail "an aborted create left $leftovers"
[ ! -e "$final_os" ] || fail "an aborted create left a final OS disk"

echo "the disk write path creates both disks, renames them into place, and cleans up a failed create"
