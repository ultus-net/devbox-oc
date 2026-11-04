# Install the devbox on the HP laptop

This is the first install path. It assumes physical access, a wired network, and
two disks. Read `docs/design.md` first; the decisions there explain why the steps
are in this order.

The short version: boot Fedora CoreOS installation media, install to the OS disk
with an Ignition file that also joins the tailnet, let ucore rebase twice, then
provision the runtime secrets over Tailscale.

## 1. Prepare the hardware

1. Update the firmware from the vendor before installing. HP firmware updates are
   easier before Linux is on the disk.
2. In firmware setup:
   - Set **Power On After Power Failure** to **On**. The exact label varies by
     model; look for "AC Power Recovery" or "After Power Loss".
   - Disable **Wake on LAN** unless you plan to use it. The box is always on.
   - Set the **lid close** action to **Do nothing** if the firmware has one.
     Linux masks suspend as well, so this is belt and braces.
   - Enable **Intel AMT/vPro** if the model supports it and the server-room
     network allows it. This is the out-of-band console when the tailnet is down.
   - Note the Secure Boot state. The ucore install path needs Secure Boot off
     until the ucore signing key is enrolled. The enrollment guide is at
     `https://projectucore.org/docs/secure-boot/`. Enroll it after the install if
     the server-room policy requires Secure Boot.
3. Connect wired Ethernet and AC power.
4. Identify the two disks. Do not guess.

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
export OS_DISK=/dev/nvme0n1
export TS_AUTHKEY=tskey-auth-REPLACE_ME
export OC_HOSTNAME=devbox
export IMAGE=ghcr.io/ultus-net/devbox:prod

BUTANE=/path/to/butane ./os/butane/build.sh
```

`TS_AUTHKEY` is a Tailscale auth key. Create it in the Tailscale admin console
with the `tag:devbox` tag. Use a single-use or short-lived key. It is written to
`/etc/devbox/tailscale-authkey` on the host and revoked after the node joins.
This is the only secret on the install media.

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

1. Boot the laptop from the USB stick.
2. At the live prompt, copy `os/butane/ucore.ign` onto the live system. A second
   USB stick is the easiest route.
3. Confirm the target OS disk one more time with `lsblk`.
4. Prepare the data disk. Booted from the live media, create one GPT partition
   labelled `data` on the by-id path, then format it ext4 with the label `data`.
   This destroys everything on the device, so read the by-id path twice. Confirm
   the result before continuing:

```sh
lsblk -f /dev/disk/by-id/ata-REPLACE_ME
```

The output must show one partition with `LABEL="data"` and `FSTYPE="ext4"`.

5. Install:

```sh
sudo coreos-installer install /dev/nvme0n1 \
  --ignition-file ucore.ign
sudo reboot
```

Replace `/dev/nvme0n1` with the OS disk. The data disk is not named here. Ignition
mounts it by its `data` label on first boot, and leaves the filesystem alone.

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

The box joins the tailnet on first boot with the key from Ignition.

```sh
tailscale status
tailscale ip -4
```

From another machine on the tailnet:

```sh
tailscale ping devbox
ssh core@devbox
```

If the join failed, check `sudo journalctl -u oc-tailnet.service -u tailscaled`.
The most common cause is a key that was already used, expired, or scoped to a tag
the ACL does not allow.

Once the node appears in the admin console, **revoke the auth key**. Revoking the
key does not remove the node; the node identity lives in `/var/lib/tailscale`.

## 7. Provision the runtime secrets

The OpenCode password and the restic credentials are not on the install media.
Create `/etc/devbox/secrets.env` on the box, mode 0600, owned by root.

Generate a password and store it in your password manager:

```sh
openssl rand -hex 24
```

Create the file locally with the values:

```sh
cat > secrets.env <<'EOF'
OPENCODE_PASSWORD=replace-with-the-generated-value
RESTIC_REPOSITORY=s3:https://s3.example.invalid/devbox-restic
RESTIC_PASSWORD=replace-with-the-restic-password
# Add the provider credential variables for your store in the same file.
EOF
chmod 600 secrets.env
```

Copy it to the box and install it with tight permissions:

```sh
scp secrets.env core@devbox:/tmp/secrets.env
ssh core@devbox 'sudo install -d -m 0700 /etc/devbox && \
  sudo install -m 0600 -o root -g root /tmp/secrets.env /etc/devbox/secrets.env'
```

Delete the temporary copy in `/tmp` on the box and the local `secrets.env` after
the install. Do not commit either one.

Then start the environment writer and the container:

```sh
ssh core@devbox 'sudo systemctl restart oc-env.service opencode.service'
```

Check that the container is healthy:

```sh
ssh core@devbox 'sudo podman ps --format "{{.Names}} {{.Status}}"'
ssh core@devbox 'sudo systemctl is-active oc-env opencode'
```

`oc-env` writes `/etc/opencode/env`. The quadlet loads it. If `oc-env` fails, the
container will not start. That is the fail-closed path, not a bug.

If the restic repository is new, initialize it once:

```sh
ssh core@devbox 'sudo podman run --rm --env-file /etc/devbox/secrets.env \
  docker.io/restic/restic@sha256:4cf4a61ef9786f4de53e9de8c8f5c040f33830eb0a10bf3d614410ee2fcb6120 init'
```

Then run the backup and confirm a snapshot exists:

```sh
ssh core@devbox 'sudo systemctl start oc-backup.service'
ssh core@devbox 'sudo journalctl -u oc-backup.service -n 30 --no-pager'
```

The restic container reads every credential in `/etc/devbox/secrets.env`, so an
S3-compatible store or Backblaze B2 works without editing the script: set the
provider variables (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, or the B2
equivalents) alongside `RESTIC_REPOSITORY` and `RESTIC_PASSWORD`. An SFTP
repository would need an SSH key mounted into the container, which this script
does not do; use an S3-compatible endpoint or add the mount deliberately.

## 8. Connect a client

```sh
opencode pair --url https://devbox.<tailnet>.ts.net   # desktop app
opencode --server https://devbox.<tailnet>.ts.net     # TUI
```

`oc-tailnet` publishes loopback 4096 on HTTPS 443 with a real certificate. The
pairing link is single-use and expires in five minutes. The TUI uses
`OPENCODE_PASSWORD` from the same password manager entry.

## 9. Finish the checkout

- Confirm `rpm-ostree status` names ucore-minimal.
- Confirm `systemctl is-enabled tailscaled` says `enabled`.
- Confirm `systemctl list-timers oc-backup.timer` shows the next run.
- Confirm `sudo systemctl status oc-nosleep.service` is active.
- Confirm the lid closes without suspending: close it for a minute and check that
  `tailscale ping devbox` still answers.
- Run the restore drill in `docs/runbook.md` before trusting the backup.
- Record the installed ucore digest and the container digest in the change that
  lands the install.
