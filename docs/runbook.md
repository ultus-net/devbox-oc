# Devbox runbook

Operating procedures for the devbox. Written for the case where something has
already gone wrong.

Replace the placeholders with your own values:

```sh
RG=rg-devbox-oc
VM=vm-devbox-oc
DISK=disk-devbox-oc-data
```

## What is on the box, and what survives

| Layer | Survives a rebuild? | Recovery |
|---|---|---|
| OS image (ucore) | no, by design | rebuild from the published managed image |
| Container image | no | pulled from ACR by digest |
| Data disk (`/srv`) | **yes**, `prevent_destroy` | reattached, or restored from snapshot |
| Session database | yes, on the data disk | part of the data disk restore |
| Repos | yes, on the data disk | part of the data disk restore, but push anyway |

The data disk is **not a backup**. Nightly incremental snapshots give a 24 hour
recovery point for uncommitted work. Anything you would grieve over must be
pushed to a remote. That RPO was chosen deliberately, in exchange for a cheap
snapshot bill.

## Restore the data disk

Use this when the disk is corrupt, or when a change needs rolling back.

1. Stop the workload first, so nothing writes during the restore.

```sh
az vm deallocate -g "$RG" -n "$VM"
```

2. Detach the current disk.

```sh
az vm disk detach -g "$RG" --vm-name "$VM" --name "$DISK"
```

3. List recent snapshots. This query returns the **id**, which step 4 needs. An
   earlier form of this query returned only names, which left step 4 with nothing
   to consume.

```sh
az snapshot list -g "$RG" \
  --query "sort_by([?contains(name,'devbox-data-')].{name:name,time:timeCreated,id:id},&time)[-5:]" \
  -o table
```

4. Create a new disk from the snapshot you chose. Never restore in place: the
   source disk is the fallback if the restore is wrong.

```sh
az disk create -g "$RG" -n "${DISK}-restore" --source "<snapshot-id>"
```

5. Attach the restored disk in place of the original.

```sh
az vm disk attach -g "$RG" --vm-name "$VM" --name "${DISK}-restore" --lun 0
```

6. Start the box and verify before trusting it.

```sh
az vm start -g "$RG" -n "$VM"
# then, over the tailnet:
ssh core@devbox "sudo mount /srv && ls -la /srv/opencode/share"
```

7. Promote only after reading the restored copy. Keep the original disk until you
   are certain.

A restore from an incremental snapshot runs a background copy. On Standard SSD
the completion percentage is not reported, so allow a few minutes before the first
mount.

## Prune snapshots

Retention is deliberately manual. Removing backups from a timer is a destructive
action that deserves a human decision, so no automation does it.

Inspect what exists with the listing below, then remove what you no longer need
from the Azure portal, or from the CLI using the snapshot removal command
documented at `https://learn.microsoft.com/en-us/cli/azure/snapshot`. Never
remove the newest snapshot before a verified restore.

```sh
az snapshot list -g "$RG" --query "[?contains(name,'devbox-data-')].{n:name,t:timeCreated}" -o table
```

## Roll back the container

Two operations, because the tag is what `podman auto-update` follows and the
digest is what tells you what that tag used to point at.

```sh
sudo podman auto-update --dry-run          # what would change
cat /srv/devbox/image/prod-digest.txt      # what prod pointed at
```

To pin back to a known-good digest, re-point `:prod` at it and restart the
quadlet-generated unit:

```sh
az acr import -n <acr> --source <acr>.azurecr.io/devbox@sha256:<old> --image devbox:prod --force
sudo systemctl restart opencode.service
```

## Roll back the OS

ucore is an ostree system, so the previous deployment is still on disk.

```sh
sudo rpm-ostree status        # see current and previous
sudo rpm-ostree rollback
sudo systemctl reboot
```

This restores the OS only. It does not restore application data, reverse a
database migration, or recover deleted files.

## Rejoin the tailnet

The tailnet is the only data path. If the box is unreachable, get console access
first (Azure Bastion Developer, which is free), then:

```sh
sudo tailscale status
sudo systemctl restart oc-tailnet.service
sudo journalctl -u oc-tailnet.service -u tailscaled --no-pager | tail -40
```

The node must stay **non-ephemeral** and keep its hostname, or MagicDNS and the
client's saved server URL break. If the node key has expired, mint a new auth key
in the Tailscale admin console and store it in Key Vault under the name the
`oc-tailnet-up` unit reads. Never paste it into Ignition, which is retrievable by
anyone with read on the VM.

## The idle gate

The box deallocates itself after 45 idle minutes. It stays up while any of these
is true: a running session, a running shell, an open terminal, a pending approval,
or a pending form.

To hold the box awake for work the gate cannot see, create the pin file, and
remove it when done:

```sh
sudo touch /var/lib/oc-idle/pin
sudo rm /var/lib/oc-idle/pin
```

To confirm what the gate sees without acting on it:

```sh
sudo DRY_RUN=1 oc-idle-check
```

## Wake the box

```sh
oc            # starts the VM, waits for health, then opens the TUI
```

Cold start is 60 to 120 seconds. If `oc` times out, the container may have failed
to pull its image; check with `sudo journalctl -u opencode.service`.
