# Install the devbox on the HP EliteDesk Mini

**Status:** the recorded first-install procedure. No step here has run on the
Mini. The VM rehearsal in step 0 runs the same Ignition, and it passes.

This is the first install path. It assumes physical access, a wired network, two
disks, and a second machine to prepare the USB sticks and reach the box later.
Read `docs/design.md` first; the decisions there explain why the steps are in
this order.

Every step has three parts: the command, what success looks like, and what to do
when it fails. Run the steps in order, and do not skip a check. A command that
prints an error is a stop, not a warning.

## Before you start

Fill this in as you go. It is the record you need when a step fails, and it is
the input to step 4.

| Item | Where it comes from | Record it here |
|---|---|---|
| Firmware version | BIOS setup, step 1.1 | |
| Secure Boot state | BIOS setup, step 1.1 | |
| OS disk `/dev/disk/by-id/...` | live media, step 4.3 | |
| Data disk `/dev/disk/by-id/...` | live media, step 4.3 | |
| `OC_HOSTNAME` (MagicDNS name) | your choice, default `devbox` | |
| Tailnet name | Tailscale admin console | |

Two rules carry the whole procedure:

- **Never run step 4.4 twice.** It erases the data disk. On an OS reinstall the
  disk already holds `/srv`, and `docs/runbook.md` sends you to step 4.5 only.
- **Confirm a device before you write to it.** Read its model and serial in the
  output, not just its name. A wrong path is unrecoverable.

The recovery doors, in order: the `tty1` console autologins as `core`; Intel
AMT/PiKVM if the SKU has it; then the live USB and step 4.5 to reinstall the OS
without touching the data disk.

## 0. Rehearse in a VM

Run the install in QEMU on the preparation machine first. It uses the same
`os/butane/ucore.bu` this install ships, so a config fault surfaces with no disk
at risk and no trip to the server room.

```sh
./vm/run-vm.sh --rebuild
```

It takes 10 to 20 minutes. Then power it down:

```sh
./vm/run-vm.sh --stop
```

**Expect:** the run ends with `VM DOGFOOD: pass` and `SUMMARY failures=0`. A
`SKIP` is allowed only for a conditional guard the image does not meet, and the
report names which one.

**If it fails:** the log names the failed assertion. Do not continue to bare
metal. Fix the config and rerun. `docs/vm.md` has the harness procedure and the
list of what a pass still cannot prove.

Skip this only when an earlier run already passed on the current Ignition. Rerun
it after every change to `os/butane/`, `host/`, `image/` or a quadlet.

## 1. Prepare the hardware

### 1.1 Update the firmware and set the power policy

1. Update the HP firmware from the vendor. It is easier before Linux is on the
   disk.
2. In firmware setup, set:
   - **Power On After Power Failure** to **On**. The label varies by model; look
     for "AC Power Recovery" or "After Power Loss".
   - **Wake on LAN** to **Off**. The box is always on and has no LAN listener.
   - **Intel vPro/AMT** to **On** if the SKU has it and the server-room network
     allows it. It is the out-of-band console when the tailnet is down.
   - **Secure Boot** to **Off** until the ucore signing key is enrolled. The
     enrollment guide is `https://projectucore.org/docs/secure-boot/`. Enroll
     the key after the install if policy requires Secure Boot.
3. Write the firmware version and the Secure Boot state in the table above.

**Expect:** firmware setup shows Power On After Power Failure On, Wake on LAN
Off, and Secure Boot Disabled.

**If it fails:** a setting that will not stick usually needs the firmware
password or a save-and-exit. Re-enter setup and confirm the value after reboot.

### 1.2 Fit the disks and decide their roles

The OS disk is disposable. The data disk holds `/srv`, which is the part you
cannot rebuild.

- Fit the OS disk in the M.2 slot. Use the smaller disk when the two differ.
- Fit the data disk in the second M.2 slot on the 800 G4, or in the 2.5 inch SATA
  caddy on either model. Use the larger disk.
- When the two disks are identical, pick either one for the OS. The roles are
  fixed by the ids you record in step 4.3, not by the hardware.
- Confirm the caddy and the screws came with the chassis before relying on the
  SATA bay.

**Expect:** both disks appear in firmware setup, and step 4.3 lists both.

**If it fails:** a disk that does not appear is not seated or is not supported.
Reseat it before installing anything.

### 1.3 Connect power, network and the UPS

Connect wired Ethernet, the 65W adapter, and the UPS. The Mini has no internal
battery, so the UPS is the only thing between a power cut and an unclean
shutdown.

**Expect:** the Ethernet link light is on and the UPS reports mains power.

**If it fails:** swap the cable or the adapter now. A dead link costs a trip
later, after the box is in the server room.

## 2. Build the Ignition file

Run this on a preparation machine with this repository checked out and Butane
0.29.0 available. The build refuses placeholder values, so a forgotten edit fails
before the USB is written.

```sh
test -s ~/.ssh/id_ed25519.pub || ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519
export SSH_PUBKEY="$(cat ~/.ssh/id_ed25519.pub)"
read -rsp 'Tailscale auth key (empty for keyless): ' TS_AUTHKEY; export TS_AUTHKEY
export OC_HOSTNAME=devbox
export IMAGE=ghcr.io/ultus-net/devbox

BUTANE=/path/to/butane-0.29.0 ./os/butane/build.sh
```

`IMAGE` names the package the workflow publishes. The build appends the digest in
`image/prod-digest.txt` and bakes `<repo>@sha256:<digest>` into the quadlet, so
the host runs one content digest rather than a tag that can move. The build
refuses a tag, an empty path component, a digest that is not the recorded one,
and a record that holds no digest. Promote a build before writing the USB.

GHCR packages are private by default, and the host pulls anonymously. Set the
package visibility to public before installing. If it must stay private, add a
read-only token and a `podman login ghcr.io` step; otherwise the container cannot
start after an OS reinstall.

`TS_AUTHKEY` is optional. With a key, the host joins the tailnet on its first
ucore boot. Create the key in the Tailscale admin console with the `tag:devbox`
tag, single-use or short-lived. The build writes it to
`/etc/devbox/tailscale-authkey`, and the host deletes that file after a
successful join, so a revoked key cannot break later boots. In a keyed build this
is the only secret on the install media.

A keyless build ships no key and is the safer choice. Leave `TS_AUTHKEY` empty
and join from the console in step 6. The console is the one door that cannot lock
you out, so it must work before the tailnet does.

`OC_HOSTNAME` is the MagicDNS name. Keep it stable, because the client's saved
server URL contains it. The default is `devbox`.

The build writes `os/butane/ucore.ign`. It is a compiled artifact. Never edit it
by hand; edit `os/butane/ucore.bu` and rebuild.

**Expect:** a keyless build prints the two-line `KEYLESS build:` warning, then
`ignition ok: .../os/butane/ucore.ign`. A keyed build prints only the
`ignition ok:` line. Both exit 0.

**If it fails:** the error names the missing input or the refused value. Nothing
has been written to a USB yet. Fix it and rerun. The binary's `--version` must
name 0.29.0; a different compiler can change the output bytes.

## 3. Write Fedora CoreOS installation media

Download the stable live ISO for x86_64 from
`https://fedoraproject.org/coreos/download/?stream=stable#baremetal`.

Verify it before writing. The download page prints the SHA-256 beside the link:

```sh
sha256sum fedora-coreos-<version>-live-iso.x86_64.iso
```

**Expect:** one 64 character hex string, identical to the value on the download
page.

**If it fails:** delete the file, download it again, and verify again. Never
write an unverified image.

Write the ISO to a USB stick with Fedora Media Writer, balenaEtcher, or `dd`.
Confirm the USB device first; every one of those tools destroys the target.

```sh
lsblk -d -o NAME,SIZE,MODEL,TRAN
sudo dd if=fedora-coreos-<version>-live-iso.x86_64.iso \
  of=/dev/sdX bs=4M status=progress conv=fsync
sync
```

Replace `/dev/sdX` with the USB device from `lsblk`, never a disk that holds
anything you want. Then confirm the stick:

```sh
lsblk -f /dev/sdX
```

**Expect:** an `iso9660` filesystem labelled `Fedora-CoreOS-...`. The capacity
is the stick's, not the ISO's.

**If it fails:** re-run `lsblk` and confirm the device. A stick that will not
boot is usually the wrong device or a failed write; write it again.

## 4. Install

Section 4 is the only part that writes to the Mini's disks. Read each substep
before running it.

### 4.1 Boot the live media

Insert the USB stick. Power on the Mini and press **Esc** at the HP logo for the
startup menu, then **F9** for the one-time boot menu. Select the USB stick under
**UEFI**. **F10** opens firmware setup if you need to change a setting first.

**Expect:** a `core@localhost` shell prompt within two minutes. If it shows a
login prompt instead, `core` has no password.

**If it fails:** a `Secure Boot violation` means step 1.1 was missed. Disable
Secure Boot, save, and boot again. A stick that never appears in the boot menu
was written to the wrong device or is not UEFI-bootable.

### 4.2 Stage the Ignition file

The live system needs `ucore.ign`. Use either route.

Second USB stick, if you copied `ucore.ign` onto one:

```sh
lsblk -o NAME,SIZE,LABEL,MOUNTPOINT
sudo mkdir -p /mnt/usb
sudo mount /dev/sdX1 /mnt/usb
cp /mnt/usb/ucore.ign /tmp/ucore.ign
sync
sudo umount /mnt/usb
```

Or over the network from the preparation machine, in the repository:

```sh
cd os/butane
python3 -m http.server 8000
```

Then on the live system, with the preparation machine's address:

```sh
curl -f -o /tmp/ucore.ign http://<preparation-machine-ip>:8000/ucore.ign
```

A keyed build embeds the Tailscale auth key in `ucore.ign`, in clear text. Do
not serve it over a network you do not control, and never over the internet. Use
the USB route when the LAN is shared. Stop the HTTP server as soon as the copy
finishes; the server exposes every file in `os/butane` until you do.

Confirm the copy matches the file you built, on both machines:

```sh
sha256sum /tmp/ucore.ign
```

**Expect:** the hash equals `sha256sum os/butane/ucore.ign` on the preparation
machine, and `/tmp/ucore.ign` is not empty.

**If it fails:** the mount path or the HTTP address is wrong. Do not continue
with an empty or partial file; Ignition will boot the box with no config.

### 4.3 Record the by-id paths and confirm the OS disk

```sh
lsblk -o NAME,SIZE,MODEL,SERIAL,TYPE
ls -l /dev/disk/by-id/
```

**Expect:** two whole disks of the sizes you fitted, plus the USB stick. An M.2
device has an `nvme-` prefix, a SATA device has an `ata-` prefix, and a USB stick
has a `usb-` prefix.

Now set both paths. Replace each `REPLACE_ME` with the full path, and copy the
values into the table above:

```sh
os=/dev/disk/by-id/REPLACE_ME_OS
data=/dev/disk/by-id/REPLACE_ME_DATA

case "$os$data" in *REPLACE_ME*)
  echo "replace the placeholders first"; exit 1 ;;
esac
[ "$(readlink -f "$os")" != "$(readlink -f "$data")" ] \
  || { echo "the OS disk and the data disk are the same device"; exit 1; }
[ "$(lsblk -dno TYPE "$os")" = disk ] \
  || { echo "not a whole disk: $os"; exit 1; }
[ "$(lsblk -dno TYPE "$data")" = disk ] \
  || { echo "not a whole disk: $data"; exit 1; }
lsblk -o NAME,SIZE,MODEL,SERIAL "$os" "$data"
```

**Expect:** the last command prints two `disk` rows. The model and serial of
each must match the disk you fitted for that role in step 1.2.

**If it fails:** a `not a whole disk` message means the path names a partition,
not the disk. Go back to `lsblk` and copy the parent. If the model and serial do
not match, stop and fix the path before step 4.4.

Keep this shell open. Steps 4.4 and 4.5 read `$os` and `$data` from it.

### 4.4 Prepare the data disk (first install only)

This is the destructive step. It creates one GPT partition labelled `data` and
an ext4 filesystem labelled `data`, which is what `var-srv.mount` looks up. It
uses the same `systemd-repart` definition the VM harness uses in
`vm/guest-data.sh`, so the two paths cannot drift apart.

**First install only.** Skip this step when reinstalling the OS on a box whose
data disk already holds `/srv`. Ignition mounts that disk by its existing label
and leaves it alone. This step builds the filesystem; it never repairs one.

The harness runs the same definition with `--empty=allow`, because its data disk
is blank. This step adds `--empty=force`, because a first install must also
replace a stale partition table. `force` erases the whole device. That is
deliberate, and it is why step 4.3 refuses a placeholder and a wrong disk first.

```sh
sudo mkdir -p /etc/repart.d
sudo tee /etc/repart.d/10-data.conf >/dev/null <<'EOF'
[Partition]
Type=linux-generic
Label=data
Format=ext4
EOF

# Preview. This changes nothing.
sudo systemd-repart --definitions=/etc/repart.d "$data"

# Apply. --empty=force writes a fresh table and erases the device.
sudo systemd-repart --dry-run=no --empty=force --definitions=/etc/repart.d "$data"
```

Then confirm the label the mount unit will use:

```sh
sudo blkid -t LABEL=data -s TYPE -o value
sudo lsblk -f "$data"
```

**Expect:** the preview lists one partition to create, with `Label: data` and
`Format: ext4`, and no existing partition to keep. After the apply, `blkid`
prints `ext4`, and `lsblk -f` shows exactly one child partition with
`FSTYPE ext4`, `LABEL data`, and no mount point. That child is what
`/dev/disk/by-label/data` resolves to on first boot.

**If it fails:** `systemd-repart` names the reason. A busy or mounted device
means something else is using the disk. An empty `blkid` means no partition was
created; do not continue to step 4.5, because Ignition would find no `data`
label and `/srv` would land on the OS disk.

### 4.5 Install and reboot

```sh
sudo coreos-installer install "$os" --ignition-file /tmp/ucore.ign
```

**Expect:** the command ends with `Install complete.` and exits 0. Nothing in
the output names the data disk; the install targets `$os` only.

**If it fails:** the error names the reason. A target that is not a block device
means `$os` is wrong; go back to step 4.3. A full disk means the media is too
small for the image.

Then reboot and remove the USB stick as the machine restarts, so it boots the
installed disk rather than the stick again:

```sh
sudo reboot
```

**Expect:** the box reboots into Fedora CoreOS and applies Ignition on this
first boot. The data disk is mounted at `/var/srv`, and `/srv` reaches it through
the symlink.

**If it fails:** if the box boots the stick again, remove it and power-cycle. If
it drops to an emergency shell, the Ignition file was rejected; read
`journalctl -b` for the parse error.

## 5. Let ucore rebase

The first boot is Fedora CoreOS with Ignition applied. One one-shot unit then
rebases the machine to ucore:

1. `ucore-autorebase.service` rebases to `ghcr.io/ublue-os/ucore-minimal:stable`,
   writes its marker, disables itself, and reboots.

Keep the network connected. This takes a few minutes and two boots total.

Confirm the result:

```sh
rpm-ostree status
```

**Expect:** the booted deployment, marked `*`, names
`ghcr.io/ublue-os/ucore-minimal:stable`.

**If it fails:** if the booted deployment still names `fedora-coreos`, the
rebase did not finish or the network was down. Read
`sudo journalctl -u ucore-autorebase.service --no-pager` and rerun
`sudo systemctl restart ucore-autorebase.service`.

## 6. Confirm the tailnet

A keyed build joins on its first ucore boot. The join unit is skipped on the
Fedora CoreOS boot because no tailscale binary is installed yet.

A keyless build stays off the tailnet until you join from the console. The
console autologins as `core` on tty1, and `core` has passwordless sudo. Mint the
key in the Tailscale admin console with the `tag:devbox` tag, then run the same
join the unit would have run:

```sh
sudo tailscale up --auth-key tskey-auth-... --hostname devbox --accept-routes=false
sudo systemctl restart oc-tailnet.service
```

Use the hostname from `OC_HOSTNAME`; the default is `devbox`. A bare
`tailscale up` registers the node untagged under your user identity, and the ACL
below requires `tag:devbox`.

Now confirm the node and the three published surfaces:

```sh
tailscale status
tailscale ip -4
tailscale serve status
```

**Expect:** `ip -4` prints one `100.x.y.z` address. `status` lists `devbox`
against that address and does not say `offline`. `serve status` names
`https://devbox.<tailnet>.ts.net` and proxies to `http://127.0.0.1:4096`, plus
the `8443` dashboard and `10000` gateway mounts.

**If it fails:** check `sudo journalctl -u oc-tailnet.service -u tailscaled`.
The most common cause is a key that was already used, expired, or scoped to a
tag the ACL does not allow. A keyless build that has not joined shows
`oc-tailnet` failed; that is expected until you run the join above.

From another machine on the tailnet:

```sh
tailscale ping devbox
ssh core@devbox
```

**Expect:** `pong` from `tailscale ping`, then a `core@devbox` shell prompt.

**If it fails:** `sshd` is masked, because it is a second listener on the wired
LAN and this box has one door. Tailscale SSH serves the shell from inside
`tailscaled`, and it needs an ACL rule before it answers. Add this in the
Tailscale admin console:

```json
{
  "action": "accept",
  "src": ["autogroup:member"],
  "dst": ["tag:devbox"],
  "users": ["autogroup:member"]
}
```

Without that rule, `ssh core@devbox` refuses the connection even though the node
is up. The console and Intel AMT are the recovery path if the tailnet is down.

Once the node appears in the admin console, **revoke the auth key**. Revoking
the key does not remove the node; the node identity lives in `/var/lib/tailscale`.

## 7. Provision the runtime secrets

The OpenCode password, the Hermes gateway key, a model provider key and the
restic credentials are not on the install media. Create
`/etc/devbox/secrets.env` on the box, mode 0600, owned by root.

Generate a password and store it in your password manager:

```sh
openssl rand -hex 24
```

**Expect:** 48 hex characters. Save it before you clear the screen; nothing
stores it for you.

**If it fails:** generate another. Never reuse a password from another service.

Create the file locally with the values:

```sh
cat > secrets.env <<'EOF'
OPENCODE_PASSWORD=replace-with-the-generated-value
# The Hermes control plane's own gateway key. Generate one with `openssl rand -hex 32`.
API_SERVER_KEY=replace-with-the-gateway-key
# One model provider key, whichever vendor you use.
OPENROUTER_API_KEY=replace-with-the-provider-key
# Optional Hermes dashboard auth and chat channel.
HERMES_DASHBOARD_BASIC_AUTH_USERNAME=admin
HERMES_DASHBOARD_BASIC_AUTH_PASSWORD=replace-with-a-dashboard-password
RESTIC_REPOSITORY=s3:https://s3.example.invalid/devbox-restic
RESTIC_PASSWORD=replace-with-the-restic-password
EOF
chmod 600 secrets.env
```

Send the file over the SSH session and install it with tight permissions. This
uses SSH stdin, so it does not depend on `scp` being available under Tailscale
SSH:

```sh
ssh core@devbox 'sudo install -d -m 0700 /etc/devbox && \
  umask 077 && sudo tee /etc/devbox/secrets.env >/dev/null && \
  sudo chmod 0600 /etc/devbox/secrets.env' < secrets.env
```

Confirm the file landed with the right mode and owner:

```sh
ssh core@devbox 'sudo stat -c "%a %U:%G %n" /etc/devbox/secrets.env'
```

**Expect:** `600 root:root /etc/devbox/secrets.env` and no other output.

**If it fails:** a different mode means the `chmod` did not run; fix it before
starting the units. A missing file means the SSH session failed; reconnect and
resend.

Delete the local `secrets.env` after the install. Do not commit it.

Then start the environment writers and the containers:

```sh
ssh core@devbox 'sudo systemctl restart oc-env.service hermes-env.service opencode.service hermes.service'
```

Check that both containers are healthy:

```sh
ssh core@devbox 'sudo systemctl is-active oc-env hermes-env opencode hermes'
ssh core@devbox 'sudo podman ps --format "{{.Names}} {{.Status}}"'
```

**Expect:** four `active` lines, then `opencode` and `hermes` each reading
`(healthy)`.

**If it fails:** `oc-env` writes `/etc/opencode/env` and `hermes-env` writes
`/etc/hermes/env`. Each quadlet loads its own file, so a failed writer stops its
container. That is the fail-closed path, not a bug. Read
`sudo journalctl -u <unit>` for the missing key.

If the restic repository is new, initialize it once. `oc-restic` runs restic in
the project's Fedora image with only the restic credentials:

```sh
ssh core@devbox 'sudo oc-restic init'
```

Then run the backup and confirm a snapshot exists:

```sh
ssh core@devbox 'sudo systemctl start oc-backup.service'
ssh core@devbox 'sudo journalctl -u oc-backup.service -n 30 --no-pager'
```

**Expect:** `created restic repository` on the first run, then a journal line
ending `snapshot ... saved`.

**If it fails:** the journal names the repository or credential error. `oc-backup`
passes only `RESTIC_*`, `AWS_*` and `B2_*` variables to the container, so an
S3-compatible store or Backblaze B2 works without editing the script. An SFTP
repository would need an SSH key mounted into the container, which this script
does not do.

## 8. Connect a client

```sh
opencode pair --url https://devbox.<tailnet>.ts.net   # desktop app
opencode --server https://devbox.<tailnet>.ts.net     # TUI
```

**Expect:** the desktop app opens a pairing link, and the TUI asks for
`OPENCODE_PASSWORD`.

**If it fails:** the pairing link is single-use and expires in five minutes.
Mint a new one. `docs/web-access.md` is the full client path: the browser
sign-in, the tailnet-only invariant, the verification checklist, and the
teardown.

`oc-tailnet` publishes loopback 4096 on HTTPS 443 with a real certificate. The
TUI uses `OPENCODE_PASSWORD` from the same password manager entry.

## 9. Finish the checkout

Run every row. A row that fails is a stop.

| Check | Command | Passes when | If it fails |
|---|---|---|---|
| OS is ucore | `ssh core@devbox 'rpm-ostree status --booted'` | the booted deployment names `ucore-minimal` | see step 5 |
| `/srv` is the data disk | `ssh core@devbox 'findmnt -no SOURCE /srv'` | the source is the data partition, not the OS disk | the mount failed; check `systemctl status var-srv.mount` |
| Tailscale enabled | `ssh core@devbox 'systemctl is-enabled tailscaled'` | prints `enabled` | `systemctl enable --now tailscaled` |
| Backup timer | `ssh core@devbox 'systemctl list-timers oc-backup.timer --no-pager'` | one timer with a next run | `systemctl status oc-backup.timer` |
| Sleep blocked | `ssh core@devbox 'systemctl show -p UnitFileState suspend.target hibernate.target'` | prints `UnitFileState=masked` twice | `systemctl mask suspend.target hibernate.target` |
| Idle policy | `ssh core@devbox 'systemctl show -p IdleAction'` | prints `IdleAction=ignore` | reinstall the Ignition; do not edit the unit by hand |
| Cooling | `ssh core@devbox 'sensors'` | a stable idle temperature, fan spins under load | clean the dust and reseat the heatsink |
| UPS | pull AC for one minute, then `ssh core@devbox 'uptime'` | uptime keeps climbing | replace the UPS battery or the adapter |
| Backup restores | the drill in `docs/runbook.md` | a snapshot restores to a scratch device | do not trust the backup until it does |

Then leave the box idle for an hour and confirm `tailscale ping devbox` still
answers.

Record both digests. The ucore line comes from the booted deployment. The
container line must match `image/prod-digest.txt`.

```sh
ssh core@devbox 'rpm-ostree status --booted'
ssh core@devbox 'sudo podman inspect --format "{{.Image}}" opencode | xargs sudo podman image inspect --format "{{.RepoDigests}}"'
```

**Expect:** every row passes, the idle hour does not drop the tailnet, and the
container digest equals the one in `image/prod-digest.txt`.

**If it fails:** stop at the row that failed. The table names the unit or the
command to inspect. Nothing after a failed row is trustworthy. A container
digest that differs from the pin means the box is running something the repo did
not ship; do not record it as the installed digest.

## What this procedure does not prove

The VM rehearsal proves the Ignition, the rebase, the mount and the container
start path. It cannot prove the Mini's firmware, the two physical disk ids, the
tailnet join, `tailscale serve` TLS, the UPS, or the thermals. Those are the
steps above, and none of them has run on the Mini yet. `docs/runbook.md` covers
the day after, including the restore drill, the rollback paths and the disk
replacements.
