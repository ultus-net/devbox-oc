# Changelog

All notable changes to this project. One entry per landed change, newest first.

## Unreleased

### Added

- QEMU dogfood harness. `vm/run-vm.sh` boots a pinned Fedora CoreOS QEMU
  image, applies the Ignition compiled from `os/butane/ucore.bu`, waits for the
  one-shot ucore rebase, then runs a check suite inside the guest. The guest
  posts its report to `vm/report-agent.py` bound to `127.0.0.1`, reached at
  `10.0.2.2` over qemu's user network, so the harness adds no inbound listener.
  The overlay appends a serial console, the data-disk preparation and the check
  unit; it never edits the shipped Ignition. The guest check fails, rather than
  notes, when no boot target wants a quadlet unit. It reads port bindings from
  `podman port` and probes each loopback port, inspects logind's Manager property
  for `IdleAction`, and writes the fallback report only when `/srv` is a real
  mountpoint. It reads the booted deployment only, so a staged ucore that has not
  booted cannot pass the rebase assertion. The report agent refuses a truncated
  post, and `vm/report-verdict.sh` requires `SUMMARY failures=0` before the run
  prints a pass. `vm/tests/` guards the merge, the boot command, the guest check's
  helper definitions, the booted-deployment parse and the parent-device
  comparison, the agent's truncated-post refusal, the verdict, and the data-disk
  root-device refusal in both its bare and `[/ostree/...]` spellings. Those suites
  are wired into `tests/verify.sh`, and `docs/vm.md` is checked by
  `tests/docs_complete.sh`. A full `--rebuild` run at the tip passed on
  2026-11-11: `VM DOGFOOD: pass`, zero failures, one `SKIP` for the absent Cockpit
  socket.
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

- The VM rehearsal is the documented step before bare metal, not an optional
  extra. `README.md` leads with it, `docs/install.md` opens with a new step 0 that
  requires `VM DOGFOOD: pass`, `docs/runbook.md` carries the procedure for a host
  change, and `AGENTS.md` makes a passing run the readiness condition for anything
  under `os/butane/`, `host/`, `image/` or a quadlet. `docs/vm.md` gains a "When
  to run it" section, which also names the changes that need no run.
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

- The quadlet health command only proved the binary ran. `HealthCmd` was
  `opencode --version`, so a build that booted but never served still reported
  healthy, and `podman auto-update` would have kept it. It now runs
  `/usr/local/bin/devbox-health`, which probes `/api/info` and accepts the `401`
  the runbook calls healthy. `host/tests/test_quadlet_health.sh` ties the
  quadlet to the Dockerfile COPY target, so a path drift or a return to a version
  probe fails the gate. The generated `os/butane/ucore.ign` is rebuilt from the
  new quadlet.
- The disk write path had no test. `vm/tests/test_run_args.sh` proved the plan
  matched the command, but nothing ran the create steps, so deleting either `mv`
  in `run-vm.sh` kept every suite green and an aborted create could leave a
  `*.new.*` disk that a later run silently ignored. `vm/tests/test_disk_write.sh`
  runs `run-vm.sh --disks-only` with stub `qemu-img` and `truncate` on `PATH`. It
  asserts the exact overlay and truncate argv at non-default sizes, that both
  disks land under their final names, that no temporary name survives, that a
  second run reuses them without calling either stub, and that `--rebuild`
  recreates both. A failed create now removes its temporary, and the test drives
  that with a stub that fails after writing, so the leftover cannot come back.
  Dropping either `mv`, or the cleanup, fails it. `VM_BASE_IMAGE` skips the pinned
  base download for that test, and `--disks-only` stops before QEMU and needs
  neither Butane, KVM nor the QEMU binary. `--help` now prints the whole header,
  and `vm/tests/test_run_args.sh` T4d guards that range.
- The image gate could pass an image that never serves. `image/smoke.sh` accepted
  any semver from `opencode --version` and never started the server, so an image
  that booted but served nothing passed the gate. The image now ships
  `/usr/local/bin/devbox-health`, which probes `/api/info` and accepts the `401`
  the runbook already calls healthy; `image/tests/test_healthcheck.sh` drives it
  through a stub `curl` and pins every answer, including the URL it probes. The
  smoke gate requires `SMOKE_OC_VERSION` so the pin cannot turn itself off, pins
  the built binary against the Dockerfile's `OC_VERSION`, starts the container on
  loopback, requires `401` on `/api/info`, requires the health command to pass,
  and requires it to fail against a URL that serves nothing. A missing pin now
  fails the gate, and `image/tests/test_smoke_requires_pin.sh` holds that, so the
  pin cannot revert to optional unnoticed. The quadlet still runs
  `opencode --version` as its health check: switching it to `devbox-health` is
  #23, because the published `:prod` image does not carry the script yet and the
  VM dogfood run pulls `:prod`.
  `image/prod-digest.txt` held `PENDING-FIRST-BUILD` while `:prod` had been live
  since 2026-11-04, so the rollback record named no image; it now records the
  digest `sha256:fa87259b…` of the last successful `main` build (run
  42899375906).
- `vm/tests/test_run_args.sh` T6 read `run-vm.sh` for `qemu-img` and `truncate`
  instead of running it, the text-reading defect this repo's test rules forbid.
  The disk steps now go through `run_step`, which prints the argv under
  `--dry-run` and runs it otherwise, so the plan cannot drift from the write. The
  dry run also reports `plan: reuse <path>` for a disk it would keep, and
  `vm/fetch-fcos.sh --print-base` names the base without downloading it. T6
  asserts the exact plan for an empty cache, a populated one and `--rebuild`,
  using sizes other than the defaults so a baked-in size cannot pass; a mutation
  pointing the overlay at the data disk, one dropping the truncate, one dropping
  the reuse line, and one ignoring `--rebuild` each fail it.
- The docs claimed ucore ships and enables Cockpit. ucore-minimal installs the
  Cockpit packages but not `cockpit-ws`, so `cockpit.socket` does not exist and
  nothing listens on 9090. The Ignition drop-in stays as a guard for an image
  that does ship the socket, and `AGENTS.md`, design decision 9, the web-access
  diagram and the test docstring now say so. Found by the QEMU harness, which
  skips the Cockpit assertion when the socket is absent.
- systemd-resolved answered LLMNR on 5355 and mDNS on 5353 on every interface.
  Neither is a systemd socket, so the sshd mask and the Cockpit rebind could not
  close them. An Ignition drop-in sets `LLMNR=no` and `MulticastDNS=no`. The
  harness's TCP scan reported the LLMNR listener; mDNS is UDP, so the config guard
  is what keeps both off. `host/tests/test_no_lan_listener.sh` now reads the
  effective `[Resolve]` values in drop-in order and fails on a commented-out
  switch, a wrong section or a later override, with a mutation for each.
- The data disk mounts at `/var/srv`, not `/srv`. On Fedora CoreOS and ucore
  `/srv` is a symlink to `var/srv`, and systemd refuses a mount on a path that
  contains a symlink, so `srv.mount` failed on every boot and `/srv` stayed a
  plain directory on the OS disk. The unit is now `var-srv.mount`, and the VM
  check compares the parent block devices behind `/srv` and `/var`, so a second
  partition on the OS disk cannot pass as a separate device.
  `os/butane/tests/test_data_mount.sh` covers the unit name, the mount path and
  every dependency. It reads `Where=` and `What=` from `[Mount]`, and a mutation
  that moves them to `[Unit]` proves a section-blind grep cannot pass.
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
- The container image has been built by the GitHub Actions workflow and pulled in
  the VM, but it has not run on the Mini.
- The restic restore drill has not been executed against a real repository.
- The ucore rebase has run under QEMU, not on the Mini.
- `podman-auto-update.timer` is not gated on idleness. It follows `:prod` on its
  own schedule and restarts the container when the tag moves, so an update can
  land during a running session. The health check decides whether the new image
  is kept, not whether a session is in flight.
- `systemd-analyze verify` cannot check the quadlet: it rejects a `.container`
  file, because the podman generator, not systemd, produces the unit.
- The GHCR package must be public, or the host needs a read-only pull token. The
  install doc calls this out; nothing enforces it.
