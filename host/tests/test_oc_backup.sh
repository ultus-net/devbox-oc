#!/usr/bin/env bash
# host/tests/test_oc_backup.sh
#
# Run oc-backup against a fake podman. The properties that matter are the pinned
# image, the env file it reads, the read-only data mount, and the absence of any
# snapshot deletion.
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
printf 'OPENCODE_PASSWORD=server-secret\nRESTIC_REPOSITORY=sftp:backup@nas.example:/srv/restic/devbox\nRESTIC_PASSWORD=x\n' \
  > "$tmp/secrets.env"

run_backup() (
  env PATH="$tmp/bin:$PATH" CALLS="$tmp/calls" ENVCOPY="$tmp/envcopy" \
    SECRETS_FILE="$tmp/secrets.env" DATA_DIR="$tmp/data" "$script"
)

run_backup >/dev/null || fail "oc-backup exited non-zero"
calls="$(cat "$tmp/calls")"

case "$calls" in
  *"docker.io/restic/restic@sha256:"*) ;;
  *) fail "restic image is not pinned by digest: $calls" ;;
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
grep -qx 'RESTIC_REPOSITORY=sftp:backup@nas.example:/srv/restic/devbox' "$tmp/envcopy" \
  || fail "the restic environment is missing its repository"
if grep -q 'OPENCODE_PASSWORD' "$tmp/envcopy"; then
  fail "the OpenCode password is passed to the backup container"
fi
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
    fail "a backup run deletes snapshots: retention must stay manual: $calls"
    ;;
esac

# T2: a missing secrets file must stop before any container starts.
rm -f "$tmp/secrets.env"
rc=0
run_backup >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail "oc-backup ran with no secrets file"

echo "oc-backup is pinned, read-only and never prunes"
