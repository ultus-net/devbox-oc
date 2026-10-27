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
- OS image publish script and pipeline, building a VHD from the pinned ucore
  bootc image with `image-builder`. Fedora publishes no CoreOS image in the Azure
  marketplace, and Fedora's own VHD is plain CoreOS rather than ucore.
- Butane source and a compiled Ignition document, plus the podman quadlet that
  runs the container with every persistent path on the data disk.
- Idempotent tailnet join with a durable, non-ephemeral node and SSH over tailnet
  identity.
- Terraform that boots from the published managed image with Ignition, with no
  public IP and an explicit deny for inbound internet traffic.
- Guard test asserting the Key Vault name stays derivable from tfvars, so a
  revert to a random suffix fails the gate rather than the first deploy.
- Guard tests for the three invariants that are easy to regress: no public
  ingress, no scheduled hard stop, and a destroy-protected data disk.
- Wake-and-connect wrapper that starts the VM, polls health, then opens the TUI.
- `tests/verify.sh`, one gate that runs every suite then shellchecks every script.
- Copyable `terraform.tfvars.example` documenting every required variable without
  defaults, so a first `plan` fails on a value rather than on a missing file.
- Pull-request verification pipeline that runs the whole suite on any PR touching
  the devbox subtree. It holds no service connection, so a fork can run it.
- Operating runbook covering first deployment from clone to a connected client,
  plus data disk restore, container and OS rollback, tailnet rejoin, snapshot
  pruning, and the idle gate.

### Fixed

- Three defects made a correctly deployed box unreachable. `tailscaled` was never
  enabled, so the tailnet join had no daemon to talk to and the box was
  Bastion-only. The Tailscale auth key was a required variable that no resource
  wrote to Key Vault, so the join read a secret that did not exist. And the OS
  pipeline published Fedora's plain CoreOS VHD instead of ucore, so the host ran
  an OS with no `tailscaled` package, zincati in place of ucore's update path, and
  none of the assumptions every host unit makes. Each now has a guard that was
  observed failing before its fix.
- The quadlet's `EnvironmentFile` is now guarded: every file it names must have a
  component that writes it, and the password variable must match on both sides.
  A config pointing at a file nothing produces is how the tailnet key went
  missing, and it fails at boot as an unset variable rather than a missing file.
- The Key Vault name is derived from the subscription id instead of a random
  suffix, so Ignition can be generated before the first apply. A random suffix
  made first deployment circular: Ignition needs the name, the name needed the
  apply, and the apply needs the Ignition.
- `srv-data.mount` was rejected by systemd, because a mount unit's `Where=` must
  match its filename. Renamed to `srv.mount`.
- The Logic App recurrence used `week_days`, which the azurerm provider does not
  accept. Corrected to `on_these_days`.
- Persistent session data was mounted from a podman named volume, which lands on
  the OS disk and would be lost on every VM rebuild. Now bind mounts under `/srv`.
- `get.coreos-installer.dev` does not resolve, and Fedora's Azure VHD is plain
  CoreOS rather than ucore. The OS pipeline now builds from the pinned ucore
  image with `image-builder`, and no longer uses `coreos-installer` at all.
- Four test assertions could not fail: a fake curl that assumed the URL was the
  last argument, JSON defaults that broke on brace expansion, a pipeline subshell
  that swallowed `exit 1`, and a digest check that returned `echo`'s status.
- An idle-gate script committed mode 0644 made every test pass vacuously.
- A failed secret bootstrap used to serve nothing while still billing. The quadlet
  now carries `Requires=oc-secrets.service`, and the idle gate treats an unreadable
  API as idle when the container is not running, so the box stops either way.
- On first boot with a failed Key Vault fetch there is no env file, and the idle
  gate exited there without ever probing, so the box still billed. It now falls
  through with no password and lets the container check decide.
- `os/butane/build.sh` wrote Butane's output straight into the target, so a failed
  compile left an empty file where a bootable Ignition document was. It now stages
  the output and moves it into place only after the assertions pass.
- The Key Vault suffix is sized against the prefix instead of truncating the
  assembled name, which silently ate hex characters at the longest prefix.
- Three guards could pass on text that did not mean what they claimed: a
  state-derived hash satisfied the vault-derivability check, a `Requires=` line
  inside `[Container]` satisfied the dependency check, and an `echo` mentioning
  `tests/verify.sh` satisfied the pipeline check.

### Known gaps

- No `terraform plan` or `apply` has run: no subscription available here.
- The container image has never been built: no container engine available here.
- All three pipeline files parse as YAML but have never executed.
- `pipelines/devbox-image.yml` and `pipelines/devbox-os.yml` carry placeholder
  registry and storage account names that must be set before first use.
- `systemd-analyze verify` cannot check the quadlet: it rejects a `.container`
  file, because the podman generator, not systemd, produces the unit.
