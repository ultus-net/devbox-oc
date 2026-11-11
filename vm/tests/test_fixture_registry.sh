#!/usr/bin/env bash
# vm/tests/test_fixture_registry.sh
#
# The rollback rehearsal must never move the published :prod tag. This checks
# the fixture plan: a Fedora registry bound to loopback, two local tags built
# FROM the published image, and a plain-HTTP push to the fixture only.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
vm="$(cd "$here/.." && pwd)"
fail() { echo "FAIL: $1" >&2; exit 1; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

registry_containerfile="$vm/fixtures/registry.Containerfile"
image_containerfile="$vm/fixtures/image.Containerfile"
[ -s "$registry_containerfile" ] || fail "no registry Containerfile"
[ -s "$image_containerfile" ] || fail "no fixture image Containerfile"

# The registry base is pinned by digest, not by a tag that can move.
grep -Eq '^FROM .*@sha256:[0-9a-f]{64}$' "$registry_containerfile" \
  || fail "the registry base is not pinned by digest"
grep -q 'docker-distribution' "$registry_containerfile" \
  || fail "the registry Containerfile does not install the Fedora package"

# The fixture image is built FROM the image the host runs, so only the label
# differs between the two tags.
# shellcheck disable=SC2016  # the ${...} are Containerfile variables, not shell
grep -qxF 'ARG BASE' "$image_containerfile" || fail "the fixture image has no BASE argument"
# shellcheck disable=SC2016
grep -qxF 'FROM ${BASE}' "$image_containerfile" || fail "the fixture image is not built FROM BASE"
# shellcheck disable=SC2016
grep -qxF 'LABEL org.ultus.devbox.vm-fixture=${VARIANT}' "$image_containerfile" \
  || fail "the fixture image does not label its variant"
# Two tags need distinct manifests. A metadata-only label can be served from the
# build cache under one digest, so the variant must change a layer too.
grep -qF '/tmp/devbox-vm-fixture' "$image_containerfile" \
  || fail "the fixture image has no variant layer"

VM_CACHE="$tmp" VM_REGISTRY_PORT=5099 VM_REGISTRY_IMAGE=localhost/devbox-vm-registry:test \
  "$vm/fixture-registry.sh" plan >"$tmp/out" 2>"$tmp/plan" \
  || fail "the fixture plan failed"
grep -F 'plan: ' "$tmp/plan" > "$tmp/steps" || fail "the plan printed no steps"

# The registry is reachable from the guest at 10.0.2.2, which the qemu user
# network maps to the host loopback. Publishing on any other address would open
# it to the LAN.
grep -Fqx "plan: podman run -d --rm --name devbox-vm-registry -p 127.0.0.1:5099:5000 -v $tmp/registry:/var/lib/registry:Z localhost/devbox-vm-registry:test" "$tmp/steps" \
  || fail "the registry is not published on 127.0.0.1:5099"
if grep -Fq '0.0.0.0:' "$tmp/steps"; then
  fail "the registry plan binds a wildcard address"
fi

# Both tags are built FROM the published image and pushed to the fixture.
grep -Fqx "plan: podman pull ghcr.io/ultus-net/devbox:prod" "$tmp/steps" \
  || fail "the plan does not pull the published image"
for variant in older newer; do
  grep -Fq -- "--build-arg BASE=ghcr.io/ultus-net/devbox:prod" "$tmp/steps" \
    || fail "the $variant build does not use the published image"
  grep -Fq -- "--build-arg VARIANT=$variant" "$tmp/steps" \
    || fail "the plan does not build the $variant variant"
  grep -Fqx "plan: podman push --tls-verify=false --digestfile $tmp/fixture-$variant.digest 127.0.0.1:5099/devbox:$variant" "$tmp/steps" \
    || fail "the plan does not push $variant to the fixture with its digest file"
done

# A push to the real registry would be a production mutation.
if grep -E 'podman push .*ghcr\.io' "$tmp/steps" >/dev/null; then
  fail "the plan pushes to the published registry"
fi

# A failed start or seed must remove the container it just created. A stub
# podman records every call, so the cleanup is observed, not read from source.
live="$tmp/live"
mkdir -p "$live/bin"
cat > "$live/bin/podman" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$PODMAN_LOG"
case "$1 $2" in
  "image exists") exit 0 ;;
  "run -d") echo deadbeef; exit 0 ;;
  "pull ghcr.io/ultus-net/devbox:prod") exit "${PODMAN_PULL_STATUS:-0}" ;;
  "rm -f") exit 0 ;;
esac
exit 0
EOF
printf '#!/bin/sh\nexit 0\n' > "$live/bin/sleep"
chmod 0755 "$live/bin/podman" "$live/bin/sleep"

# A registry that never answers: the start loop gives up and removes it.
printf '#!/bin/sh\nexit 1\n' > "$live/bin/curl"
chmod 0755 "$live/bin/curl"
PODMAN_LOG="$live/start.log"
export PODMAN_LOG
if PATH="$live/bin:$PATH" VM_CACHE="$live/cache" VM_REGISTRY_PORT=5098 \
  "$vm/fixture-registry.sh" up >"$live/start.out" 2>&1; then
  fail "the fixture survived a registry that never answered"
fi
# One removal clears the pre-start container and one is the failure cleanup.
start_rm="$(grep -cx 'rm -f devbox-vm-registry' "$PODMAN_LOG" || true)"
[ "${start_rm:-0}" -ge 2 ] || fail "a failed start left the registry container behind"

# A registry that answers but fails the seed pull: the up path removes it.
printf '#!/bin/sh\nexit 0\n' > "$live/bin/curl"
PODMAN_LOG="$live/seed.log" PODMAN_PULL_STATUS=3
export PODMAN_LOG PODMAN_PULL_STATUS
if PATH="$live/bin:$PATH" VM_CACHE="$live/cache" VM_REGISTRY_PORT=5098 \
  "$vm/fixture-registry.sh" up >"$live/seed.out" 2>&1; then
  fail "the fixture survived a failed seed"
fi
unset PODMAN_PULL_STATUS
seed_rm="$(grep -cx 'rm -f devbox-vm-registry' "$PODMAN_LOG" || true)"
[ "${seed_rm:-0}" -ge 2 ] || fail "a failed seed left the registry container behind"

echo "the rollback fixture stays on loopback and builds FROM the published image"
