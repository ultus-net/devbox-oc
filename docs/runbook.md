# Devbox runbook

Operating procedures for the devbox: first deployment, and the case where
something has already gone wrong.

Replace the placeholders with your own values:

```sh
RG=rg-devbox-oc
VM=vm-devbox-oc
DISK=disk-devbox-oc-data
```

## First deploy, from clone to a connected client

The order below is not arbitrary. Each stage produces a value the next one
consumes, and two of them fail loudly if run out of order.

### 1. Fill in the variables

```sh
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
$EDITOR terraform/terraform.tfvars
```

Everything in the example is commented out, so a copied file sets nothing and
`terraform plan` fails with `No value for required variable`. That is deliberate:
an obvious failure beats a silently inherited placeholder.

The two values easiest to get wrong:

- `acr_name` must already exist and match `^[a-z0-9]{5,50}$`. Leaving it empty
  removes the only image pull path.
- `os_image_id` is a managed image resource ID. Stage 2 prints it.

Set `opencode_password` and `tailscale_authkey` from your secret store, or as
`TF_VAR_opencode_password` and `TF_VAR_tailscale_authkey` environment variables.
Never commit `terraform.tfvars`; it is gitignored for that reason.

### 2. Publish the OS image

Fedora and ucore both publish no Azure VHD, so the first step builds one from the
upstream ucore-minimal bootc container and publishes it as a managed image. The
image already is ucore, so the box boots it directly with no rebase stage.

```sh
az pipelines run --name devbox-os            # or: ./os/build-os-image.sh
```

The last line of output is the image resource ID. Put it in `os_image_id`.

Before either path runs, set the pipeline's `resourceGroup` and `storageAccount`
variables in `pipelines/devbox-os.yml`. Storage account names are globally
unique, so the placeholder there is certainly wrong. The script path needs
`image-builder`, `podman`, and `az` on PATH, with `RG` and `STORAGE_ACCOUNT`
exported; the pipeline installs a pinned `image-builder`, so prefer the pipeline.
Run `DRY_RUN=1 ./os/build-os-image.sh` to print the image id it would create
without pulling or uploading anything. That works before a storage account
exists, because the dry run answers before it requires one.

The OS comes from `UCORE_IMAGE`, a digest-pinned reference to
`ghcr.io/ublue-os/ucore-minimal`. A tag is rejected rather than resolved, so the
published image cannot drift. Change the digest deliberately, and record the new
one in the design's verified-facts table.

`image-builder` needs `--bootc-default-fs` because Fedora bootable containers do
not declare a root filesystem. `BUILD_FS` defaults to `ext4`, which is what Azure
expects.

The VM's generation is not set in Terraform: `azurerm_linux_virtual_machine` has
no `hyper_v_generation` argument in the azurerm 4.x provider, and Azure takes the
generation from the image. What matters is the image itself, so
`os/build-os-image.sh` passes `--hyper-v-generation V2` to `az image create`.
`os/butane/tests/test_bootc_image.sh` guards that argument. Confirm the first
apply produces a Gen2 VM; a Gen1 VM cannot boot this UEFI image, and the failure
appears at create time.

### 3. Generate Ignition with real values

The repository ships `os/butane/ucore.ign` compiled from placeholders. Terraform
refuses to plan against it, through a precondition that matches `placeholder`,
`devbox-placeholder` and a zero subscription ID. That guard exists because a
placeholder config would otherwise boot a VM whose SSH key is a well-known dummy.

```sh
# Terraform resolves the names below, so init first. Init downloads providers
# only; it creates nothing in Azure.
terraform -chdir=terraform init

export SUBSCRIPTION_ID="$(az account show --query id -o tsv)"
export RG=rg-devbox-oc
export ACR_NAME=youracr
export SSH_PUBKEY="$(cat ~/.ssh/id_ed25519.pub)"

# Both names are derived from tfvars, not read from state. `terraform output`
# fails here, because nothing has been created yet.
export VAULT_NAME="$(terraform -chdir=terraform console <<<'local.key_vault_name' | tr -d '"')"
export DISK_ID="/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RG}/providers/Microsoft.Compute/disks/disk-devbox-oc-data"

./os/butane/build.sh
```

`VAULT_NAME` is `kv-<name_prefix>-<hex of sha256(subscription_id)>`, where the
hex run shrinks as the prefix grows so the whole name stays within 24 characters.
`DISK_ID` follows from `name_prefix` plus the subscription. Neither needs state,
which is the whole point: Ignition must exist before the apply that creates the
resources Ignition refers to. A randomly suffixed vault name would make that
circular, so the suffix is derived instead.

Two consequences worth knowing before you pick a `name_prefix`:

- A vault name is a global DNS name. Two boxes in one subscription that share a
  prefix collide, so give each box its own.
- `purge_protection_enabled` keeps a removed vault's name reserved for seven
  days. Removing the stack and immediately re-applying fails on the name until
  that window passes. Use a different prefix if you need one now.

### 4. Apply

```sh
terraform -chdir=terraform init
terraform -chdir=terraform plan -out=tfplan     # confirm no public IP appears
terraform -chdir=terraform apply tfplan
```

If the plan fails with the placeholder message from stage 3, `ucore.ign` was not
regenerated. Go back; do not bypass the guard.

### 5. Build and promote the container image

```sh
az pipelines run --name devbox-image
```

This builds, smoke-gates against the real image, promotes to `:prod`, and commits
the resolved digest to `image/prod-digest.txt`. The box's `podman auto-update`
follows `:prod`, so the image reaches the host without a redeploy.

### 6. Verify first boot

The published image is built from the ucore bootc container, so first boot is one
boot. The VM starts already on ucore; there is no rebase stage and no reboot.

```sh
az vm start -g "$RG" -n "$VM"
```

Prove the booted OS is ucore:

```sh
ssh core@devbox "sudo rpm-ostree status"
```

The booted deployment must name `ghcr.io/ublue-os/ucore-minimal`. Every host unit
below depends on ucore packages, so nothing else works until this is right. If it
names `fedora-coreos`, the VM booted the wrong image: check that `os_image_id`
points at the image `pipelines/devbox-os.yml` published, not an older one.

Then confirm the devbox units and the daemon the tailnet path needs:

```sh
ssh core@devbox "systemctl is-active tailscaled oc-secrets oc-tailnet opencode"
ssh core@devbox "systemctl is-enabled tailscaled"
ssh core@devbox "sudo podman ps --format '{{.Names}} {{.Status}}'"
```

All four units must report `active` and the container must be `healthy`. If
`opencode` is not active, `oc-secrets` failed first: check
`sudo journalctl -u oc-secrets -n 40`. If `tailscaled` is not active there is no
tailnet path and the box needs Bastion: check
`sudo journalctl -u tailscaled -n 40`.

The password path is not a default inside the script. `/etc/devbox/oc-secrets.env`
defines `OUT_FILE`, written by Ignition, and `oc-secrets` fails rather than inventing
one. A boot that reports `OUT_FILE is required` means that env file is missing, which
points at Ignition rather than at Key Vault. `oc-idle-check` reads the same definition,
so the idle gate follows the password path instead of carrying its own copy. It does
not fail when the definition is absent: the env file never arriving means nothing is
being served, so the gate falls through and the box still deallocates.

`is-active` alone does not prove enablement is right: `oc-tailnet` carries an
unconditional `Wants=tailscaled`, so the daemon starts whether or not it is
enabled. `is-enabled` must say `enabled`. If it says `disabled`, enable it by hand
with `sudo systemctl enable --now tailscaled` before pairing a client, and check
`sudo journalctl -u tailscaled -n 40` to see why the preset did not apply.

### 7. Connect a client

```sh
opencode pair --url https://devbox.<tailnet>.ts.net   # desktop app
opencode --server https://devbox.<tailnet>.ts.net     # TUI
```

Set `OPENCODE_PASSWORD` from Key Vault for the TUI. The pairing link is
single-use and expires in five minutes.

Cockpit is published on its own HTTPS port, `https://devbox.<tailnet>.ts.net:8443`
by default. It listens on loopback only and is reachable over the tailnet, never
the VNet or the internet. Do not expect port 9090 to answer: an Ignition drop-in
rebinds the socket to `127.0.0.1:9090`, and `host/tests/test_cockpit_loopback.sh`
fails the gate if that drop-in is lost.

### 8. Confirm the cost model

Leave the box alone with no session for fifty minutes, then check:

```sh
ssh core@devbox "sudo journalctl -t oc-idle -n 5"
```

Expect `idle for 45m, deallocating`. If the log is empty, the gate is not running:
`systemctl list-timers oc-idle.timer`.

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

A failed secret bootstrap is not one of those, and it needs care. The quadlet
carries `Requires=oc-secrets.service`, so if Key Vault or the ACR login fails the
container never starts and nothing is listening on port 4096. The gate then
distinguishes two cases:

| Container | API answer | Gate behaviour |
|---|---|---|
| running | unreadable | stays up, because a half-started container may hold a session |
| not running | unreadable | idle, so the box deallocates and stops billing |

That second row is why the gate asks `systemctl is-active opencode.service`
instead of treating every probe failure as busy. A box that refuses to serve must
not also refuse to stop.

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
