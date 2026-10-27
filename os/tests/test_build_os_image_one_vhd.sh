#!/usr/bin/env bash
# os/tests/test_build_os_image_one_vhd.sh
#
# A download directory that yields two .vhd files must abort. Uploading the first
# match would ship an arbitrary artifact, and the audited hash would describe a
# file nobody chose.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
script="$here/../build-os-image.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }
bash_bin="$(command -v bash)"
mkdir -p "$tmp/bin"

# Writes two vhds, which the real tool never does, to exercise the count check.
cat > "$tmp/bin/coreos-installer" <<'EOF'
#!/usr/bin/env bash
dir=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --directory) dir="$2"; shift 2 ;;
    *) shift ;;
  esac
done
[ -n "$dir" ] || { echo "fake coreos-installer: no --directory" >&2; exit 1; }
printf 'one\n' > "$dir/a.vhd"
printf 'two\n' > "$dir/b.vhd"
EOF
cat > "$tmp/bin/az" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$tmp/az-calls"
EOF
chmod +x "$tmp/bin/coreos-installer" "$tmp/bin/az"
: > "$tmp/az-calls"

rc=0
out="$(PATH="$tmp/bin:$PATH" RG=rg-x STORAGE_ACCOUNT=stx "$bash_bin" "$script" 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "two vhds did not abort the build"
case "$out" in
  *"expected exactly one vhd"*) ;;
  *) fail "abort message does not explain the count: $out" ;;
esac
[ ! -s "$tmp/az-calls" ] || fail "it uploaded before checking the count: $(cat "$tmp/az-calls")"

echo "a download producing two vhds aborts before uploading"
