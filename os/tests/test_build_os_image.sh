#!/usr/bin/env bash
# Exercise os/build-os-image.sh offline. Fake image-builder, podman, and az sit on
# PATH, so no container is pulled, no vhd is real, and no Azure call is made.
#
# Covers what a machine without the real tools can prove: each precondition
# refuses before any work, a tag is rejected, and DRY_RUN still prints a usable
# image id without touching a tool.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
script="$here/../build-os-image.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }

# Absolute path: the precondition cases run with a stripped PATH.
bash_bin="$(command -v bash)"
mkdir -p "$tmp/bin" "$tmp/bare"

# Writes the vhd the real tool would write, into whatever --output-dir it got.
# It also records the bootc ref, so a test can prove the pin reached the build.
# In container mode the flag is /output and the host path is the bind mount, so
# --output-dir /output maps to $tmp/output; resolve it the way the bind mount does.
cat > "$tmp/bin/image-builder" <<EOF
#!/usr/bin/env bash
# Record argv before parsing it: the parse loop below consumes its arguments.
printf '%s\n' "\$*" > "$tmp/args-used"
dir=""
ref=""
inside=0
while [ "\$#" -gt 0 ]; do
  case "\$1" in
    --output-dir) dir="\$2"; shift 2 ;;
    --bootc-ref) ref="\$2"; shift 2 ;;
    *) shift ;;
  esac
done
[ -n "\$dir" ] || { echo "fake image-builder: no --output-dir" >&2; exit 1; }
# The container sees /output; the test's bind mount puts that at "$tmp/output".
case "\$dir" in
  /output) dir="$tmp/output" ;;
esac
printf '%s\n' "\$ref" > "$tmp/ref-used"
printf 'not a real vhd\n' > "\$dir/ucore.vhd"
EOF

cat > "$tmp/bin/podman" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$tmp/podman-calls"
# Only 'run' emulates the builder container; 'pull' just records and succeeds.
[ "\${1:-}" = "run" ] || exit 0
shift
host=""
args=()
while [ "\$#" -gt 0 ]; do
  case "\$1" in
    --rm|--privileged) shift ;;
    --security-opt) shift 2 ;;
    --volume)
      case "\$2" in
        *:/output) host="\${2%:/output}" ;;
      esac
      shift 2
      ;;
    build) shift ;;
    *) args+=("\$1"); shift ;;
  esac
done
# Rewrite the in-container output path to the host directory it is bound to, which
# is what the real bind mount does.
rewritten=()
for a in "\${args[@]}"; do
  [ "\$a" = "/output" ] && a="\$host"
  rewritten+=("\$a")
done
[ -n "\$host" ] || { echo "fake podman: no /output mount" >&2; exit 1; }
exec "$tmp/bin/image-builder" "\${rewritten[@]}"
EOF

# Records every call, so a dry run can prove it created nothing.
cat > "$tmp/bin/az" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$tmp/az-calls"
EOF
chmod +x "$tmp/bin/image-builder" "$tmp/bin/podman" "$tmp/bin/az"
: > "$tmp/az-calls"
: > "$tmp/podman-calls"

id_re='^/subscriptions/.+/providers/Microsoft\.Compute/images/.+$'
digest='@sha256:7906a70efe7482704fdb232c7e5d2a3068a0c5520ef46d3f7f6b9f8fc0e899b9'

# T1: no image-builder, so the script refuses and names the tool.
rc=0
out="$(PATH="$tmp/bare" RG=rg-x STORAGE_ACCOUNT=stx "$bash_bin" "$script" 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "T1 exited 0 with image-builder absent"
case "$out" in
  *"image-builder not installed"*) ;;
  *) fail "T1 message does not name image-builder: $out" ;;
esac

# T2: image-builder present, podman absent. Refuse, and name podman. The pull is
# what puts the bootc ref in local storage, so a missing podman must stop the
# build rather than surface later as a missing-image error.
mkdir -p "$tmp/nopod"
cp "$tmp/bin/image-builder" "$tmp/nopod/"
rc=0
out="$(PATH="$tmp/nopod" RG=rg-x STORAGE_ACCOUNT=stx "$bash_bin" "$script" 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "T2 exited 0 with podman absent"
case "$out" in
  *"podman not installed"*) ;;
  *) fail "T2 message does not name podman: $out" ;;
esac

# T3: image-builder and podman present, az absent. Refuse, and name az.
mkdir -p "$tmp/noaz"
cp "$tmp/bin/image-builder" "$tmp/bin/podman" "$tmp/noaz/"
rc=0
out="$(PATH="$tmp/noaz" RG=rg-x STORAGE_ACCOUNT=stx "$bash_bin" "$script" 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "T3 exited 0 with az absent"
case "$out" in
  *"az not installed"*) ;;
  *) fail "T3 message does not name az: $out" ;;
esac

# T4: a tag is refused. A moving tag would publish a different OS on a later run
# while the pipeline reported success, so this must fail before any pull.
rc=0
out="$(PATH="$tmp/bin:$PATH" RG=rg-x STORAGE_ACCOUNT=stx \
  UCORE_IMAGE=ghcr.io/ublue-os/ucore-minimal:stable "$bash_bin" "$script" 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "T4 accepted a tag instead of a digest"
case "$out" in
  *"pinned by digest"*) ;;
  *) fail "T4 message does not explain the digest requirement: $out" ;;
esac
[ ! -s "$tmp/podman-calls" ] || fail "T4 pulled before rejecting the tag: $(cat "$tmp/podman-calls")"

# T4b: a digest prefix with nothing after it is not a pin either. A test for
# `@sha256:` alone accepted this, so the check requires the full 64 hex digits.
rc=0
out="$(PATH="$tmp/bin:$PATH" RG=rg-x STORAGE_ACCOUNT=stx \
  UCORE_IMAGE=ghcr.io/ublue-os/ucore-minimal@sha256: "$bash_bin" "$script" 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "T4b accepted an empty digest as a pin"
case "$out" in
  *"pinned by digest"*) ;;
  *) fail "T4b message does not explain the digest requirement: $out" ;;
esac
[ ! -s "$tmp/podman-calls" ] || fail "T4b pulled before rejecting the empty digest"

# T5: DRY_RUN answers before any tool or credential is required, and calls
# nothing. That ordering is the point: the runbook tells the operator to run this
# before a storage account exists, so requiring one here would make it useless.
# Progress goes to stderr, so stdout is only the machine-readable id.
rc=0
PATH="$tmp/bare" DRY_RUN=1 "$bash_bin" "$script" >"$tmp/out" 2>"$tmp/err" || rc=$?
[ "$rc" -eq 0 ] || fail "T5 dry run exited $rc without RG or tools: $(cat "$tmp/err")"

last="$(tail -1 "$tmp/out")"
printf '%s\n' "$last" | grep -Eq "$id_re" \
  || fail "T5 last stdout line is not an image id: $last"
case "$last" in
  */images/devbox-ucore-*) ;;
  *) fail "T5 image id does not name the ucore image: $last" ;;
esac

grep -q "dry run: would build a vhd" "$tmp/out" \
  || fail "T5 no dry-run line in stdout: $(cat "$tmp/out")"
[ ! -s "$tmp/az-calls" ] || fail "T5 dry run called az: $(cat "$tmp/az-calls")"
[ ! -s "$tmp/podman-calls" ] || fail "T5 dry run called podman: $(cat "$tmp/podman-calls")"

# T6: the real path pulls the pinned ref, builds from it, and creates a Gen2
# image. Gen1 would reject a UEFI bootc vhd, and the ref must reach the build or
# the digest pin is decoration.
rc=0
PATH="$tmp/bin:$PATH" RG=rg-x STORAGE_ACCOUNT=stx "$bash_bin" "$script" \
  >"$tmp/out6" 2>"$tmp/err6" || rc=$?
[ "$rc" -eq 0 ] || fail "T6 real path exited $rc: $(cat "$tmp/err6")"

grep -q "$digest" "$tmp/podman-calls" \
  || fail "T6 did not pull the pinned ref: $(cat "$tmp/podman-calls")"
grep -q "$digest" "$tmp/ref-used" 2>/dev/null \
  || fail "T6 did not pass the pinned ref to image-builder: $(cat "$tmp/ref-used" 2>/dev/null || echo none)"
grep -q -- "--hyper-v-generation V2" "$tmp/az-calls" \
  || fail "T6 did not create a Gen2 image: $(cat "$tmp/az-calls")"

# The root filesystem is not optional: image-builder refuses a Fedora bootc
# container without it, and the refusal arrives after the pull, which is slow and
# confusing. Assert the flag the builder actually received, not the source text.
grep -q -- "--bootc-default-fs" "$tmp/args-used" \
  || fail "T6 did not pass --bootc-default-fs to image-builder: $(cat "$tmp/args-used" 2>/dev/null || echo none)"

# T7: the container path, which is what a non-Fedora CI runner takes. It must
# work with no host binary at all, must run privileged with the shared container
# storage (or the pulled ref is invisible), and must pass the same pinned ref and
# Gen2 settings as the host path.
#
# The PATH here holds the fakes and the few coreutils the script needs, and
# nothing else. Building it deliberately is what makes "no host binary" a fact
# the test proves rather than a claim it repeats.
mkdir -p "$tmp/nobuilder"
for tool in bash mktemp rm find sha256sum date; do
  ln -sf "$(command -v "$tool")" "$tmp/nobuilder/$tool"
done
cp "$tmp/bin/podman" "$tmp/bin/az" "$tmp/nobuilder/"
if PATH="$tmp/nobuilder" command -v image-builder >/dev/null 2>&1; then
  fail "T7 precondition: image-builder is on the stripped PATH, so this cannot prove container mode stands alone"
fi

: > "$tmp/ref-used"
rc=0
PATH="$tmp/nobuilder" RG=rg-x STORAGE_ACCOUNT=stx \
  IMAGE_BUILDER_CONTAINER=ghcr.io/osbuild/image-builder-cli@pinned \
  "$bash_bin" "$script" >"$tmp/out7" 2>"$tmp/err7" || rc=$?
[ "$rc" -eq 0 ] || fail "T7 container path exited $rc without a host image-builder: $(cat "$tmp/err7")"

grep -q -- "--privileged" "$tmp/podman-calls" \
  || fail "T7 did not run the builder privileged, which mounting a disk requires"
grep -q -- "/var/lib/containers/storage" "$tmp/podman-calls" \
  || fail "T7 did not share container storage, so the pulled bootc ref is invisible to the builder"
grep -q -- "image-builder-cli@pinned" "$tmp/podman-calls" \
  || fail "T7 did not run the requested builder container: $(cat "$tmp/podman-calls")"
grep -q "$digest" "$tmp/ref-used" 2>/dev/null \
  || fail "T7 did not pass the pinned ref to the builder in container mode"
grep -q -- "--hyper-v-generation V2" "$tmp/az-calls" \
  || fail "T7 did not create a Gen2 image"

echo "all build-os-image tests passed"
