# Changelog

All notable changes to this project. One entry per landed change, newest first.

## Unreleased

### Added

- Fedora toolbox container image with OpenCode installed from the verified glibc
  npm artifact, pinned and sha512-checked at build time. The upstream ghcr image
  is musl-only and cannot be inherited on a glibc base.
- Idle gate that deallocates the VM after 45 idle minutes, with five busy signals,
  an operator pin file, boot grace, and fail-closed probes.
- Key Vault bootstrap writing `/etc/opencode/env` at mode 0600, and managed-identity
  ACR login writing `/etc/containers/auth.json`, both over IMDS with no Azure CLI
  on the host.
- Image pipeline that builds, smoke-gates before promotion, promotes to `:prod`,
  and records the resolved digest for rollback.
- OS image publish script and pipeline, using Fedora's own Azure VHD because
  Fedora publishes no CoreOS image in the Azure marketplace.
- Butane source and a compiled Ignition document, plus the podman quadlet that
  runs the container with every persistent path on the data disk.
- Idempotent tailnet join with a durable, non-ephemeral node and SSH over tailnet
  identity.
- Terraform that boots from the published managed image with Ignition, with no
  public IP and an explicit deny for inbound internet traffic.
- Guard tests for the three invariants that are easy to regress: no public
  ingress, no scheduled hard stop, and a destroy-protected data disk.
- Wake-and-connect wrapper that starts the VM, polls health, then opens the TUI.
- `tests/verify.sh`, one gate that runs every suite then shellchecks every script.
- Pull-request verification pipeline that gates on the verification suite: checks a
  PR pipeline has a `pr:` trigger with path filters, does not reference
  `azureSubscription`, installs shellcheck, runs `tests/verify.sh`, and installs
  shellcheck before running tests.
- Operating runbook covering data disk restore, container and OS rollback,
  tailnet rejoin, snapshot pruning, and the idle gate.

### Fixed

- `srv-data.mount` was rejected by systemd, because a mount unit's `Where=` must
  match its filename. Renamed to `srv.mount`.
- The Logic App recurrence used `week_days`, which the azurerm provider does not
  accept. Corrected to `on_these_days`.
- Persistent session data was mounted from a podman named volume, which lands on
  the OS disk and would be lost on every VM rebuild. Now bind mounts under `/srv`.
- `get.coreos-installer.dev` does not resolve. The OS pipeline uses the pinned
  upstream container instead.
- Four test assertions could not fail: a fake curl that assumed the URL was the
  last argument, JSON defaults that broke on brace expansion, a pipeline subshell
  that swallowed `exit 1`, and a digest check that returned `echo`'s status.
- An idle-gate script committed mode 0644 made every test pass vacuously.

### Known gaps

- No `terraform plan` or `apply` has run: no subscription available here.
- The container image has never been built: no container engine available here.
- Both pipeline files parse as YAML but have never executed.
- `pipelines/devbox-image.yml` and `pipelines/devbox-os.yml` carry placeholder
  registry and storage account names that must be set before first use.
