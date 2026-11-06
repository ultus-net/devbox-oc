# Changelog

All notable changes to this project. One entry per landed change, newest first.

## Unreleased

### Added

- Hermes control plane alongside OpenCode. A second podman quadlet
  (`host/quadlet/hermes.container`) runs the official `nousresearch/hermes-agent`
  image as the assistant that schedules and delegates work to the OpenCode
  server. The two containers share the `devbox` podman network
  (`host/quadlet/devbox.network`), so Hermes reaches `http://opencode:4096` by
  name with neither port leaving loopback. Both publish on `127.0.0.1` only and
  persist their state under `/srv/hermes/data`.
- `hermes-env` host script and `hermes-env.service`. It reads
  `/etc/devbox/secrets.env`, filters to an allowlist, and writes `/etc/hermes/env`
  as a 0600 file. It fails closed on a missing `OPENCODE_PASSWORD`,
  `API_SERVER_KEY` or model provider key, and the quadlet carries
  `Requires=hermes-env.service`.
- `oc-tailnet` now publishes three tailnet-only mounts: OpenCode on 443, the
  Hermes dashboard on 8443, and the Hermes gateway API on 10000, each proxying a
  loopback port. This is the one place the repo consumes a non-Fedora image; the
  waiver is scoped to that container and recorded as design decision 14.
- `host/tests/test_hermes-env.sh` and `host/tests/test_hermes_quadlet.sh` guard
  the new env writer, the quadlet shape and the backup ordering. Both are wired
  into `tests/verify.sh`.
- Bare-metal deployment path. Ignition for Fedora CoreOS installation media, one
  enabled rebase to `ghcr.io/ublue-os/ucore-minimal:stable`, a separate data disk
  mounted at `/srv`, masked sleep targets, and a logind policy that ignores idle.
  `docs/install.md` is the first-install procedure.
- `oc-env`, `oc-backup`, `oc-restic`, `oc-tailnet` and `oc-tailnet-up` host
  scripts. The env writer fails closed on an empty password. The backup runs
  restic in the Fedora image, mounts data read-only, refuses an unmounted `/srv`,
  and never prunes. The tailnet join is idempotent, key-driven, deletes the key
  after a successful join, and cannot latch the box off the tailnet.
- GitHub Actions CI. `verify.yml` runs the repo gate with pinned Butane and
  shellcheck. `image.yml` builds the container, smoke-gates it before pushing to
  GHCR, and only pushes from the default branch or a tag.
- `docs/design.md` recording the bare-metal architecture, the pivot, the hardware
  risks the cloud hid, and the decisions behind them.
- `docs/runbook.md` rewritten for backup, restore, prune, rollback, data-disk
  replacement, OS-disk replacement and hardware checks.
- `docs/web-access.md`, the tailnet-only client path. It records the served
  address and its valid spellings, HTTP Basic sign-in, the same-origin CORS
  rule, the `/` versus `/api/info` check, the backup window that interrupts a
  long turn, teardown, and the failure table. It names every OpenTunnel route
  that would publish the server and keeps remote access off. The responses were
  measured against OpenCode 2.1.4, the version pinned in the image, and the doc
  states that no serve mount has run on the Mini. `tests/docs_complete.sh` now
  scopes its invariant assertions to that section, and
  `host/tests/test_cockpit_loopback.sh` rejects a Funnel call.
- Fedora toolbox container image with OpenCode installed from the verified glibc
  npm artifact, pinned and sha512-checked at build time. The upstream ghcr image
  is musl-only and cannot be inherited on a glibc base.
- Guards for every invariant: data-disk persistence, loopback-only listeners,
  masked sleep, fail-closed env, restic retention, tailnet join, Ignition
  reproducibility, no Azure leftovers, CI shape and docs coverage.

### Changed

- Pivoted from an Azure VM to an always-on HP laptop in a server room. The
  workload is unchanged: ucore host, podman quadlet, tailnet-only reachability,
  separate data disk. Secrets now come from `/etc/devbox/secrets.env`, written by
  the operator after first boot. Backups are restic to an off-box repository, not
  a managed disk snapshot.
- Retargeted the host from the laptop to the HP EliteDesk G4 35W Desktop Mini.
  The build now requires a 35W T-series CPU, 16 GiB or more across two SODIMM
  slots, the OS on one M.2 NVMe, `/srv` on a second physical device (the second
  M.2 slot or a 2.5 inch SATA caddy), a 65W external adapter, and a UPS.
- The Tailscale auth key is optional at build time. A keyless build ships no key,
  and the operator joins from the console after first boot. Ignition now writes a
  `getty@tty1` autologin drop-in, because Fedora CoreOS ignores
  `coreos.autologin` and the console is the only door before the join.
- The data disk is prepared once from the live media and mounted by its `data`
  label. Ignition never partitions or formats it, so an OS reinstall cannot wipe
  `/srv`.
- `sshd` is masked. Tailscale SSH runs inside `tailscaled` and is the only shell
  path, so no second listener sits on the wired LAN.
- `oc-backup` stops the workload before the snapshot and starts it again after,
  so the SQLite session store is not captured mid-write.
- The container image is built and smoke-tested in GitHub Actions and published
  to GHCR. The smoke test runs before the push, so a broken image never lands.

### Removed

- `terraform/`, `pipelines/`, `tools/oc`, their fixtures and their guards. There
  is no cloud subscription in the deploy path any more.
- `host/bin/lib-imds.sh`, `oc-secrets`, `oc-acr-login`, `oc-idle-check` and
  `oc-snapshot`, plus the unit files and tests that drove them.
- `docs/pipelines.md`, `docs/deployment-plan.md`,
  `docs/headless-hosting-options.md` and `docs/superpowers/`.
- The `HandleLidSwitch*` logind policy and the lid checks in the install and
  runbook. The Mini has no lid, so only the sleep masks and `IdleAction=ignore`
  remain.
- The hosted `ucore-minimal` VHD build, the managed-disk publish path, the
  Key Vault bootstrap, the ACR login, the idle deallocator and the `oc` wake
  wrapper. None of them has a purpose on a box with no control plane.

### Fixed

- `host/tests/test_nosleep.sh` requires `IdleAction=ignore` under `[Login]`, so a
  commented-out or mis-sectioned setting no longer passes the guard.
- `os/butane/build.sh` stages Butane's output and moves it into place only after
  the assertions pass, so a failed compile cannot leave an empty Ignition file.
- `os/butane/build.sh` refuses placeholder values unless the placeholder build
  sets `ALLOW_PLACEHOLDERS=1`, so an install cannot ship a dummy disk path.
- `oc-env` parses `secrets.env` as data instead of sourcing it, and writes the
  environment file atomically at mode 0600.
- `oc-restic` passes only `RESTIC_*`, `AWS_*` and `B2_*` variables, so the
  OpenCode password never reaches the backup container.
- The tailscale wants symlink is written directly, because `enabled: true` on a
  unit that does not exist yet does not produce a usable link on Fedora CoreOS.
- The Ignition `srv.mount` uses `TimeoutSec=30` in `[Mount]`; the
  `x-systemd.device-timeout` option is only read from `/etc/fstab`.

### Known gaps

- No install has run on the target Mini, and no live boot has been tested.
- The container image has never been built by the GitHub Actions workflow.
- The restic restore drill has not been executed against a real repository.
- The ucore rebase path is documented upstream but unexercised on this hardware.
- `podman-auto-update.timer` is not gated on idleness. It follows `:prod` on its
  own schedule and restarts the container when the tag moves, so an update can
  land during a running session. The health check decides whether the new image
  is kept, not whether a session is in flight.
- `systemd-analyze verify` cannot check the quadlet: it rejects a `.container`
  file, because the podman generator, not systemd, produces the unit.
- The GHCR package must be public, or the host needs a read-only pull token. The
  install doc calls this out; nothing enforces it.
