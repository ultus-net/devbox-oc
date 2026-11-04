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
ssh core@devbox 'systemctl is-active oc-env opencode oc-tailnet'
ssh core@devbox 'sudo podman ps --format "{{.Names}} {{.Status}}"'
ssh core@devbox 'sudo systemctl list-timers oc-backup.timer'
ssh core@devbox 'df -h /srv'
ssh core@devbox 'findmnt -no SOURCE /srv'
```

`oc-env` and `opencode` must both be active. A failed `oc-env` stops the
container by design. `podman ps` must show the container as `healthy`. `findmnt`
must name the data device, not the OS disk.

## Rotate the OpenCode password

1. Generate a new value and store it in the password manager.
2. Edit `/etc/devbox/secrets.env` on the box, replace `OPENCODE_PASSWORD`, and
   keep the file at mode 0600.
3. Restart the writer and the container:

```sh
ssh core@devbox 'sudo systemctl restart oc-env.service opencode.service'
```

4. Pair the client again with `opencode pair --url ...`, or update the TUI's
   saved password.

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
Pruning is manual.

## Restore from restic

Use this when `/srv` is corrupt, a file was deleted, or the data disk was
replaced. Never restore over the live `/srv` in one step. Restore to a scratch
device, inspect it, then copy the contents into `/srv`.

The backup snapshot root is `/data`, because `/srv` is mounted at `/data` inside
the container. A restore therefore lands at `/restore/data/...`.

1. Stop the workload so nothing writes during the restore:

```sh
ssh core@devbox 'sudo systemctl stop opencode.service'
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

The quadlet follows `:prod`. Every build also publishes an immutable
`sha-<commit>` tag. Rollback is a re-point of `:prod` to the previous digest,
then a restart.

```sh
ssh core@devbox 'sudo podman auto-update --dry-run'
cat image/prod-digest.txt
```

The digest record is in the repository, not on the host. `image.yml` prints the
promoted digest in its job summary, because a workflow token cannot push to the
protected `main`. After a production build, copy that digest into
`image/prod-digest.txt` in a PR. That PR is the rollback record.

Pull the previous digest, tag it `:prod`, push it back to GHCR, then restart:

```sh
ssh core@devbox 'sudo systemctl restart opencode.service'
```

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
first, then:

```sh
sudo tailscale status
sudo systemctl restart oc-tailnet.service
sudo journalctl -u oc-tailnet.service -u tailscaled --no-pager | tail -40
```

The node must stay non-ephemeral and keep its hostname, or MagicDNS and the
client's saved server URL break. If the node key has expired, mint a new auth key
in the Tailscale admin console, write it to `/etc/devbox/tailscale-authkey` at
mode 0600, and restart the unit.

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
6. Confirm the `srv.mount` unit is active and `/srv` is on the new device:

```sh
systemctl status srv.mount
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
3. After the rebase, confirm `srv.mount` is active and `/srv` still holds the
   repositories and sessions.
4. Re-provision `/etc/devbox/secrets.env` and start `oc-env` and `opencode`.
5. Re-pair the client if the tailnet name changed. It should not, because the
   hostname is pinned.

If the data disk was accidentally formatted, stop and restore from restic before
starting the workload. Do not write to the fresh filesystem first.

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
ssh core@devbox 'sudo systemctl status srv.mount'
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
