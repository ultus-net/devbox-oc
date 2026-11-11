# Changelog

All notable changes to this project. One entry per landed change, newest first.

## Unreleased

### Added

- The VM harness rehearses the container rollback. The procedure was documented
  but never executed, and moving the recorded digest to test it would need new
  media and a reinstall. `vm/fixture-registry.sh` now runs a Fedora registry
  (`docker-distribution`, not the Alpine `registry:2`) on `127.0.0.1`, pulls the
  published image, and pushes two tags built FROM it as `devbox:older` and
  `devbox:newer`, keeping the digest each push wrote. The guest reaches the
  registry at qemu's `10.0.2.2` and `vm/run-vm.sh` boots the `:newer` push
  digest, so the quadlet carries a digest exactly as the media does. The guest
  proves a bare restart leaves that digest alone, pulls `:older`, rewrites
  `Image=` to the older digest the way the runbook rolls a host back, reloads
  the generator, restarts, and proves the running image moved. The overlay marks
  only that fixture host insecure, and the run is the default; `--no-rollback`
  boots the published image instead, and `VM_IMAGE` or `--console` skip the
  fixture. The host refuses a default run without a working podman, removes the
  fixture container on every exit path, and requires the six rollback PASS lines
  when the guest pulled the fixture image, so a skipped rehearsal cannot read as
  green. The guest restores the auto-update timer it stopped.
  `vm/tests/test_fixture_registry.sh` holds the loopback bind, the
  build-from-published-image rule, the digest file per push, and the
  no-push-to-GHCR rule, and `vm/tests/test_overlay_merge.sh` holds the insecure
  drop-in.
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

- Following the Hermes tag is recorded as an accepted risk. The timer pulls
  whatever `docker.io/nousresearch/hermes-agent:latest` serves, unattended and as
  root, and `podman auto-update` keeps a new image only if the health probe
  passes. Decision 14 now says so, reviewed on 2026-11-11 and due again by
  2027-02-11, and the README and the runbook repeat it. A digest pin was rejected
  because it would freeze another team's releases until a reviewed commit, and
  this image is consumed as published.
- The container image is pinned by digest. The media baked
  `ghcr.io/ultus-net/devbox:prod`, so whatever GHCR served under that tag when
  the host first started was what it ran, and `AutoUpdate=registry` kept pulling
  it unattended as root. `os/butane/build.sh` now resolves the digest recorded in
  `image/prod-digest.txt` through `os/butane/image-ref.sh` and bakes
  `<repo>@sha256:<digest>` into the quadlet and into `RESTIC_IMAGE`, so
  `oc-backup` runs the same pinned image. A tag, a reference with an empty path
  component, a digest that is not the recorded one, or a record with nothing to
  pin fails the build, and podman verifies the pulled content against the
  digest. The OpenCode quadlet no longer sets `AutoUpdate`, so the container no
  longer updates itself: a new digest is a reviewed commit plus a rebuilt
  Ignition, and `docs/runbook.md` documents the in-place unit edit a rollback
  needs. The Hermes waiver image still follows its upstream tag.
- The VM rollback rehearsal follows the pinned unit. It boots the digest the
  fixture push wrote and rewrites `Image=` to the older digest, then reloads the
  generator and restarts, instead of re-pointing a tag the pinned host no longer
  follows. `docs/vm.md` describes the steps and the digest the harness keeps.
- The linter is pinned. The verify workflow installed shellcheck from the runner
  image, so CI reported `SC2329` on a head the local 0.10.0 gate passed. The
  workflow now downloads v0.11.0 and checks its sha256, `tests/verify.sh` fails
  when the binary it finds is not that release, and `tests/ci_shape.sh` holds the
  version, the checksum and the absence of the apt install. `.tools/shellcheck`
  is the same release.
- The toolbox base is the released Fedora stream, not a rawhide snapshot. The
  pin moves from the `fedora-toolbox` digest behind the `46` tag, whose config
  label reads `rawhide` and which was built 2026-10-23, to the digest behind `45`
  and `latest`, labelled `45` and built 2026-11-10. Both digests were read from
  the registry, and the tag label is not treated as a version signal: a bump is
  a deliberate PR that reads the new digest from the registry.
  `image/tests/test_base_pin.sh` fails if the base stops being a Fedora image
  consumed by digest, or if the build no longer starts `FROM` the pin.
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

- The CI shape guard trusted text it never ran, and only caught an
  apt-installed shellcheck when the command fit on one line. `tests/ci_shape.sh`
  matched each physical line, so an `apt-get install -y` split onto a second line
  with a backslash continuation slipped past it, and a checksum inside
  `if false; then ... fi` passed as though it ran. The guard now joins backslash
  continuations, compares the `Install shellcheck` step to the pinned command
  sequence, and runs that step against stubs to record the calls it makes, so a
  branch, a redefinition, an early `exit` or a rewritten command fails. A call
  the stubs do not record cannot hide behind matching text.
- The verify gate only worked from the repo root. `tests/verify.sh` resolved its
  suite paths, its script `find` and its Butane and shellcheck lookups from
  `$PWD`, so a run from anywhere else failed on paths that did not exist there.
  The gate now resolves the repository root from its own path, changes to it, and
  reads the linter pin and local tools from that root. `tests/test_gate_cwd.sh`
  runs the gate twice, from the repository root and from a throwaway directory,
  and requires the same suite lines, the lint step and a pass from both, so a cwd
  run that found only a subset fails. The child prints its skipped suite instead
  of dropping it silently, and the suite fails if a workflow ever sets
  `VERIFY_INNER`.
- The Hermes health check proved nothing about the workload. `HealthCmd=hermes
  --version` answered whenever the binary ran, so a gateway that never served
  still reported healthy, and `podman auto-update` would keep that image. The
  upstream image ships no health check and cannot be rebuilt, so Ignition now
  writes `host/bin/hermes-health.sh` to `/usr/local/bin`, and the quadlet mounts
  that one file read-only at the same path. The probe requests
  `http://127.0.0.1:8642/health` inside the container and requires a `200` whose
  body names the `hermes-agent` platform; a redirect or error status fails even
  with a healthy-looking body, and `/health/detailed` needs the Bearer key, so the
  unauthenticated path is the probe. `host/tests/test_hermes_health.sh` runs the
  script against a real loopback server and rejects a `302`, a `401`, a `500`, a
  body naming another platform, and a refused port.
  `host/tests/test_quadlet_health.sh` now covers both quadlets and ties each
  command to how its script is installed, and `host/tests/test_hermes_quadlet.sh`
  allows only the read-only same-path mount beyond the `/srv` state.
- The digest repair path could not succeed. The workflow token is not permitted
  to open a pull request, so every main build pushed a `chore/prod-digest` branch
  and then failed at `gh pr create`, and the open-PR guard could not see the
  leaked branch. `image/promote-digest.sh` now pushes the branch, prints a
  compare URL and fails, and it refuses to push while any `chore/prod-digest-`
  branch exists on the remote. The `record-digest` job drops `pull-requests:
  write` and `GH_TOKEN`. A main push that changes only `image/prod-digest.txt`
  no longer builds, because the rebuild stamped a new digest and re-staled the
  record the merge had just fixed; path filters are not evaluated for tag pushes,
  so a release still builds. `tests/ci_shape.sh` holds the trigger paths and the
  narrowed permissions, and `image/tests/test_promote_digest.sh` asserts the
  repair never calls `gh`.
- The rollback record could go stale without anything failing.
  `image/tests/test_digest_record.sh` accepted `PENDING`, and nothing compared
  the file with the live `:prod` digest, which is how it sat out of date while
  `:prod` had moved. The main build now reads the pushed digest bare and runs
  `image/promote-digest.sh`, which compares it with the record through
  `image/check-prod-digest.sh` and fails the run when they differ. On a stale
  record it repairs the file with `image/write-prod-digest.sh`, proves the repair
  passes its own check, and pushes a `chore/prod-digest-<run-id>` branch, because
  a workflow token cannot push to `main`. It pushes one branch at a time rather
  than one per run. The repair runs in a `record-digest` job that
  depends on `build`, so the write token never sits on the job that executes
  PR-controlled code. `PENDING` stays a valid shape only before the first build.
  `image/tests/test_prod_digest.sh` drives the two helpers against fixtures,
  `image/tests/test_promote_digest.sh` drives the repair against stub `git`, and
  `tests/ci_shape.sh` reads the parsed workflow to keep the permissions
  in that job.
- The docs claimed more than the tree did. The README suite table listed 24
  suites while `tests/verify.sh` ran 30, so it read as the list while hiding six;
  `tests/docs_suite_table.sh` now compares both documents and fails when a suite
  has no row, a row outlives its suite, or either side lists one twice.
  `docs/vm.md` names the `vm/fetch-fcos.sh` flags `run-vm.sh` relies on,
  `image/toolchains.txt` stops claiming npm builds the OpenCode artifact, and
  `docs/design.md` records that a separate operator PR writes the promoted digest
  because the workflow token cannot push to `main`.
- The rollback procedure did not move the image the host runs. `docs/runbook.md`
  told the operator to re-point `:prod` and restart, but neither quadlet sets
  `Pull=`, so a restart reused the local image and the rollback changed nothing
  until the auto-update timer fired. The procedure now re-points the tag with
  `podman pull`/`tag`/`push`, pulls `:prod` on the host, restarts, and proves the
  result with `podman image inspect --format '{{.RepoDigests}}'`, which can hold
  both the index and the per-architecture digest. The previous digest comes from
  the git history of `image/prod-digest.txt`, the push writes its digest to a
  file, and the rollback ends by recording the digest that is now live.
  `podman auto-update` is documented as the one-step alternative, not as a repair
  for a tag that did not move.
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
  pin cannot revert to optional unnoticed. At that point the quadlet still ran
  `opencode --version` as its health check, because the published `:prod` image
  did not carry `devbox-health` yet and the VM dogfood run pulls `:prod`; the
  switch landed once `:prod` carried the script.
  `image/prod-digest.txt` held `PENDING-FIRST-BUILD` while `:prod` had been live
  since 2026-11-04, so the rollback record named no image; it recorded the digest
  `sha256:fa87259b…` of the last successful `main` build (run 42899375906) and
  now holds `sha256:a158e9c1…` from run 42907276884, after this gate and the disk
  write path test landed.
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
