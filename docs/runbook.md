# Devbox runbook

> **Superseded for the whole stack.** The deployed VM, NIC, NSG, data disk, ACR
> and Key Vault are declared in the `csh-dev` repo's Bicep. The Terraform
> sources here are the port record, not a deployment path: **do not run
> `terraform apply`**. The recorded start schedule targets the old Terraform VM,
> so it is dormant until `csh-dev` declares it. The live stages below read the
> deployed names from Azure.

Operating procedures for the devbox: first deployment, and the case where
something has already gone wrong.

Replace the placeholders with your own values:

```sh
RG=rg-csh-dev
VM=vm-csh-dev
DISK=disk-csh-dev-data
```

## First deploy, from clone to a connected client

The order below is not arbitrary. Each stage produces a value the next one
consumes, and two of them fail loudly if run out of order.

### 1. Fill in the variables

This step belongs to the superseded Terraform path. The live `csh-dev` deploy
takes `vmImageId` as a queue-time parameter and the Ignition config as the
`ucore.ign` secure file, so keep the image id from stage 2 for `vmImageId`.

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
- `os_image_id` is the Terraform record's managed image resource ID; the live
  deploy passes the same ID as `vmImageId`. Stage 2 prints it.

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

The last line of output is the image resource ID. Keep it for `vmImageId`. The
script also prints the VHD sha256 and the staging disk name to stderr: record the
hash, and delete `devbox-ucore-<yyyymmdd>-disk` from `rg-csh-dev` after
`az image show --query hyperVGeneration` reports `V2`. The image holds its own
copy, so the disk is only a staging area.

The upload target is a managed disk, not a storage account. The script creates an
upload-ready disk, takes a write SAS with `az disk grant-access`, uploads the VHD
to that SAS, revokes access, and creates the image from the disk id. The publish
flow names no storage account, and the deleted `cshdevfilesb6lmephspqf2u` stays
deleted.

`pipelines/devbox-os.yml` sets `resourceGroup` to `rg-csh-dev` and `location` to
`newzealandnorth`. Set the `imageBuilderContainer` digest there too if you change
it; it is pinned for the same reason the OS is. The script path needs `podman`
and `az` on PATH, with either a host `image-builder` or
`IMAGE_BUILDER_CONTAINER` naming the pinned builder image. `RG` and `LOCATION`
default to `rg-csh-dev` and `newzealandnorth`, so override them only to publish
somewhere else. The pipeline installs podman and runs the builder container, so
prefer the pipeline. Run `DRY_RUN=1 ./os/build-os-image.sh` to print the image id
it would create without pulling, uploading, or requiring a disk. That works
before the resource group exists, because the dry run answers before it requires
one.

The OS comes from `UCORE_IMAGE`, a digest-pinned reference to
`ghcr.io/ublue-os/ucore-minimal`. A tag is rejected rather than resolved, so the
published image cannot drift. Change the digest deliberately, and record the new
one in the design's verified-facts table.

`image-builder` needs `--bootc-default-fs` because Fedora bootable containers do
not declare a root filesystem. `BUILD_FS` defaults to `ext4`, which is what Azure
expects.

The VM's generation is not set by the deployment template: Azure takes it from
the image. What matters is the image itself, so `os/build-os-image.sh` passes
`--hyper-v-generation V2` to both `az disk create` and `az image create`.
`os/tests/test_build_os_image.sh` guards both arguments. Confirm the published
image reports `V2` before the first boot; a Gen1 image cannot boot this UEFI
artifact, and the failure appears at create time.

### 3. Generate Ignition with real values

The repository ships `os/butane/ucore.ign` compiled from placeholders. Stage one
of the `csh-dev` pipeline must have run first (`deployVm=false`), because it
creates the vault and disk the Ignition config names. The Terraform port record
refuses to plan against placeholders, and the `csh-dev` deploy boots the file as
`customData`, so the check matters either way: a placeholder config would boot a
VM whose SSH key is a well-known dummy.

```sh
export SUBSCRIPTION_ID="$(az account show --query id -o tsv)"
export RG=rg-csh-dev
export ACR_NAME="$(az acr list -g "$RG" --query '[0].name' -o tsv)"
export SSH_PUBKEY="$(cat ~/.ssh/id_ed25519.pub)"

# Read the names the csh-dev deployment created. The vault and disk names come
# from the template and are visible in Azure after stage one, so no state is
# involved.
export VAULT_NAME="$(az keyvault list -g "$RG" --query '[0].name' -o tsv)"
export DISK_ID="/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RG}/providers/Microsoft.Compute/disks/disk-csh-dev-data"

./os/butane/build.sh
```

`VAULT_NAME` is the vault the `csh-dev` stage-one deployment created, named
`toLower('<appName>kv<uniqueString(resourceGroup().id)>')`. Nothing else in that
resource group is a vault, and both `csh-dev` and the Ignition consumers read the
name from the deployment output, so the suffix is transparent. `DISK_ID` follows
from the disk name in the same template. Ignition is built after stage one, which
is what breaks the circularity: the vault and disk exist before the VM that
refers to them.

Two consequences worth knowing:

- A vault name is a global DNS name. Two boxes in one subscription with the same
  `appName` collide, so give each box its own.
- `enableSoftDelete` keeps a removed vault's name reserved for seven days.
  Rebuilding under the same `appName` fails on the name until that window passes.

### 4. Deploy the VM (superseded path)

This stage is superseded: the VM, NIC, NSG and data disk are deployed from the
`csh-dev` Bicep, not from this repo. The commands are kept as the record of the
old path. Do not run them. The live deploy is `pipelines/azure-pipelines.yml` in
`csh-dev`: upload `os/butane/ucore.ign` as a secure file named `ucore.ign` in the
pipeline library, then queue the pipeline with `deployVm=true` and `vmImageId`
set to the stage-2 image id. The post-deploy check runs on the same flag and
reads the deployed NIC and NSG.

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
names `fedora-coreos`, the VM booted the wrong image: check that `vmImageId`
named the image `pipelines/devbox-os.yml` published, not an older one.

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
| Data disk (`/srv`) | **yes**, `deleteOption: Detach` in `csh-dev` Bicep | reattached, or restored from snapshot |
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
cat ~/devbox-oc/image/prod-digest.txt      # what prod pointed at, from your clone
```

The digest record lives in the repo, not on the host. Read it from your working
copy, or from the Azure Pipelines run that committed it. Nothing writes it to the
data disk, so a path under `/srv` would name a file that does not exist.

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
