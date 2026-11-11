# Agent instructions: devbox-oc

This repo builds a portable bare-metal development server that hosts OpenCode.
Read `~/.config/opencode/STANDARDS.md` and
`~/.config/opencode/style/coding-style.md` first. Those rules apply here in full.
This file records only what is specific to this repository, and it wins where the
two disagree.

## What this repo is

One always-on HP EliteDesk G4 35W Desktop Mini, two disks, two images. The host
is ucore-minimal, a Fedora CoreOS derived image consumed from upstream. The
toolchain runs in a Fedora toolbox container under podman. Two workloads share a
private podman network: OpenCode, the interactive dev server, and Hermes, the
assistant that schedules and delegates work to it. Both are reached over a
private tailnet with no public listener. The data disk is `/srv`, separate from
the OS disk.

This repo is the source of truth for the host configuration and the container
image. It ships no cloud infrastructure.

## Non-negotiables

These are load-bearing. A change that breaks one is a correctness bug, not a
preference.

- **Fedora family only.** No Ubuntu, Debian, or Alpine at any layer: OS, base
  image, or container. `ubuntu-latest` appears in `.github/workflows/*.yml` as
  the CI runner, which is not a shipped layer and is allowed.
- **No public listener and no inbound port forward.** Reachability is Tailscale.
  `tailscale serve` publishes loopback with real TLS.
  `os/butane/tests/test_no_azure.sh` keeps the Azure network path deleted.
- **Everything that listens, listens on loopback.** ucore-minimal installs the
  Cockpit packages but not `cockpit-ws`, so `cockpit.socket` does not exist and
  nothing answers on 9090. An Ignition drop-in rebinds it to `127.0.0.1` if a
  future image ships it, and `sshd` is masked because the server firewall profile
  would expose it on the LAN.
  `host/tests/test_cockpit_loopback.sh` and `host/tests/test_no_lan_listener.sh`
  guard both. The OpenCode port is published as `127.0.0.1:4096:4096`.
- **Always on. No scheduled stop and no idle deallocation.** Sleep targets are
  masked and logind sets `IdleAction=ignore`. A UPS and firmware power-on after
  AC loss are required. `host/tests/test_nosleep.sh` guards the sleep policy.
- **The data disk is a separate physical device.** Reinstalling the OS must never
  destroy `/srv`. It is prepared once from the live media and addressed by
  `/dev/disk/by-id` then mounted by its `data` label. Ignition never partitions
  or formats it.
- **Runtime secrets come from `/etc/devbox/secrets.env` at first boot.** No
  shipped file may define `OPENCODE_PASSWORD`, `API_SERVER_KEY` or a model
  provider key by any route, because Ignition ships as the install media's config
  and stays readable. Only the scoped Tailscale auth key
  rides the install media, and only in a keyed build. A keyless build
  (`TS_AUTHKEY` unset) ships no key and the operator joins from the console.
  `oc-env` writes `/etc/opencode/env` and `hermes-env` writes `/etc/hermes/env`;
  each fails closed on a missing key and each is `Requires=` by its quadlet.

- **A keyless build keeps a console door.** Ignition writes a `getty@tty1`
  autologin drop-in for `core`, because a keyless box has no tailnet and `sshd`
  is masked. `os/butane/tests/test_keyless_build.sh` guards the empty key and the
  drop-in.
- **Retention stays manual.** `oc-backup` never calls `restic forget` or
  `restic prune`.

## Verification

One gate runs everything:

```sh
./tests/verify.sh
```

It must end with `VERIFY: all suites pass`. It is a real gate, not a formality:
it fails rather than skips when `shellcheck` or PyYAML is missing, and it fails
when the local shellcheck is not the release pinned in
`.github/workflows/verify.yml`.

`./vm/run-vm.sh --rebuild` is the end-to-end rehearsal, and it runs before bare
metal rather than after. The same Ignition, the ucore rebase, the data-disk
mount, both containers and every loopback port run under QEMU. A change under
`os/butane/`, `host/`, `image/` or a quadlet is not ready for the Mini until a
run ends with `VM DOGFOOD: pass`. `tests/verify.sh` guards the harness itself;
the run is the evidence. `docs/vm.md` is the procedure.

**Set `BUTANE` when you change anything under `os/butane/`.** Without it the
artifact reproducibility check prints `SKIP` and the gate still returns 0. Pass a
Butane 0.29.0 binary:

```sh
BUTANE=/path/to/butane ./tests/verify.sh
```

The pinned version and its sha256 are in `.github/workflows/verify.yml`.

## How the tests are written

- **Assert behaviour, not text.** The recurring defect in this repo is a guard
  that decides a property of a script by reading its source. Run the thing.
- **Prove a test can fail.** Every guard here was verified against a mutation
  that it catches. A guard that has never failed has not been tested.
- **Grep the mutation before trusting the result.** Several rounds produced
  false passes from a mutation that never landed.
- **A rule is only as wide as its reader.** A guard that walks named keys misses
  the same string in a drop-in. Parse the document and walk its scalars.

## Layout

| Path | What lives there |
|---|---|
| `host/bin/` | scripts baked into the image: env writer, restic backup, tailnet join and serve |
| `host/quadlet/` | the podman quadlet for the OpenCode container |
| `host/tests/` | behavioural guards for those scripts and the quadlet |
| `os/butane/` | Ignition source (`ucore.bu`), build scripts, and the compiled `ucore.ign` |
| `image/` | toolbox container: Dockerfile, toolchains, smoke test, digest record |
| `.github/workflows/` | verify gate and the GHCR image build |
| `tests/` | the one verification gate and the docs/CI guards |
| `vm/` | QEMU dogfood harness: pinned FCOS base, Ignition overlay, guest checks (`docs/vm.md`) |
| `docs/` | design, first install, the runbook, and the VM harness procedure |

`os/butane/ucore.ign` is a compiled artifact and must stay byte-identical to what
`os/butane/build-placeholder.sh` produces. Never hand-edit it.

## Git

Follow the branch and commit prefixes in `STANDARDS.md`. Open a PR to `main` and
never push to it directly. Record every landed change in `CHANGELOG.md` in the
same commit.

Track work as GitHub issues, link the PR with `Fixes #<id>`, and close the issue
in the PR that lands the work.

## What is not verified here

No install has run on the target Mini and no live boot has been tested there.
`vm/run-vm.sh` exercises the same Ignition under QEMU, including the ucore
rebase and the container start path, and a full run passes on a workstation. It
cannot verify the firmware, the two physical disk ids, the tailnet join, the
UPS, or the thermals. The container image has been built by the workflow and
pulled in the VM. The attested publish was read once by hand on 2026-11-12:
`:prod` is an index with an `attestation-manifest` child, and the provenance and
SBOM fields returned a SLSA document and an SPDX 2.3 document with 456 packages.
Nothing re-reads them on a later pull. The restic restore drill has not been
executed. Do not describe anything as working until it has run against real
hardware.
`README.md` lists the same gaps; keep them in step.
