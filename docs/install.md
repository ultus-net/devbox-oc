# Install the devbox on the HP EliteDesk Mini

This is the first install path. It assumes physical access, a wired network, and
two disks. Read `docs/design.md` first; the decisions there explain why the steps
are in this order.

The short version: rehearse the install in a VM, boot Fedora CoreOS installation
media, install to the OS disk with an Ignition file that joins the tailnet or
leaves the join for the console, let ucore rebase once, then provision the
runtime secrets over Tailscale.

## 0. Rehearse in a VM

Run the install in QEMU on the preparation machine first. It uses the same
`os/butane/ucore.bu` this install ships, so a config fault surfaces with no disk
at risk and no trip to the server room.

```sh
./vm/run-vm.sh --rebuild
```

It takes 10 to 20 minutes. It must end with `VM DOGFOOD: pass`. Then power it down:

```sh
./vm/run-vm.sh --stop
```

Skip this only when an earlier run already passed on the current Ignition. Rerun
it after every change to `os/butane/`, `host/`, `image/` or a quadlet. The full
procedure and the list of what it cannot prove are in `docs/vm.md`.

## 1. Prepare the hardware

1. Update the firmware from the vendor before installing. HP firmware updates are
   easier before Linux is on the disk.
2. In firmware setup:
   - Set **Power On After Power Failure** to **On**. The exact label varies by
     model; look for "AC Power Recovery" or "After Power Loss".
   - Disable **Wake on LAN** unless you plan to use it. The box is always on.
   - Enable **Intel vPro/AMT** if the SKU has it and the wired server-room
     network allows it. This is the out-of-band console when the tailnet is down.
   - Note the Secure Boot state. The ucore install path needs Secure Boot off
     until the ucore signing key is enrolled. The enrollment guide is at
     `https://projectucore.org/docs/secure-boot/`. Enroll it after the install if
     the server-room policy requires Secure Boot.
3. Fit the two disks. The OS goes on an M.2 NVMe SSD. The data disk is the second
   M.2 NVMe on the 800 G4, or a 2.5 inch SATA SSD in a caddy on either model.
   Confirm the caddy and the screws came with the chassis before relying on the
   SATA bay.
4. Connect wired Ethernet, the 65W adapter, and the UPS. The Mini has no internal
   power source, so the UPS is the only thing between a power cut and an unclean
   shutdown.
5. Identify the two disks. Do not guess.

```sh
lsblk -o NAME,SIZE,MODEL,SERIAL
ls -l /dev/disk/by-id/
```

Pick the smaller or older SSD for the OS and the larger one for data. Record the
full `/dev/disk/by-id/...` path of the data disk. A bare `/dev/nvme1n1` can move
between boots, and one wrong device name is unrecoverable.

The data disk is prepared once, by hand, from the live media. Ignition only mounts
it by label, so reinstalling the OS cannot wipe it.

## 2. Build the Ignition file

Run this on a preparation machine with this repository checked out and Butane
0.29.0 available. The build refuses placeholder values, so a forgotten edit fails
before the USB is written.

```sh
export SSH_PUBKEY="$(cat ~/.ssh/id_ed25519.pub)"
read -rsp 'Tailscale auth key (empty for keyless): ' TS_AUTHKEY; export TS_AUTHKEY
export OC_HOSTNAME=devbox
export IMAGE=ghcr.io/ultus-net/devbox:prod

BUTANE=/path/to/butane ./os/butane/build.sh
```

`IMAGE` must name the package the workflow publishes (it derives the owner from
`github.repository_owner`). GHCR packages are private by default, and the host
pulls anonymously, so set the package visibility to public before installing.
If it must stay private, add a read-only token and a `podman login ghcr.io` step;
the container cannot start after an OS reinstall otherwise.

`TS_AUTHKEY` is optional. With a key, the host joins the tailnet on its first
ucore boot. The key is created in the Tailscale admin console with the
`tag:devbox` tag, single-use or short-lived, and written to
`/etc/devbox/tailscale-authkey` on the host. After a successful join the host
deletes that file, so a revoked key cannot break later boots. Revoke the key in
the console as well. In a keyed build this is the only secret on the install
media.

A keyless build ships no key. Leave `TS_AUTHKEY` unset and the build prints
`KEYLESS build`; the host stays off the tailnet until you join from the console
in step 6. The console autologins as `core` on tty1, because `sshd` is masked and
there is no LAN listener.

`OC_HOSTNAME` is the MagicDNS name. Keep it stable, because the client's saved
server URL contains it. The default is `devbox`.

The build writes `os/butane/ucore.ign`. It is a compiled artifact. Never edit it
by hand; edit `os/butane/ucore.bu` and rebuild.

## 3. Write Fedora CoreOS installation media

Download the Fedora CoreOS stable live ISO for x86_64 from
`https://fedoraproject.org/coreos/download/?stream=stable#baremetal`. Verify its
checksum from the same page. Write it to a USB stick with Fedora Media Writer,
balenaEtcher, or the writer you normally use. Confirm the USB device with
`lsblk` before writing; every one of those tools destroys the target.

## 4. Install

1. Boot the Mini from the USB stick.
2. At the live prompt, copy `os/butane/ucore.ign` onto the live system. A second
   USB stick is the easiest route.
3. Confirm the target OS disk one more time with `lsblk`.
4. **First install only.** Prepare the data disk. Booted from the live media,
   create one GPT partition labelled `data` on the by-id path, then format it
   ext4 with the label `data`. This destroys everything on the device, so read
   the by-id path twice. Skip this step when reinstalling the OS on a box whose
   data disk already holds `/srv`; the runbook says the same. Confirm the result
   before continuing:

```sh
lsblk -f /dev/disk/by-id/REPLACE_ME
```

The output must show one partition with `LABEL="data"` and `FSTYPE="ext4"`.
Replace `REPLACE_ME` with the recorded id. The prefix is `ata-` for a 2.5 inch
SATA disk and `nvme-` for an M.2 device.

5. Install:

```sh
sudo coreos-installer install /dev/nvme0n1 \
  --ignition-file ucore.ign
sudo reboot
```

Replace `/dev/nvme0n1` with the OS disk. The data disk is not named here. Ignition
mounts it by its `data` label on first boot, and leaves the filesystem alone.

On Fedora CoreOS `/srv` is a symlink to `var/srv`, and systemd refuses to mount
on a path that contains a symlink. The mount unit is `var-srv.mount` and it
mounts at `/var/srv`. `/srv` reaches it through the symlink, so every path in
this repo stays `/srv/...`.

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

The booted deployment must name `ghcr.io/ublue-os/ucore-minimal`. If it names
`fedora-coreos`, the rebase did not finish; check:

```sh
sudo journalctl -u ucore-autorebase.service --no-pager
```

## 6. Confirm the tailnet

With `TS_AUTHKEY` set, the box joins on its first ucore boot. The join unit is
skipped on the Fedora CoreOS boot because no tailscale binary is installed yet.

A keyless build stays off the tailnet until you join from the console. The
console autologins as `core` on tty1, and `core` has passwordless sudo. Run the
same join the unit would have run, then restart the unit so it publishes `serve`
and enables Tailscale SSH:

```sh
sudo tailscale up --auth-key tskey-auth-... --hostname devbox --accept-routes=false
sudo systemctl restart oc-tailnet.service
tailscale status
tailscale ip -4
```

Mint the key in the Tailscale admin console with the `tag:devbox` tag. Use the
hostname from `OC_HOSTNAME`; the default is `devbox`. A bare `tailscale up`
registers the node untagged under your user identity, and the ACL below requires
`tag:devbox`.

From another machine on the tailnet:

```sh
tailscale ping devbox
ssh core@devbox
```

`sshd` is masked, because it is a second listener on the wired LAN and this box
has one door. Tailscale SSH serves the shell from inside `tailscaled`. It needs an
ACL rule before it answers. In the Tailscale admin console, add:

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

If the join failed, check `sudo journalctl -u oc-tailnet.service -u tailscaled`.
The most common cause is a key that was already used, expired, or scoped to a tag
the ACL does not allow.

Once the node appears in the admin console, **revoke the auth key**. Revoking the
key does not remove the node; the node identity lives in `/var/lib/tailscale`.

## 7. Provision the runtime secrets

The OpenCode password, the Hermes gateway key, a model provider key and the
restic credentials are not on the install media. Create
`/etc/devbox/secrets.env` on the box, mode 0600, owned by root.

Generate a password and store it in your password manager:

```sh
openssl rand -hex 24
```

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

Delete the local `secrets.env` after the install. Do not commit it.

Then start the environment writers and the containers:

```sh
ssh core@devbox 'sudo systemctl restart oc-env.service hermes-env.service opencode.service hermes.service'
```

Check that both containers are healthy:

```sh
ssh core@devbox 'sudo podman ps --format "{{.Names}} {{.Status}}"'
ssh core@devbox 'sudo systemctl is-active oc-env hermes-env opencode hermes'
```

`oc-env` writes `/etc/opencode/env` and `hermes-env` writes `/etc/hermes/env`.
Each quadlet loads its own file. If either writer fails, its container will not
start. That is the fail-closed path, not a bug.

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

`oc-backup` passes only `RESTIC_*`, `AWS_*` and `B2_*` variables to the container,
so an S3-compatible store or Backblaze B2 works without editing the script. The
OpenCode password stays on the host. An SFTP repository would need an SSH key
mounted into the container, which this script does not do; use an S3-compatible
endpoint or add the mount deliberately.

## 8. Connect a client

```sh
opencode pair --url https://devbox.<tailnet>.ts.net   # desktop app
opencode --server https://devbox.<tailnet>.ts.net     # TUI
```

`oc-tailnet` publishes loopback 4096 on HTTPS 443 with a real certificate. The
pairing link is single-use and expires in five minutes. The TUI uses
`OPENCODE_PASSWORD` from the same password manager entry.

`docs/web-access.md` is the full client path: the browser sign-in, the
tailnet-only invariant, the verification checklist, and the teardown. Read it
before opening the browser.

## 9. Finish the checkout

- Confirm `rpm-ostree status` names ucore-minimal.
- Confirm `systemctl is-enabled tailscaled` says `enabled`.
- Confirm `systemctl list-timers oc-backup.timer` shows the next run.
- Confirm `systemctl is-enabled suspend.target` says `masked`.
- Confirm `systemctl show -p IdleAction` says `IdleAction=ignore`.
- Confirm the box stays up while idle: leave it idle for an hour and check that
  `tailscale ping devbox` still answers.
- Confirm the cooling: `sensors` reports a stable idle temperature and the fan
  spins up under load.
- Confirm the UPS: pull AC power for a minute and check that `uptime` keeps
  climbing, then restore AC power.
- Run the restore drill in `docs/runbook.md` before trusting the backup.
- Record the installed ucore digest and the container digest in the change that
  lands the install.
