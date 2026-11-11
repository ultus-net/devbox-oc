#!/usr/bin/env bash
# host/tests/test_oc_backup.sh
#
# Run oc-backup against a fake podman. The properties that matter are the Fedora
# image, the restic entrypoint, the read-only data mount, the SELinux label
# handling, the filtered environment, and the absence of snapshot deletion.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
script="$here/../bin/oc-backup"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }

mkdir -p "$tmp/bin" "$tmp/data"
: > "$tmp/calls"
cat > "$tmp/bin/podman" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$CALLS"
while [ $# -gt 0 ]; do
  if [ "$1" = "--env-file" ]; then cp "$2" "$ENVCOPY"; fi
  shift
done
EOF
chmod +x "$tmp/bin/podman"
printf 'OPENCODE_PASSWORD=server-secret\nRESTIC_REPOSITORY=s3:https://s3.example.invalid/devbox-restic\nRESTIC_PASSWORD=x\n' \
  > "$tmp/secrets.env"
# The build bakes a digest, so the fixture is one. A tag here would let a backup
# that rewrote the reference pass unnoticed against the shipped shape.
digest=5b9d548651dade448e26ca449ec0611ffe1a0a3d77c241deead3022302f7b5ec
image="ghcr.io/ultus-net/devbox@sha256:$digest"
printf 'RESTIC_IMAGE=%s\n' "$image" > "$tmp/backup.env"

run_backup() (
  env PATH="$tmp/bin:$PATH" CALLS="$tmp/calls" ENVCOPY="$tmp/envcopy" \
    IMAGE_FILE="$tmp/backup.env" REQUIRE_MOUNT=0 \
    SECRETS_FILE="$tmp/secrets.env" DATA_DIR="$tmp/data" "$script"
)

run_backup >/dev/null || fail "oc-backup exited non-zero"
calls="$(cat "$tmp/calls")"

case "$calls" in
  *--entrypoint\ restic*) ;;
  *) fail "restic is not the container entrypoint: $calls" ;;
esac
case "$calls" in
  *"ghcr.io/ultus-net/devbox@sha256:$digest"*) ;;
  *) fail "the backup did not use the digest the build writes: $calls" ;;
esac
case "$calls" in
  *":prod"*)
    fail "the backup ran a tag the build no longer writes: $calls"
    ;;
esac
case "$calls" in
  *--security-opt\ label=disable*) ;;
  *) fail "the read is not allowed past the workload SELinux label: $calls" ;;
esac
case "$calls" in
  *"--volume $tmp/data:/data:ro"*) ;;
  *) fail "the data directory is not mounted read-only: $calls" ;;
esac
case "$calls" in
  *" backup /data --tag devbox") ;;
  *) fail "the backup command is not the expected one: $calls" ;;
esac
case "$calls" in
  *forget*|*prune*)
    fail "a backup run deletes snapshots; retention must stay manual: $calls"
    ;;
esac

case "$calls" in
  *"--env-file"*) ;;
  *) fail "restic is run without an env file: $calls" ;;
esac
case "$calls" in
  *"--env-file $tmp/secrets.env"*)
    fail "restic reads the whole secrets file, including the OpenCode password: $calls"
    ;;
esac
grep -qx 'RESTIC_REPOSITORY=s3:https://s3.example.invalid/devbox-restic' "$tmp/envcopy" \
  || fail "the restic environment is missing its repository"
if grep -q 'OPENCODE_PASSWORD' "$tmp/envcopy"; then
  fail "the OpenCode password is passed to the backup container"
fi

# T0: /srv must be an actual mountpoint. The directory exists on the OS disk when
# var-srv.mount fails, so a backup of it would look successful and store nothing.
rc=0
env PATH="$tmp/bin:$PATH" CALLS="$tmp/calls" IMAGE_FILE="$tmp/backup.env" \
  SECRETS_FILE="$tmp/secrets.env" DATA_DIR="$tmp/data" "$script" \
  >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail "oc-backup accepted an unmounted data directory"

# T2: a missing secrets file must stop before any container starts.
rm -f "$tmp/secrets.env"
rc=0
run_backup >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail "oc-backup ran with no secrets file"

# T3: an unset image is a configuration failure, not a silent fallback to an
# Alpine image or a local binary. Restore the secrets so the image check is what
# fails, not the earlier credential check.
printf 'RESTIC_REPOSITORY=s3:https://s3.example.invalid/devbox-restic\nRESTIC_PASSWORD=x\n' \
  > "$tmp/secrets.env"
rc=0
printf '\n' > "$tmp/empty-image.env"
env PATH="$tmp/bin:$PATH" IMAGE_FILE="$tmp/empty-image.env" REQUIRE_MOUNT=0 \
  SECRETS_FILE="$tmp/secrets.env" DATA_DIR="$tmp/data" \
  "$script" >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail "oc-backup ran with no image configured"

echo "oc-backup uses the Fedora image, read-only and never prunes"
