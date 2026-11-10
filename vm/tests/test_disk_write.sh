#!/usr/bin/env bash
# vm/tests/test_disk_write.sh
#
# Runs the disk write path itself, not only its plan. Stub qemu-img and truncate
# record the argv they received, so these assertions see the command that ran,
# the file it landed on, and that the temporary name was renamed into place.
#
# The gap this closes: every other suite passed with either `mv` deleted, so an
# aborted create could leave a disk a later run trusts and nothing noticed.
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
EOF

cat > "$tmp/bin/truncate" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$logs/truncate"
printf 'stub\n' > "\$3"
EOF

# run-vm.sh resolves its engine on PATH, so a stub keeps this test off real QEMU.
cat > "$tmp/bin/qemu-system-x86_64" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$logs/qemu"
EOF
chmod 0755 "$tmp/bin/qemu-img" "$tmp/bin/truncate" "$tmp/bin/qemu-system-x86_64"

# A base the overlay can name. Its content is never read: qemu-img is a stub.
base="$tmp/base.qcow2"
printf 'stub base\n' > "$base"

run_vm() {
  env PATH="$tmp/bin:$PATH" VM_CACHE="$cache" VM_BASE_IMAGE="$base" \
    VM_DISK_SIZE=48G VM_DATA_SIZE=12G "$vm/run-vm.sh" --disks-only "$@"
}

if ! run_vm >"$tmp/run.log" 2>&1; then
  cat "$tmp/run.log" >&2
  fail "the disk write path did not complete"
fi

# The overlay names the base it was given, and the requested size, not a default.
line="$(cat "$logs/qemu-img")"
prefix="create -f qcow2 -F qcow2 -b $base $cache/vm-disk.qcow2.new."
case "$line" in
  "$prefix"*" 48G") ;;
  *) fail "qemu-img was not asked for the overlay: $line" ;;
esac
pid_part="${line#"$prefix"}"
pid_part="${pid_part% 48G}"
case "$pid_part" in
  ''|*[!0-9]*) fail "the overlay was not written to a temporary name: $line" ;;
esac

line="$(cat "$logs/truncate")"
prefix="-s 12G $cache/data.img.new."
case "$line" in
  "$prefix"*) ;;
  *) fail "truncate was not asked for the data disk: $line" ;;
esac
case "${line#"$prefix"}" in
  ''|*[!0-9]*) fail "the data disk was not written to a temporary name: $line" ;;
esac

# A temporary name that survives is a disk the next run would silently reuse.
leftovers="$(compgen -G "$cache/*.new.*" || true)"
[ -z "$leftovers" ] || fail "temporary disk names survived: $leftovers"

[ -s "$cache/vm-disk.qcow2" ] || fail "no OS disk after the create path"
[ -s "$cache/data.img" ] || fail "no data disk after the create path"

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

echo "the disk write path creates both disks and renames them into place"
