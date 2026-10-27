#!/usr/bin/env bash
# Exercise os/build-os-image.sh offline. Fake podman and az sit on PATH, so
# nothing is built and no Azure call is made.
#
# Covers what a machine without the real tools can prove: the source is ucore and
# not plain Fedora CoreOS, each precondition refuses before any work, and DRY_RUN
# still prints a usable image id.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
script="$here/../build-os-image.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }

bash_bin="$(command -v bash)"
mkdir -p "$tmp/bin" "$tmp/bare"

# Writes the vhd the real builder would write, into whatever --output-dir it got.
# Records the image reference so the source can be checked without a build.
cat > "$tmp/bin/podman" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$tmp/podman-calls"
dir=""
prev=""
for a in "\$@"; do
  [ "\$prev" = "--output-dir" ] && dir="\$a"
  prev="\$a"
done
[ -n "\$dir" ] || { echo "fake podman: no --output-dir" >&2; exit 1; }
mkdir -p "\$dir"
printf 'not a real vhd\n' > "\$dir/disk.vhd"
EOF

cat > "$tmp/bin/az" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$tmp/az-calls"
EOF
chmod +x "$tmp/bin/podman" "$tmp/bin/az"
: > "$tmp/az-calls"
: > "$tmp/podman-calls"

id_re='^/subscriptions/.+/providers/Microsoft\.Compute/images/.+$'

# T0: the source image is ucore, pinned by digest, and produced by image-builder.
# A plain Fedora CoreOS build boots a host with no tailscaled, zincati in place of
# ucore's update path, and none of the assumptions every host unit makes.
grep -q 'ghcr.io/ublue-os/ucore' "$script" \
  || fail "T0 build script does not reference the ucore image"
grep -Eq 'ghcr\.io/ublue-os/ucore@sha256:[0-9a-f]{64}' "$script" \
  || fail "T0 ucore image is not pinned by digest"
grep -q 'image-builder' "$script" \
  || fail "T0 build script does not use image-builder to produce a bootc disk image"
if grep -q 'coreos-installer download' "$script"; then
  fail "T0 build script still downloads the plain Fedora CoreOS VHD"
fi

# T1: no podman, so the script refuses and names the tool.
rc=0
out="$(PATH="$tmp/bare" RG=rg-x STORAGE_ACCOUNT=stx "$bash_bin" "$script" 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "T1 exited 0 with podman absent"
case "$out" in
  *"podman not installed"*) ;;
  *) fail "T1 message does not name podman: $out" ;;
esac

# T2: podman present, az absent. Refuse, and name az.
mkdir -p "$tmp/naz"
cp "$tmp/bin/podman" "$tmp/naz/"
rc=0
out="$(PATH="$tmp/naz" RG=rg-x STORAGE_ACCOUNT=stx "$bash_bin" "$script" 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "T2 exited 0 with az absent"
case "$out" in
  *"az not installed"*) ;;
  *) fail "T2 message does not name az: $out" ;;
esac

# T3: DRY_RUN runs everything but the build, the upload and the image create.
# Progress goes to stderr, so stdout is only the machine-readable id.
rc=0
PATH="$tmp/bin:$PATH" DRY_RUN=1 RG=rg-x \
  STORAGE_ACCOUNT=stx "$bash_bin" "$script" >"$tmp/out" 2>"$tmp/err" || rc=$?
[ "$rc" -eq 0 ] || fail "T3 dry run exited $rc: $(cat "$tmp/err")"

last="$(tail -1 "$tmp/out")"
printf '%s\n' "$last" | grep -Eq "$id_re" \
  || fail "T3 last stdout line is not an image id: $last"
case "$last" in
  */images/devbox-ucore-*) ;;
  *) fail "T3 image id does not name the ucore build: $last" ;;
esac

grep -q "dry run: would build" "$tmp/out" \
  || fail "T3 no dry-run line in stdout: $(cat "$tmp/out")"
[ ! -s "$tmp/az-calls" ] || fail "T3 dry run called az: $(cat "$tmp/az-calls")"
[ ! -s "$tmp/podman-calls" ] || fail "T3 dry run built an image: $(cat "$tmp/podman-calls")"

echo "all build-os-image tests passed"
