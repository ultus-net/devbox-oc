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
  grep -Fqx "plan: podman push --tls-verify=false 127.0.0.1:5099/devbox:$variant" "$tmp/steps" \
    || fail "the plan does not push $variant to the fixture"
done

# A push to the real registry would be a production mutation.
if grep -E 'podman push .*ghcr\.io' "$tmp/steps" >/dev/null; then
  fail "the plan pushes to the published registry"
fi

echo "the rollback fixture stays on loopback and builds FROM the published image"
