#!/usr/bin/env bash
# Serve two disposable tags from a loopback registry for the rollback rehearsal.
#
# The harness must not move the real :prod tag. This starts a Fedora registry
# bound to 127.0.0.1, builds two tags FROM the image the host runs, and pushes
# them as devbox:older and devbox:newer. The guest reaches the registry at
# 10.0.2.2, the qemu user-network address of the host loopback.
#
# usage: fixture-registry.sh up|down|plan
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
cache="${VM_CACHE:-$repo_root/.vm-cache}"
port="${VM_REGISTRY_PORT:-5000}"
base="${VM_FIXTURE_BASE:-ghcr.io/ultus-net/devbox:prod}"
registry_image="${VM_REGISTRY_IMAGE:-localhost/devbox-vm-registry:fedora}"
name="devbox-vm-registry"
storage="$cache/registry"
image_repo="127.0.0.1:$port/devbox"
plan="${VM_REGISTRY_PLAN:-0}"
case "${1:-}" in
  plan) plan=1 ;;
esac

run() {
  if [ "$plan" = 1 ]; then
    printf 'plan: %s\n' "$*" >&2
    return 0
  fi
  "$@"
}

down() {
  if [ "$plan" = 1 ]; then
    printf 'plan: podman rm -f %s\n' "$name" >&2
    return 0
  fi
  podman rm -f "$name" >/dev/null 2>&1 || true
}

registry_image_present() {
  podman image exists "$registry_image" 2>/dev/null
}

build_registry() {
  if registry_image_present; then
    return 0
  fi
  run podman build -f "$here/fixtures/registry.Containerfile" -t "$registry_image" "$here/fixtures"
}

start() {
  down
  run mkdir -p "$storage" || return 1
  if [ "$plan" = 0 ]; then
    rm -rf "${storage:?}"/* || return 1
  fi
  run podman run -d --rm --name "$name" \
    -p "127.0.0.1:$port:5000" \
    -v "$storage:/var/lib/registry:Z" \
    "$registry_image" || return 1
  if [ "$plan" = 1 ]; then
    return 0
  fi
  local ok=0
  for _ in $(seq 1 60); do
    if curl -fsS --max-time 2 "http://127.0.0.1:$port/v2/" >/dev/null 2>&1; then
      ok=1
      break
    fi
    sleep 1
  done
  if [ "$ok" = 0 ]; then
    podman logs "$name" >&2 || true
    echo "the fixture registry did not answer on 127.0.0.1:$port" >&2
    return 1
  fi
}

seed() {
  # Each step returns on failure: this function runs under a caller that tests
  # its status, where set -e does not fire.
  run podman pull "$base" || return 1
  local variant
  for variant in older newer; do
    # The label is the only difference, so both tags carry the shipped image.
    run podman build \
      -f "$here/fixtures/image.Containerfile" \
      --build-arg "BASE=$base" \
      --build-arg "VARIANT=$variant" \
      -t "$image_repo:$variant" \
      "$here/fixtures" || return 1
    run podman push --tls-verify=false "$image_repo:$variant" || return 1
  done
}

case "${1:-}" in
  up)
    build_registry
    # An image build or a push can fail after the container exists. Remove it on
    # that path too, so a failed up never leaves the port held.
    if ! start || ! seed; then
      down
      echo "the fixture registry setup failed; removed the container" >&2
      exit 1
    fi
    echo "fixture registry ready: $image_repo:newer (older tag also pushed)"
    ;;
  down)
    down
    ;;
  plan)
    build_registry
    start
    seed
    ;;
  *)
    echo "usage: $0 up|down|plan" >&2
    exit 2
    ;;
esac
