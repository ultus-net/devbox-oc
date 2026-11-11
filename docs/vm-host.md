# Run the devbox as a guest on a hypervisor

**Status:** option record, not a procedure
**Date:** 2026-11-12
**Related:** decision 16 in `docs/design.md`

## Why this page exists

The shipped target is the Mini: ucore installed directly on two physical disks,
reached only over the tailnet. This page records the alternative, where the same
Ignition-built guest runs under a hypervisor on other hardware. It exists so a
future move is a decision with a cost and a known list of changes, rather than a
redesign done under pressure. Nothing here has run: no hypervisor has booted
this guest.

The trigger is money and hardware. The Mini is already owned, so the bare-metal
path costs nothing to start. A move earns its keep only when spare capacity
exists on a host that already runs 24/7, or when the Mini fails and its
replacement would be a hypervisor host anyway.

## What the move keeps

The guest is the artifact, so most of the design carries over unchanged:

| Decision | Why it still holds |
|---|---|
| 1, 2 | The guest is still Fedora CoreOS installed from media and rebased to ucore. |
| 3, 4 | Rootful podman and bind mounts under `/srv` do not know they are virtualized. |
| 7, 8 | Secrets still arrive in `/etc/devbox/secrets.env` after first boot. |
| 9 | `tailscale serve` runs inside the guest, so the ACL, the certificate, and the MagicDNS name stay the same. |
| 11 | Ignition is still the only source for host config, and the guest is rebuilt, never edited. |
| 12, 15 | The image is still built by the workflow and still booted by digest. |
| 13 | The `getty@tty1` autologin drop-in still exists inside the guest. |
| 14 | The Hermes waiver is unaffected. |

## What the move changes

Two decisions stop being true as written, and several more acquire a dependency
on the host. Each row names the change and what it costs.

| Area | What changes | What it costs |
|---|---|---|
| Data disk (decision 5) | The second disk becomes a separate virtual volume rather than a second physical device. It stays its own device with its own `data` label, so Ignition still only mounts it. | The "reinstall the OS, keep `/srv`" guarantee becomes the hypervisor's. A guest rebuild must reattach the volume, and deleting the guest must not delete it. |
| Power (decision 6) | The guest keeps its masked sleep targets, but the hypervisor owns power. | The host needs power-on after AC loss, a UPS sized for host and guests, and no idle suspend. `host/tests/test_nosleep.sh` passes while the host sleeps, because it only sees the guest. |
| Console (decision 13) | The console door becomes the hypervisor console. | Reaching `tty1` needs host access and host credentials. The door is no longer independent: a host outage takes the recovery path with it. |
| Ignition delivery | There is no USB stick and no `coreos-installer` on a laptop. The hypervisor attaches or serves `ucore.ign`: QEMU and libvirt pass it as the `fw_cfg` entry `opt/com.coreos/config`, and an HTTP URL through `ignition.config.url` is the alternative. | A new distribution path for a file that may carry the Tailscale auth key. The HTTP option puts that key on the network, so it belongs inside a trusted network only. |
| Disk identity | `ata-` and `nvme-` ids do not exist in the guest. Virtual disks appear as `virtio-<serial>`. | The install step that reads the id twice changes, and the serials must be pinned in the hypervisor so a reboot does not rename a disk. |
| Firmware | The guest boots OVMF/UEFI, and Secure Boot depends on the ublue signing chain. | The same unknown as the Mini, with one more layer: host firmware settings now matter too. |
| Capacity | CPU and memory are shared with the host. | Oversubscription breaks the property the box exists for. Reserve cores and memory instead of borrowing them. |
| Snapshots | A hypervisor snapshot lives on the same storage as the guest. | It is rollback, not backup. Decision 10 stands, and restic still leaves the box. |

## What this record already adds

- Decision 16 in `docs/design.md`, with one cross-reference sentence each in
  decisions 5 and 6, so the design document does not contradict itself.
- The gap-list entries in `README.md` and `AGENTS.md`, because the option is
  unverified.
- A guard in `tests/docs_complete.sh` that fails when this page loses its README
  link, or when it drops one of the four rows a move breaks: data disk, power,
  console, and snapshots.

## What a move would still have to add

1. **A guest hardware profile** beside this page: vCPU count, memory, an OS
   volume of at least 64 GiB, a second volume for `/srv`, q35 with UEFI, and
   fixed virtio serials. The ids in step 4 of `docs/install.md` are the ones
   that change, so the two cannot drift apart.
2. **A guest branch in `docs/install.md`**, or a pointer from its step 3,
   because the media step has no analogue in a guest. The delivery mechanism is
   the hypervisor's, and the install step becomes an attached or fetched
   Ignition file.
3. **A host-side counterpart to `host/tests/test_nosleep.sh`**, or a recorded
   exception, covering host idle policy, power-on after AC loss, and UPS
   shutdown ordering. The current guard proves the guest's policy only.
4. **A guest rebuild procedure in `docs/runbook.md`**: recreate the guest from
   Ignition, reattach the data volume, confirm `/srv` came back by label, then
   run the restic drill. This is the recovery path decision 5 protects on bare
   metal, and on a hypervisor it moves to the host.
5. **One line in `docs/vm.md`** saying `./vm/run-vm.sh --rebuild` is already the
   guest rehearsal, because QEMU is a hypervisor. The harness needs no change.
   The claim about what it covers does.
6. **A cost note**: host price, memory, storage, and power draw against the
   Mini's. The move is defensible at spare capacity on an existing always-on
   host, and hard to defend as a new purchase.

## What would make it a failure

- Using a hypervisor snapshot as the backup. It shares storage with the guest,
  so it fails the test decision 10 already sets.
- Hosting on a machine that sleeps, is a laptop, or belongs to someone else.
  The box is meant to answer at 3 a.m. without a person in the loop.
- Adding a second tailnet identity on the host, or proxying the guest through
  the host. The proof in `docs/web-access.md` is that the guest has no public
  listener. A host that proxies breaks the proof, not just the port list.
- Editing the guest in place. Decision 11 forbids that on metal for the same
  reason it forbids it here.
- Buying a dedicated always-on host for this workload. It costs more than a
  used Mini and adds a layer that must be patched and watched.

## When to reopen this option

- The Mini fails, or a replacement is needed for some other reason.
- Spare capacity appears on a host that already runs 24/7 behind a UPS.
- Recovery or snapshot needs outgrow a single box.
- The restore drill shows the current recovery path is too slow to accept.

## What is not verified here

No guest has booted on a hypervisor. Every claim about the guest's behaviour is
inferred from the QEMU harness, which is a hypervisor, but not the kind a move
would use. The guest hardware profile does not exist yet, so there are no
capacity numbers to check. Nothing on this page changes what ships today.
