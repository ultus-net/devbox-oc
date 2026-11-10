# Devbox runbook

Operating procedures for the always-on HP EliteDesk Mini. `docs/install.md`
covers the first install; this file covers the day after, and the day something
breaks.

The box is reached over Tailscale. There is no public IP and no inbound port
forward. If the tailnet is down, use the physical console, Intel AMT/vPro if the
model has it, or a PiKVM.

## Daily checks

These are read-only. Run them when you sit down, or from a monitoring check.

```sh
ssh core@devbox 'systemctl is-active oc-env hermes-env opencode hermes oc-tailnet'
ssh core@devbox 'sudo podman ps --format "{{.Names}} {{.Status}}"'
ssh core@devbox 'sudo systemctl list-timers oc-backup.timer'
ssh core@devbox 'df -h /srv'
ssh core@devbox 'findmnt -no SOURCE /srv'
```

On a keyless install that has not been joined yet, `oc-tailnet` is expected to
be failed. Join it from the console first.

`oc-env`, `hermes-env`, `opencode` and `hermes` must all be active. A failed
`oc-env` or `hermes-env` stops its container by design. `podman ps` must show
both containers as `healthy`. `findmnt` must name the data device, not the OS
disk.

`healthy` means the image's own health command answered, not that a binary ran.
`devbox-health` requests `http://127.0.0.1:4096/api/info` and accepts `401`, so
the server is up and asking for the password. It also accepts `200`, which means
the API answered with authentication off. A container that boots but never serves
stays unhealthy, and `podman auto-update` refuses to keep the new image.

## Remote web access

The browser and client path is `docs/web-access.md`. It records the served
address, the Basic-auth sign-in, the tailnet-only invariant, the full
verification checklist, and the failure table.

The one check worth running daily, because it separates a proxy fault from an
auth fault:

```sh
ssh core@devbox 'curl -s -o /dev/null -w "%{http_code}\n" http://127.0.0.1:4096/api/info'
```

`401` is healthy: the server is up and asking for the password. No code is a
container or listener fault. `200` would mean authentication is off, which this
build never configures.

A `401` with the password rejected is a different fault: the server generated its
own password because `OPENCODE_PASSWORD` did not reach the process. Check
`/etc/opencode/env` and look for a `server password ...` line in
`journalctl -u opencode.service`.

A `200` on `/` proves nothing; the HTML shell is deliberately unauthenticated.
The API is the check.

## Rotate the OpenCode password

1. Generate a new value and store it in the password manager.
2. Edit `/etc/devbox/secrets.env` on the box, replace `OPENCODE_PASSWORD`, and
   keep the file at mode 0600.
3. Restart the writer and the container:

```sh
ssh core@devbox 'sudo systemctl restart oc-env.service opencode.service'
ssh core@devbox 'sudo systemctl restart hermes-env.service hermes.service'
```

4. Pair the client again with `opencode pair --url ...`, or update the TUI's
   saved password. Hermes reaches OpenCode with the same password through its own
   environment file, so restart `hermes-env` and `hermes` too.

A running turn is interrupted by the container restart. Do this between turns.

## Rotate the restic password

The restic password protects the repository, not just the client. Changing it
requires `restic key add` and `restic key remove`, not a text edit alone. Follow
the restic key documentation, then update `RESTIC_PASSWORD` in
`/etc/devbox/secrets.env`.

## Back up now

```sh
ssh core@devbox 'sudo systemctl start oc-backup.service'
ssh core@devbox 'sudo journalctl -u oc-backup.service -n 40 --no-pager'
```

The timer runs nightly at 02:00 local time. It backs up `/srv` and never prunes.
Pruning is manual. The unit stops both workloads before the snapshot and starts
them again after, so neither SQLite store is captured mid-write; a turn that spans
the window is interrupted.

## Restore from restic

Use this when `/srv` is corrupt, a file was deleted, or the data disk was
replaced. Never restore over the live `/srv` in one step. Restore to a scratch
device, inspect it, then copy the contents into `/srv`.

The backup snapshot root is `/data`, because `/srv` is mounted at `/data` inside
the container. A restore therefore lands at `/restore/data/...`.

1. Stop the workloads so nothing writes during the restore:

```sh
ssh core@devbox 'sudo systemctl stop opencode.service hermes.service'
```

2. Attach a scratch disk or USB device and mount it at `/mnt/restore`. Confirm it
   is a real mount before writing to it; otherwise the restore lands on the OS
   disk, which is disposable:

```sh
ssh core@devbox 'findmnt /mnt/restore'
```

3. List snapshots:

```sh
ssh core@devbox 'sudo oc-restic snapshots'
```

4. Restore the chosen snapshot into the scratch mount. The override mounts the
   target writable; the default mount is read-only:

```sh
ssh core@devbox 'sudo RESTIC_MOUNT=/mnt/restore:/restore:rw \
  oc-restic restore latest --target /restore'
```

5. Inspect `/mnt/restore/data`. Confirm the OpenCode session database, the repos,
   and the config are present and readable.
6. Copy the restored tree into `/srv`, which is still the mounted data disk:

```sh
ssh core@devbox 'sudo rsync -aHAX --delete /mnt/restore/data/ /srv/'
```

7. Start the container and confirm health:

```sh
ssh core@devbox 'sudo systemctl start opencode.service'
ssh core@devbox 'sudo podman ps --format "{{.Names}} {{.Status}}"'
```

8. Unmount the scratch device. Keep it until a client has read a session from the
   restored data.

A backup that has never been restored is an assumption. Run this drill on a
throwaway disk before trusting the nightly job.

## Prune backups

Retention is manual. Inspect first, then forget and prune:

```sh
ssh core@devbox 'sudo oc-restic snapshots'
```

Then decide a policy, for example `--keep-daily 7 --keep-weekly 4
--keep-monthly 6`, and run:

```sh
ssh core@devbox 'sudo oc-restic forget --keep-daily 7 --keep-weekly 4 \
  --keep-monthly 6 --prune'
```

Never remove the newest snapshot before a verified restore.

## Roll back the container

The OpenCode quadlet follows `:prod`. Every build also publishes an immutable
`sha-<commit>` tag. Rollback is a re-point of `:prod` to the previous digest,
a pull of that tag on the host, and then a restart.

A restart alone changes nothing: neither quadlet sets `Pull=`, so podman reuses
the local image and `systemctl restart` starts the same build again. The pull is
the step that moves the host.

`image/prod-digest.txt` holds the digest `:prod` currently names. It records one
image, so the previous digest comes from git, which logged every move:

```sh
git log --oneline -- image/prod-digest.txt
git show <previous-commit>:image/prod-digest.txt
```

The first line names the commit that set the current value. The line after it
names the move before that: use its commit in the second command, whose line
starting `sha256:` is the previous digest. The value already carries the prefix.

Re-point `:prod` at it from a workstation logged in to GHCR:

```sh
digest=<the full recorded digest>
podman pull ghcr.io/ultus-net/devbox@$digest
podman tag ghcr.io/ultus-net/devbox@$digest ghcr.io/ultus-net/devbox:prod
podman push --digestfile /tmp/prod-digest.txt ghcr.io/ultus-net/devbox:prod || exit 1
cat /tmp/prod-digest.txt
```

The digestfile holds the digest GHCR now stores for the tag. The push stops the
procedure when it fails, so an earlier attempt's file cannot be read as this
one's. Keep the value for the check below: a re-tagged local image is pushed as
a single manifest, so its digest can differ from a recorded index digest.

Pull the re-pointed tag on the host, then restart:

```sh
ssh core@devbox 'sudo podman pull ghcr.io/ultus-net/devbox:prod'
ssh core@devbox 'sudo systemctl restart opencode.service'
```

Prove the host runs the rolled-back build:

```sh
ssh core@devbox 'sudo podman image inspect \
  --format "{{.RepoDigests}}" ghcr.io/ultus-net/devbox:prod'
```

The output must contain the digest the push wrote to `/tmp/prod-digest.txt` for
this platform. The list can hold both the index and the per-architecture digest,
so check for the expected name rather than the last entry. If it is absent, the
pull did not replace the tag: read the pull output, run
`sudo podman login ghcr.io` if it asked for credentials, and confirm in GHCR that
the re-pointed tag exists.
`podman auto-update` runs the same pull, so it cannot repair a tag that did not
move.

To do the pull and the restart in one step instead, run auto-update. It keeps the
new image only if the health check passes:

```sh
ssh core@devbox 'sudo podman auto-update'
```

Record the digest that is now live in `image/prod-digest.txt` in a PR, so the
next rollback reads the image the host actually runs. Rollback is an undo, not a
forward fix, so that record makes the next rollback return to the build you have
just left. `image.yml` prints the promoted digest in its job summary. When the
record is stale it pushes a `chore/prod-digest-<run-id>` branch, prints a compare
URL and fails the run, because the workflow token cannot open a PR. Open that URL,
read the one-line diff and merge it as a human override. Delete the branch after
the merge: a leftover repair branch blocks the next one. A main push that only
rewrites the record does not rebuild, so the merge cannot re-stale it. A manual
re-point below does not run that check, so after one edit the record yourself.

If GHCR is unreachable, the host keeps running the local image. Do not delete the
local image until the rollback is confirmed.

## Roll back the OS

ucore is an ostree system, so the previous deployment is still on disk.

```sh
ssh core@devbox 'sudo rpm-ostree status'
ssh core@devbox 'sudo rpm-ostree rollback'
ssh core@devbox 'sudo systemctl reboot'
```

This restores the OS only. It does not restore application data, reverse a
database migration, or recover deleted files.

## Rejoin the tailnet

The tailnet is the only data path. If the box is unreachable, get console access
first. A keyless install starts with neither a key nor node state, so
`oc-tailnet.service` is failed until you join. The console autologins as `core`
on tty1. Join with the same flags the unit uses, then restart it:

```sh
sudo tailscale up --auth-key tskey-auth-... --hostname devbox --accept-routes=false
sudo systemctl restart oc-tailnet.service
```

A node that already has state needs only the restart and the diagnosis:

```sh
sudo tailscale status
sudo systemctl restart oc-tailnet.service
sudo journalctl -u oc-tailnet.service -u tailscaled --no-pager | tail -40
```

The node must stay non-ephemeral and keep its hostname, or MagicDNS and the
client's saved server URL break. If the node key has expired, mint a new auth key
in the Tailscale admin console with the `tag:devbox` tag, write it to
`/etc/devbox/tailscale-authkey` at mode 0600, and restart the unit.

Never paste the key into a git-tracked file or the container image.

## Replace the data disk

The OS disk and the data disk are separate devices. Replacing the data disk does
not require reinstalling the OS.

1. Stop the container and the backup timer.
2. Power off the box.
3. Replace the data disk.
4. Boot with the new disk.
5. Prepare the new disk with one GPT partition labelled `data` and an ext4
   filesystem labelled `data`, then restore `/srv` from restic. Preparing the
   disk destroys its contents, so confirm the device first.
6. Confirm the `var-srv.mount` unit is active and `/srv` is on the new device:

```sh
systemctl status var-srv.mount
findmnt /srv
```

7. Start the container and run the restore drill.

The mount unit uses the `data` filesystem label, so a device with a different
`/dev/disk/by-id/` path needs no edit. If the filesystem carries another label,
relabel it to `data` before boot. Never hand-edit the unit on the running host and
leave it there.

## Replace the OS disk

The OS disk is disposable. The data disk is not, and this procedure must never
touch it.

1. Confirm a restic snapshot exists and is readable.
2. Follow `docs/install.md` from step 4.5 (the `coreos-installer` command) only.
   **Do not run install step 4.4.** That step creates the `data` partition and
   filesystem and destroys the disk. On an OS reinstall the data disk already
   holds `/srv`; Ignition mounts it by label and leaves it alone.
3. After the rebase, confirm `var-srv.mount` is active and `/srv` still holds the
   repositories and sessions. If the rebuild was keyless, join from the console
   first; `ssh` needs the tailnet.
4. Re-provision `/etc/devbox/secrets.env` and start `oc-env` and `opencode`.
5. Re-pair the client if the tailnet name changed. It should not, because the
   hostname is pinned.

If the data disk was accidentally formatted, stop and restore from restic before
starting the workload. Do not write to the fresh filesystem first.

## Rehearse a host change in the VM

Any change to `os/butane/`, `host/`, `image/` or a quadlet is rehearsed under QEMU
before it reaches the Mini. The VM runs the same Ignition and the same containers,
so a broken mount, a masked unit or a stray LAN listener surfaces on the
workstation instead of on the always-on box.

1. Apply the change and run `./tests/verify.sh`. It must end with
   `VERIFY: all suites pass`.
2. Run the harness with a clean slate:

   ```sh
   ./vm/run-vm.sh --rebuild
   ```

   It takes 10 to 20 minutes, mostly the rebase download.
3. Read the report. It must end with `VM DOGFOOD: pass` and `SUMMARY failures=0`.
   A `SKIP` is allowed only for a conditional guard the image does not meet, and
   the report names which one.
4. On a failure, the log names the assertion. `journalctl` inside the guest
   carries the unit output; attach with
   `socat -,raw,echo=0 UNIX-CONNECT:.vm-cache/serial.sock` and detach with
   `Ctrl-a x`.
5. Power the VM down with `./vm/run-vm.sh --stop` once the run is recorded.

Ignition is first-boot only, so `--rebuild` is what makes a rerun meaningful. A
run without it boots the existing overlay and waits for a report the check unit
will not produce again.

## Hardware checks

Run these monthly, and after any unexplained reboot.

```sh
ssh core@devbox 'sensors'
ssh core@devbox 'lsblk -o NAME,SIZE,MODEL,SERIAL'
ssh core@devbox 'sudo smartctl -a /dev/nvme0n1 | head -40'
ssh core@devbox 'sudo smartctl -a /dev/nvme1n1 | head -40'   # data disk on the second M.2
ssh core@devbox 'sudo smartctl -a /dev/sda | head -40'        # data disk in the SATA caddy
ssh core@devbox 'journalctl -k -p err -b'
```

Run the SMART line that matches where the data disk sits. Watch for a fan that
never spins up, a disk that reallocates sectors, or thermal throttling in the
journal. The 35W T-series part runs cool, but a dust-clogged heatsink still
pushes the idle temperature up; if it idles above 70 C, clean the dust and
confirm the fan spins. Run the UPS self-test and check the cell age at the unit's
panel. Keep a spare 65W adapter and watch the journal for brownout resets.

## Power loss

The UPS covers a short outage. The firmware powers the box back on after a long
one. Without the UPS, the first cut is an unclean shutdown.

After a power event, confirm:

```sh
ssh core@devbox 'uptime'
ssh core@devbox 'systemctl --failed'
ssh core@devbox 'sudo podman ps'
ssh core@devbox 'sudo systemctl status var-srv.mount'
```

The filesystem is ext4 on the data disk. A power loss can still leave it dirty;
the boot repairs it. A repeated unclean shutdown is a reason to test the UPS and
the 65W adapter, not to disable the journal.

## What is on the box, and what survives

| Layer | Survives an OS reinstall? | Recovery |
|---|---|---|
| OS image (ucore) | no, by design | reinstall from Fedora CoreOS media and rebase |
| Container image | no | pulled from GHCR on first boot after the network is up |
| Data disk (`/srv`) | yes, if the disk survives | reattached, or restored from restic |
| Session database | yes, on the data disk | part of the data disk restore |
| Repos | yes, on the data disk | part of the data disk restore, but push anyway |
| `/etc/devbox/secrets.env` | no | re-provisioned from the password manager |

The data disk is not a backup. The restic repository is. Anything you would
grieve over must be pushed to a remote or included in the backup.
