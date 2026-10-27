# Devbox: ucore OS plus a Fedora toolbox container

**Status:** draft for approval
**Date:** 2026-10-27

## Intent

A personal, always-recoverable AI development server in an Azure subscription,
built from declared artifacts so it can be destroyed and recreated without
losing work. It hosts the OpenCode server. The TUI and the desktop app connect
to it directly over the network. A second IDE may attach later.

The operator owns the tooling and the setup. The goal is to stop fighting
local environment drift and instead make the environment a rebuildable
artifact.

## Why now

Local development setups break in ways that cost hours and produce nothing.
Reproducibility is the fix: if the environment is an image plus a data disk,
recovery is a redeploy rather than a repair.

## Goals

1. Two independent layers that update on their own cadence: an OS image and a
   development container image.
2. No inbound port open to the internet on the host. No public IP on the NIC.
3. TUI and desktop app connect directly, with no SSH port forward required.
4. Destroy and recreate the VM without losing sessions, repos, or images.
5. Sleep when idle, but never while a session is active or awaiting approval.
6. Everything declared in files that vendor into an existing Azure DevOps repo.
7. Fedora family only. No Ubuntu, no Debian.

## Non-goals

- Multi-user. This is a single-operator box.
- High availability. A single VM with snapshots is the accepted risk.
- Being a general-purpose Kubernetes or fleet platform.
- Serving model inference. Models are remote APIs.

## Anti-goals

These count as failure even if the system technically runs:

- A hand-edited running host. If a fix was applied by SSH and not committed,
  the design failed.
- An in-flight agent turn killed by a deploy or an idle shutdown.
- A secret written into `custom_data`, an image layer, or git.
- A rebuild that cannot reproduce the previous state.
- Two tools managing the same resource, so state drifts.

## Constraints

- Azure subscription is company-owned. Inherited policy may deny public IPs,
  mandate private endpoints, or restrict custom images. **Unresolved, blocking.**
- Fedora publishes no CoreOS image in the Azure marketplace. Verified in the
  Fedora CoreOS Azure provisioning guide: "Fedora currently does not publish
  Fedora CoreOS images within Azure, so you must download an Azure image from
  Fedora and upload it to your Azure subscription."
- ucore consumes a Fedora CoreOS base, so it inherits that gap.
- The official OpenCode container image is musl-only on every platform.
  Verified in its layer history: `dist/cli-linux-x64-baseline-musl/bin/opencode`
  for `linux/amd64`, and the arm64 path is musl too. A Fedora (glibc) base
  therefore cannot inherit that image.
- Anthropic and other model API keys must not be baked into any artifact.
- **Role assignment rights are a hard prerequisite, not a detail.** The idle
  gate needs `deallocate/action` on the VM for the VM's own identity, and
  `oc-secrets` needs Key Vault secret read. Both are role assignments. Many
  company subscriptions forbid contributors from creating them. If denied, the
  automatic shutdown mechanism does not exist and the cost model changes.
- **Key Vault reachability.** The boot-time secret fetch is the only route for
  the server password. A vault behind a private endpoint is still usable, since
  the fetch runs on the VM inside the VNet, but a vault restricted by IP rules
  with no VNet path is not. This must be settled before Terraform, not during.
- **Region and VM family** must be allowed by policy. A denied SKU family is a
  patch; a denied region is a rewrite.

## Verified facts this design depends on

Recorded with their source so a reviewer can re-check them.

| Fact | Value | Source |
|---|---|---|
| ucore-minimal stable digest | `sha256:7906a70efe7482704fdb232c7e5d2a3068a0c5520ef46d3f7f6b9f8fc0e899b9` | ghcr manifest |
| ucore-minimal size | 1533 MB, 67 layers, `Cmd ["/sbin/init"]` | ghcr config |
| ucore boot model | `containers.bootc: 1`, `com.coreos.osname: fedora-coreos` | image labels |
| ucore signing | cosign, `.sig` tag resolves | ghcr |
| ucore tag discipline | `stable` and `stable-20261025` share one digest | ghcr |
| ucore shipped runtime | `systemctl disable docker.socket`; podman is expected | `install-ucore-minimal.sh`, `post-install-ucore-minimal.sh` |
| ucore OS updates | `rpm-ostreed-automatic.timer` enabled, `AutomaticUpdatePolicy=stage` | `post-install-ucore-minimal.sh` |
| ucore container autostart | off by default; needs `podman-restart.service` plus `loginctl enable-linger` for rootless | projectucore.org/docs/containers |
| ucore filesystem policy | root immutable at runtime; persist changes via image build | projectucore.org/docs/containers |
| ucore firewalld interaction | `netavark-firewalld-reload.service` restores podman rules | projectucore.org/docs/containers |
| FCOS Azure path | download `azure/vhd.xz`, upload, `az image create`, `--custom-data` carries Ignition | fedora-coreos-docs `provisioning-azure.adoc` |
| FCOS admin user on Azure | `--admin-username core` | same |
| ucore first boot | two-stage autorebase, two reboots, needs network | projectucore.org/docs/first-install |
| OpenCode glibc artifact | `@opencode/cli-linux-x64@2.1.4`, sha512 `o8EJ0ZsT...PNmNQ==` | npm registry, hash recomputed locally and matched |
| OpenCode binary | dynamically linked, `libc.so.6`, runs and reports `v2.1.4` | local `file` and `ldd` |
| Idle signals | `/api/session/active`, `/api/shell`, `/api/pty`, `/api/permission/request`, `/api/form` | `opencode.ai/v2/openapi.json` |
| fedora-toolbox tag hazard | tag `46` labels itself `rawhide`; pin by digest `sha256:2c8a6048...` | ghcr config |

## Approaches considered

### A. Container Apps, no VM

Rejected. Scale-to-zero discards the SQLite session database under
`~/.local/share/opencode/`, ingress is HTTP-only so no IDE can attach over SSH,
and one always-on vCPU plus 2 GiB costs roughly $110/month before storage. That
is more money for less capability than a VM.

### B. Azure Functions as the host, or as a wake button

Rejected as a host: Flex Consumption has no container support and 0 GB
persisted storage. Kept as the wake mechanism, but a Logic App recurrence
replaced it because it needs no code and bills at $0.000025 per run.

### C. Ubuntu VM plus cloud-init, container inside

The original scaffold. Rejected on the operator's explicit constraint: Fedora
family only. Also leaves OS updates as apt drift rather than an atomic image.

### D. ucore-minimal OS plus a Fedora toolbox container (chosen)

The OS is a signed, immutable, auto-updating Fedora CoreOS image. The dev
toolchain lives in a rootless podman container under a quadlet. The data disk
holds anything that must survive.

Why this one:

- Two update cadences stay independent. ucore builds daily; OpenCode ships per
  release. Fusing them would make every OpenCode bump an OS rebuild plus reboot.
- Rootless podman means the container cannot modify the host, which matches an
  immutable OS where `dnf install` into `/usr` is not available anyway.
- Rollback is two independent levers: revert one container digest, or
  `rpm-ostree rollback` for the OS.
- The container is the attachment point for the future IDE. VS Code Remote and
  JetBrains Gateway reach the host over the tailnet, then attach to a dev
  container.
- Staged OS updates pair naturally with nightly deallocation: the box applies
  them on next boot without a maintenance window.

Costs accepted:

- Custom image pipeline. Azure needs an uploaded VHD plus a managed image.
- First boot does two reboots to reach the signed ucore reference.
- SELinux labelling on bind mounts.
- One more pipeline to maintain.

### E. Layer OpenCode into a derived ucore OS image

Rejected. It is possible, and it would remove the container, but it couples the
OpenCode release cadence to the OS image and a reboot. It also forfeits rootless
isolation. This is the design D explicitly avoids.

## Decisions

Each is a call made here, with its reason. The operator can override any of them.

1. **Consume upstream ucore-minimal, do not fork it.** Forking would mean owning
   an OS build for no benefit while the container layer already carries the
   toolchain. Revisit only if a host package is genuinely needed.
2. **No OS packages installed on the host.** Anything the operator needs at
   runtime goes in the container. This follows the ucore filesystem policy.
3. **Rootful podman quadlet, not rootless.** Rootless needs
   `podman-restart.service` plus lingering, and bind-mount uid mapping adds
   failure modes. The container already runs as a non-root user inside, so
   rootful podman is the simpler correct choice here.
4. **`podman auto-update` against a moving tag, with the digest recorded in
   git.** See decision 7 for how this coexists with digest pinning. It is the
   idiom ucore expects, and it removes a script we would own. Guarded by the
   idle gate.
5. **Every persistent path is a bind mount under `/srv`.** This corrects an
   earlier draft that used a podman named volume for the session database. A
   named volume lives in `/var/lib/containers/storage` on the OS disk, and the OS
   disk is recreated with the VM, so a rebuild would discard every session.

6. **Idle shutdown, never a scheduled hard stop.** A fixed cutoff would kill an
   active session, which is an anti-goal. Scheduled start only.
7. **Secrets fetched at boot from Key Vault over IMDS.** Never in Ignition,
   never in an image layer. Ignition is stored in `custom_data`, which anyone
   with read on the VM can retrieve, so Ignition carries no secrets.
8. **The quadlet consumes a moving `:prod` tag; git records the digest.**
   `podman auto-update` re-resolves a tag, so a bare `@sha256:` reference has
   nothing to advance. The pipeline therefore promotes to `:prod` and commits
   the resolved digest to `image/prod-digest.txt`. Rollback is two operations:
   re-point `:prod` to the previous digest, and revert that file. Terraform
   does not carry the image reference, so a container bump never recreates the
   VM. The OS digest is pinned in Terraform, because an OS change *should* roll
   the host.
9. **Data disk separate and protected from destroy.** `prevent_destroy` plus
   nightly incremental snapshots. Retention is manual, because deleting backups
   from a timer deserves a human.
10. **Tailscale for the data path, Bastion Developer as break-glass.** No public
   IP, no inbound rule. Tailscale provides TLS and SSH over tailnet identity.
11. **Terraform owns Azure; quadlet files own the container.** One owner per
    resource, so state cannot drift.
12. **The tailnet node is a durable, tagged, non-expiring device.** A key that
    expires or an ephemeral node breaks the client's saved server URL and turns
    recovery into a Bastion session. The auth key is single-use and scoped to a
    tag, stored in Key Vault, and the tailnet name is recorded in the runbook so
    a rebuilt box rejoins under the same name. **Assumes an existing tailnet the
    operator controls**; if Tailscale is not permitted on a company VM, the data
    path repoints to Bastion Standard at roughly $212/month, which is a cost
    decision for the operator, not a builder.
13. **The container pulls from ACR with a podman credential helper backed by a
    managed-identity token.** The admin account stays disabled, because policy
    commonly disallows it. This adds one artifact: the helper plus an
    `auth.json` written at boot alongside the env file.
14. **The data disk is not a backup.** Nightly incremental snapshots give a
    24 hour RPO for uncommitted work. Anything the operator would grieve over
    must be pushed to a remote. The runbook states this, and the design does not
    pretend snapshots are version control.

## Architecture

```
tailnet (WireGuard + TLS)
   |
   v
ucore-minimal VM  --- no public IP, NSG deny inbound from Internet
   |  tailscaled: serves https -> 127.0.0.1:4096, ssh on
   |  podman quadlet: opencode container, restart + auto-update
   |  oc-idle.timer: probes five signals, deallocates when idle
   |  snapshot.timer: incremental data-disk snapshot
   v
data disk /srv  --- repos, container storage, opencode DB
   |
   v
NAT Gateway -> internet egress (apt/dnf, registry, model APIs)
```

Three artifacts, three cadences:

| Artifact | Built by | Updates |
|---|---|---|
| OS image | upstream ucore, consumed by digest | `rpm-ostreed-automatic.timer`, staged |
| Dev container | our pipeline into ACR | `podman auto-update` when idle |
| Data disk | not built | snapshotted nightly |

## Scaffold status

An earlier scaffold exists on branch `feature/scaffold-devbox`, written before
the Fedora and ucore decisions. It is **not** the implementation and must not be
shipped as-is. Reconciliation:

| Path | Verdict | Reason |
|---|---|---|
| `image/Dockerfile` | keep, extend | Already Fedora toolbox, digest-pinned, with a verified sha512 install of the glibc OpenCode artifact. Needs the ACR pull helper. |
| `image/toolchains.txt` | keep | dnf package list, correct for this design. |
| `host/bin/oc-idle-check` | keep, extend | IMDS plus ARM, fails closed. Needs the pin-file signal. |
| `host/bin/oc-secrets` | keep, extend | Writes `/etc/opencode/env`. Needs to also write `auth.json` for ACR. |
| `host/bin/oc-image-update` | **delete** | Replaced by `podman auto-update`, per decision 4. |
| `host/bin/oc-tailnet`, `oc-tailnet-up` | keep | Serve plus `up` with a Key Vault key. |
| `host/bin/oc-snapshot` | keep | Creates only; retention stays manual. |
| `host/compose.yaml` | **delete** | Replaced by a quadlet, per decisions 3 and 9 and the ucore container doc. |
| `host/systemd/*` | rewrite | Containers units become quadlets. Timers survive, unit files change. |
| `terraform/*` | rewrite | `source_image_reference` is Canonical Ubuntu. Becomes a managed image from the FCOS Azure VHD. `custom_data` becomes Ignition, not cloud-init. |
| `terraform/schedule.tf` | rewrite | Logic App stays, but it loses the hard-stop framing that contradicted decision 5. |

The plan below supersedes the scaffold rather than patching it. Files marked
delete are removed in the task that replaces them, not left orphaned.

## Host layer detail

This section exists because the ucore specifics contradict what a generic
Linux host would need.

- **Container autostart.** ucore does not start `restart: always` containers at
  boot. A quadlet with `[Install] WantedBy=default.target` plus enabling
  `podman-restart.service` is the documented path.
- **Firewall.** Enable `netavark-firewalld-reload.service`, or a firewalld
  reload silently drops podman's rules.
- **No docker.** `docker.socket` is disabled upstream and Fedora CoreOS warns
  against mixing Docker and Podman workloads. Podman only.
- **Immutable root.** Runtime state belongs in `/var` and on the data disk.
  `/etc` is mutable on ostree and is where the env file lives.
- **Secrets.** `oc-secrets.service` writes `/etc/devbox/opencode.env` from Key
  Vault over IMDS, mode 0600, before the quadlet starts.
- **Idle gate.** Reads the same env file, probes five endpoints, and deallocates
  through IMDS plus ARM. Fails closed on any error.

## Idle policy

A turn is protected if any of these is non-zero:

| Endpoint | Meaning |
|---|---|
| `GET /api/session/active` | a session is running |
| `GET /api/shell` | a shell command is running |
| `GET /api/pty` | a terminal is open |
| `GET /api/permission/request` | a turn is blocked on approval |
| `GET /api/form` | a turn is blocked on a question |

### What is not protected, stated plainly

This contract covers OpenCode work only. That is deliberate, because the
alternatives are unreliable.

- A connected TUI with no running turn does **not** keep the box up.
- An SSH session or a future IDE terminal does **not** keep the box up.
- A long build running outside an OpenCode turn does **not** keep the box up.

Reason: tailscaled connection state and container process liveness are both
noisy. A client that reconnects after sleep, or an idle editor holding a socket,
would pin the box awake forever and defeat the cost goal.

Mitigation instead of a probe: the client wakes the box on connect (see the wake
path below), and the 45 minute threshold is longer than a typical read or
think. Work that must outlive an idle window belongs in an OpenCode turn, or the
operator holds it open with an explicit pin file, checked as a sixth signal:

```
/var/lib/oc-idle/pin    # exists => never deallocate
```

Rules:

- Boot grace of 15 minutes, so a starting container is never read as idle.
- Idle threshold 45 minutes, measured from the last busy observation.
- Second probe 60 seconds later before acting, to close the start race.
- Any probe error means stay up.
- The pin file overrides everything.

## Wake path

Goal 3 requires the clients to connect directly, and the box sleeps. Those two
together need a wake path, so this is explicit:

- The `oc` wrapper script on the operator's machine does: `az vm start`, then
  poll the OpenCode health endpoint until it answers, then `exec opencode
  --server https://<host>.<tailnet>.ts.net`. Cold start is 60 to 120 seconds.
- The Logic App recurrence stays as a convenience start for the normal working
  day, not as the only way in.
- The operator's laptop holds the only credential that can start the box.
  Azure DevOps gets no start permission. The pipeline builds images; it does not
  manage the host.
- Break-glass when the tailnet is down: Bastion Developer in the portal.

## Open questions

### Resolved

1. **Managed image and storage account: permitted.** The subscription is the main
   company subscription, and the operator can create both. The OS pipeline runs
   before Terraform, so Terraform consumes an `os_image_id`.
2. **Role assignments: permitted.** Idle shutdown is buildable, so the cost model
   is the scheduled-start-and-idle-stop figure, not the 24/7 figure.
3. **Tailscale: permitted, operator is the tailnet admin.** The data path is the
   tailnet, the node key is tagged and non-expiring, and no Bastion Standard
   spend is required.

### Pending operator decision

4. **ACR SKU.** Recommendation is **Basic**, around $5/month. Repo-scoped Entra
   roles work on all SKUs, so least privilege is not a reason to upgrade. The
   Premium retention policy only purges *untagged* manifests, so it does not
   solve `sha-*` tag accumulation either; a pipeline purge step is needed on
   every SKU. Premium is required only if policy forbids public network access
   on the registry, since private endpoint is Premium-only. **Confirm which
   applies on this subscription.**
5. **RPO.** Recommendation is **nightly snapshots, accepting 24 hours**, plus
   push discipline. Rationale: the only irreplaceable data is session
   transcripts; code that matters is pushed. Hourly is incremental and cheap if
   preferred, and is a timer change rather than a design change. **Confirm.**

### Non-blocking

6. Whether the idle probe accepts `Authorization: Bearer <password>`. One curl
   against a live server settles it; the fallback is a paired session cookie.

## What is left to the builder

- Exact Ignition unit contents, derived from the Butane template.
- Whether the container runs as the `core` user's container storage or root's
  system storage. Decision 3 picks rootful, so system storage.
- The precise ACR repository name and image tag scheme.
- Whether to add a five-minute pre-shutdown notification.

## Anti-goal found during review

A podman **named volume** for the session database places
`/home/dev/.local/share/opencode` in `/var/lib/containers/storage`, which is on
the **OS disk**. Terraform sets `delete_os_disk_on_deletion = true`, so rebuilding
the VM would discard every session, violating goal 4.

The rule that follows: every persistent path is a bind mount under `/srv`, the
data disk. Never a named volume for anything that must survive. The quadlet
reflects this and Task 6 step 2b tests for it.
