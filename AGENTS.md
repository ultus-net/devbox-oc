# Agent instructions: devbox-oc

This repo builds a portable Azure development server that hosts OpenCode. Read
`~/.config/opencode/STANDARDS.md` and
`~/.config/opencode/style/coding-style.md` first. Those rules apply here in full.
This file records only what is specific to this repository, and it wins where the
two disagree.

## What this repo is

Two images and a data disk. The OS is ucore-minimal, a Fedora CoreOS derived
image built from its upstream bootc container by digest, so a VM boots it
directly. The toolchain runs in a Fedora toolbox container. OpenCode is reached
over a private tailnet with no public IP.

This repo is the source of truth. Azure DevOps builds it directly from GitHub and
deploys into the work subscription, so there is no copy to keep in step.
`docs/pipelines.md` records the one-time console setup.

## Non-negotiables

These are load-bearing. A change that breaks one is a correctness bug, not a
preference.

- **Fedora family only.** No Ubuntu, Debian, or Alpine at any layer: OS, base
  image, or container. `ubuntu-latest` appears in `pipelines/*.yml` as the CI
  runner, which is not a shipped layer and is allowed.
- **No public IP and no inbound internet rule.** Reachability is Tailscale.
  Bastion Developer is break-glass only. The deployed VM is declared in `csh-dev`
  Bicep: `scripts/check-template.py` reads the compiled template and
  `scripts/check-deployed-network.sh` reads the live NIC and NSG.
- **Everything that listens, listens on loopback.** Services are published over the
  tailnet with `tailscale serve`, never bound to an interface. ucore ships Cockpit
  and enables it, so its socket is rebound to `127.0.0.1` by an Ignition drop-in;
  `host/tests/test_cockpit_loopback.sh` guards that.
- **No scheduled stop.** Start is scheduled, stop is idle-based. A timer that
  deallocates on a clock is a data-loss path. The `csh-dev` compiled-template
  check rejects a DevTestLab shutdown schedule, and
  `terraform/tests/no_scheduled_stop.sh` rejects one in the Terraform port record.
- **The data disk survives a VM rebuild.** The disk holds the session database and
  the repos. In `csh-dev` Bicep the data disk and NIC use `deleteOption: Detach`,
  which `scripts/check-template.py` asserts.
- **The password comes from Key Vault at boot.** No shipped file may define
  `OPENCODE_PASSWORD` by any route, because Ignition ships as the VM's
  `custom_data` and stays readable in deployment history.

## Verification

One gate runs everything:

```sh
./tests/verify.sh
```

It must end with `VERIFY: all suites pass`. It is a real gate, not a formality:
it fails rather than skips when `shellcheck` or PyYAML is missing.

**Set `BUTANE` when you change anything under `os/butane/`.** Without it the
artifact reproducibility check prints `SKIP` and the gate still returns 0. Pass a
Butane 0.29.0 binary:

```sh
BUTANE=/path/to/butane ./tests/verify.sh
```

CI installs that exact version, pinned by sha256, and fails the step if the skip
line appears.

Terraform checks are separate:

```sh
terraform -chdir=terraform fmt -check -recursive
terraform -chdir=terraform validate
```

`validate` needs a real working directory. It fails in a copy, so mutate
`main.tf` in place with a backup when testing a change to it.

## How the tests are written

- **Assert behaviour, not text.** The recurring defect in this repo is a guard
  that decides a property of a script by reading its source. Run the thing.
- **Prove a test can fail.** Every guard here was verified against a mutation
  that it catches. A guard that has never failed has not been tested.
- **Grep the mutation before trusting the result.** Several rounds produced
  false passes from a mutation that never landed.
- **A rule is only as wide as its reader.** "No shipped file defines X" was true
  of every file the parser opened and false of one included via `local:`.

## Layout

| Path | What lives there |
|---|---|
| `host/bin/` | scripts baked into the image: secret fetch, idle probe, snapshot |
| `host/quadlet/` | the podman quadlet for the OpenCode container |
| `os/butane/` | Ignition source (`ucore.bu`) and the compiled `ucore.ign` |
| `os/` | the OS image publish script |
| `image/` | toolbox container: Dockerfile, toolchains, smoke test, digest |
| `terraform/` | port record for the VM, disk, network, ACR and Key Vault; never applied |
| `pipelines/` | Azure Pipelines: verify, OS image, container image |
| `docs/` | runbook, pipeline setup, design and plans |

`os/butane/ucore.ign` is a compiled artifact and must stay byte-identical to what
`os/butane/build-placeholder.sh` produces. Never hand-edit it.

## Git

Follow the branch and commit prefixes in `STANDARDS.md`. Open a PR to `main` and
never push to it directly. Record every landed change in `CHANGELOG.md` in the
same commit.

## What is not verified here

No `terraform apply`, container build, or pipeline run has ever executed, and no
live boot has been tested. Do not describe anything as working until it has run
against a real subscription. `README.md` lists the same gap; keep them in step.
