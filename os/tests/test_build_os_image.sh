#!/usr/bin/env bash
# Exercise os/build-os-image.sh offline. Fake coreos-installer and az sit on
# PATH, so nothing is downloaded and no Azure call is made.
#
# Covers what a machine without the real tools can prove: each precondition
# refuses before any work, and DRY_RUN still prints a usable image id.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
script="$here/../build-os-image.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }

# Absolute path: the precondition cases run with a stripped PATH.
bash_bin="$(command -v bash)"
mkdir -p "$tmp/bin" "$tmp/bare"

# Writes the vhd the real tool would write, into whatever --directory it got.
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
printf 'not a real vhd\n' > "$dir/fedora-coreos-43.20261027.3.0-azure.x86_64.vhd"
EOF

# Records every call, so a dry run can prove it created nothing.
cat > "$tmp/bin/az" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$tmp/az-calls"
EOF
chmod +x "$tmp/bin/coreos-installer" "$tmp/bin/az"
: > "$tmp/az-calls"

id_re='^/subscriptions/.+/providers/Microsoft\.Compute/images/.+$'

# T1: no coreos-installer, so the script refuses and names the tool.
rc=0
out="$(PATH="$tmp/bare" RG=rg-x STORAGE_ACCOUNT=stx "$bash_bin" "$script" 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "T1 exited 0 with coreos-installer absent"
case "$out" in
  *"coreos-installer not installed"*) ;;
  *) fail "T1 message does not name coreos-installer: $out" ;;
esac

# T2: coreos-installer present, az absent. Refuse, and name az.
mkdir -p "$tmp/naz"
cp "$tmp/bin/coreos-installer" "$tmp/naz/"
rc=0
out="$(PATH="$tmp/naz" RG=rg-x STORAGE_ACCOUNT=stx "$bash_bin" "$script" 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "T2 exited 0 with az absent"
case "$out" in
  *"az not installed"*) ;;
  *) fail "T2 message does not name az: $out" ;;
esac

# T3: DRY_RUN runs everything but the upload and the image create.
# Progress goes to stderr, so stdout is only the machine-readable id.
rc=0
PATH="$tmp/bin:$PATH" DRY_RUN=1 STREAM=stable RG=rg-x \
  STORAGE_ACCOUNT=stx "$bash_bin" "$script" >"$tmp/out" 2>"$tmp/err" || rc=$?
[ "$rc" -eq 0 ] || fail "T3 dry run exited $rc: $(cat "$tmp/err")"

last="$(tail -1 "$tmp/out")"
printf '%s\n' "$last" | grep -Eq "$id_re" \
  || fail "T3 last stdout line is not an image id: $last"
case "$last" in
  */images/devbox-fcos-stable-*) ;;
  *) fail "T3 image id does not carry the stream: $last" ;;
esac

grep -q "dry run: would upload" "$tmp/out" \
  || fail "T3 no dry-run line in stdout: $(cat "$tmp/out")"
grep -q "downloading FCOS stable" "$tmp/err" \
  || fail "T3 the download never ran: $(cat "$tmp/err")"
[ ! -s "$tmp/az-calls" ] || fail "T3 dry run called az: $(cat "$tmp/az-calls")"

echo "all build-os-image tests passed"
