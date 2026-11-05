# devbox-oc

An AI development server on an HP EliteDesk G4 35W Desktop Mini in a server
room. It runs ucore-minimal, a Fedora CoreOS derived image, as an immutable host,
runs the OpenCode server in a podman container, and is reached only over a
private tailnet. The OS disk and the data disk are separate, and a nightly restic
backup leaves the box.

## Why it exists

Local dev environments drift and break in ways that cost hours and produce
nothing. Here the environment is two images plus a data disk, so recovery is a
rebuild rather than a repair.

The box used to be an Azure VM. Terraform, Key Vault, ACR, the idle
deallocator, and the wake wrapper are gone with it: the Mini has no control
plane to pay for and no reason to scale to zero. `docs/design.md` records the
pivot and its reasons.

## Architecture

```mermaid
flowchart LR
  TUI["TUI<br/>opencode --server"] --> TN
  DESK["Desktop app<br/>pairing link"] --> TN
  TN["tailnet<br/>WireGuard plus TLS"] --> HOST
  subgraph BOX["HP EliteDesk Mini, server room, always on"]
    HOST["tailscaled<br/>serves loopback only"]
    Q["podman quadlet<br/>opencode container"]
    ENV["oc-env.service<br/>writes /etc/opencode/env"]
    BK["oc-backup.timer<br/>nightly restic"]
    HOST --> Q
    ENV --> Q
  end
  Q --> DD["/srv data disk<br/>repos, session DB, config"]
  DD --> BK
  BK --> OFF["off-box restic repository<br/>NAS, B2, or S3"]
  BOX --> LAN["wired LAN and firewall"]
  LAN --> NET["GHCR, npm, model APIs"]
```

## Three update cadences, deliberately independent

| Layer | Built by | Updated by |
|---|---|---|
| OS (`ucore-minimal`) | upstream, installed from Fedora CoreOS media then rebased once | `rpm-ostreed-automatic.timer`, staged, applies on next boot |
| Container image | `.github/workflows/image.yml` into GHCR | `podman auto-update` on the `:prod` tag, kept only if the health check passes |
| Data (`/srv`) | not built | nightly restic backup to an off-box repository |

Fusing the first two would make every OpenCode release an OS rebuild plus a
reboot. They stay separate on purpose.

The container update is not gated on idleness. `podman-auto-update.timer` fires
on its own schedule and restarts the container when `:prod` moves. The health
check decides whether a new image is kept, not whether a session is running.

## Secrets

| Secret | Where it lives | Written by |
|---|---|---|
| `OPENCODE_PASSWORD` | `/etc/devbox/secrets.env`, mode 0600 | operator, after first boot |
| `RESTIC_REPOSITORY`, `RESTIC_PASSWORD` | `/etc/devbox/secrets.env` | operator, after first boot |
| Tailscale auth key | `/etc/devbox/tailscale-authkey`, mode 0600, in Ignition | `os/butane/build.sh`; empty in a keyless build |
| SSH public key | Ignition, no secret | `os/butane/build.sh` |

`oc-env.service` reads the password from `secrets.env` and writes
`/etc/opencode/env`. It fails closed when the password is absent or empty, and
the quadlet carries `Requires=oc-env.service`, so a failed write never serves a
passwordless server.

In a keyed build, the Tailscale key is the only secret on the install media. It
is scoped to a tag, single-use or short-lived, and revoked after the node
appears. Revoking it does not disconnect the node: identity lives in
`/var/lib/tailscale`. A keyless build ships no key, and you join from the console
after first boot.

## Always on

There is no idle deallocation and no scheduled stop. Suspend and hibernate are
masked in Ignition, and logind sets `IdleAction=ignore`. A UPS covers a short
power cut; the firmware setting to power on after AC loss covers the rest.

## Run the tests

Everything the repo asserts runs through one gate:

```sh
./tests/verify.sh
```

It runs every suite and then `shellcheck` over all shell scripts. It ends with
`VERIFY: all suites pass`.

Set `BUTANE` when you change anything under `os/butane/`, or the artifact
reproducibility check skips:

```sh
BUTANE=/path/to/butane ./tests/verify.sh
```

| Suite | What it protects |
|---|---|
| `host/tests/test_oc-env.sh` | the environment file is 0600 and an empty password fails closed |
| `host/tests/test_oc_backup.sh` | the backup runs the Fedora image, mounts data read-only, and never prunes |
| `host/tests/test_tailnet_up.sh` | the tailnet join is idempotent, durable, and needs a real key |
| `host/tests/test_cockpit_loopback.sh` | Cockpit listens on loopback only and is not published |
| `host/tests/test_no_lan_listener.sh` | sshd is masked and no unit declares a non-loopback listener |
| `host/tests/test_nosleep.sh` | sleep targets are masked and `IdleAction=ignore` is set |
| `host/tests/test_quadlet_persistence.sh` | persistent data is on the data disk and the workload fails closed |
| `os/butane/tests/test_autorebase.sh` | one enabled rebase unit, pinned, marked, disabled, rebooted |
| `os/butane/tests/test_no_azure.sh` | no Azure endpoint or deleted module survives |
| `os/butane/tests/test_tailscale_enabled.sh` | `tailscaled` is enabled and orders the join |
| `os/butane/tests/test_keyless_build.sh` | a keyless build ships no key and keeps the console autologin |
| `os/butane/tests/test_units_have_scripts.sh` | every unit runs a shipped script, and the artifact reproduces |
| `image/tests/test_integrity_logic.sh` | the OpenCode artifact's sha512 is verified, with a negative control |
| `image/tests/test_digest_record.sh` | the rollback digest record holds exactly one valid digest |
| `tests/ci_shape.sh` | CI publishes to GHCR behind a smoke gate |
| `tests/docs_complete.sh` | the install and recovery topics stay written down |

Every guard was checked against a mutation it is meant to catch, and the mutation
was confirmed to land before the result was trusted. The integrity test has a
documented negative control: it rejects a corrupted tarball.

## What is not verified here

No install has run on the target Mini. No live boot has been tested. The
container image has not been built by the GitHub Actions workflow. The restic
restore drill has not been executed, the keyless console join has not run, and
the ucore rebase path is documented upstream but unexercised on this hardware.
Nothing here should be described as working until it runs against real hardware.

## Documentation

- `docs/design.md` records the architecture, the pivot, and the hardware risks.
- `docs/install.md` is the first-install procedure.
- `docs/runbook.md` covers daily checks, backup, restore, rollback, and disk
  replacement.
- `docs/web-access.md` covers the tailnet-only client path: the served address,
  browser sign-in, CORS, verification, teardown, and the failures.
- `CHANGELOG.md` records every landed change and the honest gaps.

## Status

The bare-metal pivot is implemented on `refactor/bare-metal-pivot` until it
merges. The invariants named above each have a guard, and those guards were
checked against mutations they are meant to catch. See `CHANGELOG.md` for the
change list.
