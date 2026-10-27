# Devbox reachability plan: three defects that stop a deploy working

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans.

**Goal:** Fix three verified defects that make a deployed box unreachable, before any Batch B step is attempted.

**Spec:** `docs/superpowers/specs/2026-10-27-devbox-opencode-design.md`
**Prior plans:** `docs/superpowers/plans/2026-10-27-devbox-implementation.md` (tasks 1 to 12),
`docs/superpowers/plans/2026-10-27-devbox-followon.md` (Batch A done, Batch B operator-only)

## Why this plan exists

Batch B is blocked on the operator's Azure subscription. That block hid a worse
problem: three defects would make the first deploy fail even if every operator
step were completed correctly. Each is a missing link between two components
that were built and tested in isolation.

| # | Defect | Consequence | Severity |
|---|---|---|---|
| 1 | `tailscaled` is never enabled, and nothing orders it before `oc-tailnet.service` | `tailscale up` fails at boot, so the box is unreachable over the tailnet. Only a Bastion session recovers it. | P1 |
| 2 | `var.tailscale_authkey` is declared and documented, but no resource ever writes it to Key Vault | `oc-tailnet-up` reads a secret that does not exist, so defect 1's failure becomes permanent rather than transient | P1 |
| 3 | `os/build-os-image.sh` publishes Fedora's plain CoreOS VHD, not ucore | The VM boots plain FCOS. Every ucore assumption breaks: podman is `docker`, `tailscaled` is absent, `rpm-ostreed-automatic.timer` is not enabled, and the `bootc` model the design depends on is not what runs | P1 |

Batches D and E below close those. Batch F records what the operator must run,
unchanged from the follow-on plan.

## Verified facts

Checked against upstream sources in this session, so a reviewer can re-check them.

| Fact | Value | Source |
|---|---|---|
| `tailscale` is installed in ucore-minimal | `dnf -y --enable-repo=tailscale-stable install tailscale` | `ublue-os/ucore` `ucore/install-ucore-minimal.sh` |
| The tailscale repo is vendored disabled | `enabled=0` in `ucore/system_files/minimal/etc/yum.repos.d/tailscale.repo` | same repo |
| The RPM ships the unit but enables nothing | `/lib/systemd/system/tailscaled.service` is in the file list, no preset entry | `pkgs.tailscale.com/stable/fedora/x86_64` repodata filelists |
| `tailscaled.service` is `Type=notify` | so `After=tailscaled.service` waits for readiness, not just for start | `tailscale/tailscale` `cmd/tailscaled/tailscaled.service` |
| ucore enables added services only on request | "most added services are installed but not enabled automatically" | `projectucore.org/docs/services/` |
| `jq` is in the Fedora CoreOS base | `jq 1.8.1-3.fc44.x86_64` in the lockfile | `coreos/fedora-coreos-config` `manifest-lock.x86_64.json` |
| ucore is a bootc image | `containers.bootc: 1` label | design doc verified-facts table |
| `image-builder` can emit a VHD from a bootc image | `vhd` is a listed disk image type, `filename: disk.vhd` | `osbuild/image-builder` `data/distrodefs/bootc-generic/imagetypes.yaml` |
| The legacy `bootc-image-builder` container is a compatibility shim | new work should use `image-builder` | `osbuild/image-builder` `bootc-image-builder/README.md` |
| `az image create` accepts a Hyper-V generation | `--hyper-v-generation` is a documented argument | Azure CLI `vm/_params.py`, image create |

## Batches

| Batch | Tasks | Needs |
|---|---|---|
| D | D1 enable tailscaled, D2 write the auth key, D3 build the OS from ucore, D4 one env file, D5 docs | nothing external |
| E | E1 apply and first-boot verification | Azure subscription, container engine |
| F | F1 vendoring | a target Azure DevOps repo |

---

## Batch D

### Task 1: D1 Start `tailscaled` and order the tailnet join after it

**Files:** `os/butane/ucore.bu` (modify), `os/butane/tests/test_tailscale_enabled.sh` (create), `tests/verify.sh` (modify)

**Interfaces:** produces an Ignition unit set where `tailscaled.service` is enabled and `oc-tailnet.service` is ordered after it.

Step 1 writes a guard that fails today. The failure has to be a missing
`tailscaled` unit block, not a missing file, because the file exists.

- [ ] **Step 1: Write the failing test**

```bash
#!/usr/bin/env bash
# os/butane/tests/test_tailscale_enabled.sh
#
# ucore ships the tailscale RPM and vendors its repo disabled, but enables no
# service. Its services doc says added services are enabled deliberately. Without
# this block, tailscale up fails at boot and the box is unreachable except by
# Bastion.
#
# Source-level, not .ign-level: the .ign needs a container engine to compile, and
# a guard that skips on a machine without one protects nothing.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
bu="${1:-$here/../ucore.bu}"
fail() { echo "FAIL: $1" >&2; exit 1; }

[ -f "$bu" ] || fail "no such file: $bu"

# tailscaled is a shipped unit, not one we write. Enabling it needs a unit
# entry with no contents block, or the contents would shadow the real unit.
#
# The block is taken by line number, not an awk range: the range end pattern
# `^    - name: ` matches the start line itself, so a range collapses to one line
# and the enabled check reads it as absent.
start="$(grep -n -- '- name: tailscaled.service' "$bu" | head -1 | cut -d: -f1 || true)"
[ -n "$start" ] || fail "tailscaled.service is not enabled in the Ignition config"
block="$(tail -n "+$start" "$bu" | awk 'NR > 1 && /^    - name: /{exit} {print}')"
[ -n "$block" ] || fail "tailscaled.service block is empty"
printf '%s\n' "$block" | grep -Eq '^[[:space:]]+enabled: true[[:space:]]*$' \
  || fail "tailscaled.service is present but not enabled"
if printf '%s\n' "$block" | grep -q 'contents:'; then
  fail "tailscaled.service has a contents block, which would shadow the shipped unit"
fi

# Ordering, not just presence. tailscale up contacts the coordination server, so
# it needs a socket that is already listening.
nstart="$(grep -n -- '- name: oc-tailnet.service' "$bu" | head -1 | cut -d: -f1 || true)"
[ -n "$nstart" ] || fail "oc-tailnet.service not found in $bu"
net="$(tail -n "+$nstart" "$bu" | awk 'NR > 1 && /^    - name: /{exit} {print}')"
printf '%s\n' "$net" | grep -Eq 'After=.*tailscaled\.service' \
  || fail "oc-tailnet.service does not start after tailscaled.service"
printf '%s\n' "$net" | grep -Eq 'Requires=.*tailscaled\.service|Wants=.*tailscaled\.service' \
  || fail "oc-tailnet.service does not want or require tailscaled.service"

echo "tailscaled is enabled and orders the tailnet join"
```

- [ ] **Step 2: Run it to verify it fails**

Run: `chmod +x os/butane/tests/test_tailscale_enabled.sh && ./os/butane/tests/test_tailscale_enabled.sh`
Expected: `FAIL: tailscaled.service is not enabled in the Ignition config`

- [ ] **Step 3: Add the unit and the ordering**

In `os/butane/ucore.bu`, insert before the `oc-tailnet.service` entry:

```yaml
    # ucore installs the tailscale RPM but enables no service, and its repo is
    # vendored disabled. Without this the join below has no daemon to talk to,
    # and the box has no reachable path on first boot.
    #
    # No contents: this enables the shipped unit. A contents block here would
    # shadow /lib/systemd/system/tailscaled.service.
    - name: tailscaled.service
      enabled: true
```

Then change the existing unit's dependency lines to:

```yaml
        After=network-online.target oc-secrets.service tailscaled.service
        Wants=network-online.target tailscaled.service
```

- [ ] **Step 4: Run the test again**

Run: `./os/butane/tests/test_tailscale_enabled.sh`
Expected: `tailscaled is enabled and orders the tailnet join`

- [ ] **Step 5: Add the suite to the gate**

In `tests/verify.sh`, after the `ignition units` line:

```bash
run "tailscale enabled"   ./os/butane/tests/test_tailscale_enabled.sh
```

- [ ] **Step 6: Regenerate the committed Ignition and confirm the unit landed**

```bash
./os/butane/build-placeholder.sh
jq -e '.systemd.units[] | select(.name == "tailscaled.service") | .enabled' os/butane/ucore.ign
```

Expected: `true`. If `BUTANE` is unset and no podman is present, skip this step
and note it; the source test is the gate, and the `.ign` is regenerated by the
operator in runbook stage 3.

- [ ] **Step 7: Commit**

```bash
git add os/butane/ucore.bu os/butane/ucore.ign os/butane/tests/test_tailscale_enabled.sh tests/verify.sh
git commit -m "fix(os): enable tailscaled and order the tailnet join after it"
```

---

### Task 2: D2 Make the auth key reach the host, not just Key Vault

**Files:** `terraform/main.tf` (modify), `terraform/outputs.tf` (modify), `os/butane/ucore.bu` (modify), `terraform/tests/authkey_is_stored.sh` (create), `os/butane/tests/test_units_load_their_env.sh` (create), `tests/verify.sh` (modify)

**Interfaces:** produces `azurerm_key_vault_secret.tailscale_authkey` named `tailscale-authkey`, and an `oc-tailnet.service` that loads the env file naming that vault.

The defect has two halves, and fixing only the first leaves the box just as
unreachable:

1. `var.tailscale_authkey` is required and documented, and
   `terraform.tfvars.example` tells the operator to set it, but no resource
   consumes it. Terraform accepts the value and drops it.
2. `oc-tailnet.service` has no `EnvironmentFile=`. A systemd unit does not inherit
   another unit's `EnvironmentFile`, so `TS_AUTHKEY_SECRET` and `VAULT_NAME` are
   unset, `oc-tailnet-up` skips its Key Vault branch entirely, and it dies with
   "no auth key". The Terraform secret would then exist and never be fetched.

Both get a guard. The second is why the plan also adds a source-level check that no
unit runs a script needing variables from an env file it does not load.

- [ ] **Step 1: Write the failing test**

```bash
#!/usr/bin/env bash
# terraform/tests/authkey_is_stored.sh
#
# A required, documented variable that no resource consumes is a silent drop: the
# operator supplies a key, Terraform accepts it, and the host asks Key Vault for a
# secret that was never written. The tailnet join then fails on every boot.
#
# Usage: authkey_is_stored.sh [path/to/main.tf]
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
main="${1:-$(cd "$here/.." && pwd)/main.tf}"
fail() { echo "FAIL: $1" >&2; exit 1; }

[ -f "$main" ] || fail "no such file: $main"

# The variable must exist at all.
grep -qE '^variable "tailscale_authkey"' "$main" \
  || grep -qE '^variable "tailscale_authkey"' "$(dirname "$main")/variables.tf" \
  || fail "tailscale_authkey is no longer an input"

# It must be consumed, not merely declared.
grep -q 'var\.tailscale_authkey' "$main" \
  || fail "var.tailscale_authkey is declared but no resource consumes it"

# The secret name is a contract with host/bin/oc-tailnet-up, which defaults to
# TS_AUTHKEY_SECRET=tailscale-authkey. Renaming one side silently breaks the join.
start="$(grep -n 'resource "azurerm_key_vault_secret" "tailscale_authkey"' "$main" | head -1 | cut -d: -f1 || true)"
[ -n "$start" ] || fail "no azurerm_key_vault_secret.tailscale_authkey resource"
block="$(tail -n "+$start" "$main" | awk 'NR > 1 && /^}/{exit} {print}')"
printf '%s\n' "$block" | grep -Eq 'name[[:space:]]*=[[:space:]]*"tailscale-authkey"' \
  || fail "secret name is not the one oc-tailnet-up reads"
printf '%s\n' "$block" | grep -q 'var\.tailscale_authkey' \
  || fail "the secret does not carry the variable's value"

# The role assignment must exist before the secret, or the apply races and fails
# with an authorization error that reads like a permissions problem. Match the
# depends_on list itself: a bare mention in a comment would satisfy a looser check
# without ordering anything.
printf '%s\n' "$block" \
  | grep -Eq 'depends_on[[:space:]]*=[[:space:]]*\[[^]]*azurerm_role_assignment\.deployer_kv_admin' \
  || fail "secret does not depend on the deployer's Key Vault role assignment"

echo "the tailscale auth key is stored where the host reads it"
```

- [ ] **Step 2: Run it to verify it fails**

Run: `chmod +x terraform/tests/authkey_is_stored.sh && ./terraform/tests/authkey_is_stored.sh`
Expected: `FAIL: var.tailscale_authkey is declared but no resource consumes it`

- [ ] **Step 3: Add the secret resource**

In `terraform/main.tf`, directly after `azurerm_key_vault_secret.opencode_password`:

```hcl
# The tailnet join reads this by name at boot. host/bin/oc-tailnet-up defaults
# TS_AUTHKEY_SECRET to "tailscale-authkey", so the name is a contract.
#
# Without this resource the variable was accepted and dropped, and the first boot
# failed with a Key Vault 404 that looks like a permissions problem.
resource "azurerm_key_vault_secret" "tailscale_authkey" {
  name         = "tailscale-authkey"
  value        = var.tailscale_authkey
  key_vault_id = azurerm_key_vault.this.id

  depends_on = [azurerm_role_assignment.deployer_kv_admin]
}
```

- [ ] **Step 4: Run the test again**

Run: `./terraform/tests/authkey_is_stored.sh`
Expected: `the tailscale auth key is stored where the host reads it`

- [ ] **Step 5: Say so in the outputs**

`terraform/outputs.tf`, extend the `key_vault_name` description:

```hcl
  description = "Vault holding the server password and the tailnet auth key."
```

- [ ] **Step 6: Add the unit guard and load the env file**

Create `os/butane/tests/test_units_load_their_env.sh`. It parses `ucore.bu` with
python3-yaml, maps each `*.env` file to the variables it defines, maps each
`ExecStart` to the variables its script references (following `lib-imds.sh`), and
fails when a unit runs a script needing variables from an env file it does not
load. Every input comes from the config and the scripts, so the check covers units
that do not exist yet.

It must fail before the config change:

Run: `chmod +x os/butane/tests/test_units_load_their_env.sh && ./os/butane/tests/test_units_load_their_env.sh`
Expected: `FAIL: oc-tailnet.service runs a script needing TS_AUTHKEY_SECRET, VAULT_NAME but does not load /etc/devbox/oc-secrets.env`

Then add the missing line to `oc-tailnet.service` in `os/butane/ucore.bu`, in the
`[Service]` section:

```yaml
        # A unit does not inherit another unit's EnvironmentFile. Without this the
        # join runs with TS_AUTHKEY_SECRET and VAULT_NAME unset, skips Key Vault
        # entirely, and fails with "no auth key" on every fresh boot.
        EnvironmentFile=/etc/devbox/oc-secrets.env
```

Run the guard again. Expected: `every unit loads the env file its scripts need`.

- [ ] **Step 7: Add both suites to the gate**

In `tests/verify.sh`, after the `vault name derivable without state` run block:

```bash
run "auth key stored" \
  ./terraform/tests/authkey_is_stored.sh
```

And after the `tailscale enabled` run:

```bash
run "units load their env" \
  ./os/butane/tests/test_units_load_their_env.sh
```

- [ ] **Step 8: Regenerate the committed Ignition**

```bash
BUTANE=/path/to/butane ./os/butane/build-placeholder.sh
jq -r '.systemd.units[] | select(.name=="oc-tailnet.service") | .contents' os/butane/ucore.ign \
  | grep EnvironmentFile
```

Expected: `EnvironmentFile=/etc/devbox/oc-secrets.env`. Both the `.bu` and the
generated `.ign` must carry it: Terraform reads the `.ign`.

- [ ] **Step 9: Validate and commit**

```bash
terraform -chdir=terraform fmt -check
terraform -chdir=terraform validate
git add terraform/main.tf terraform/outputs.tf terraform/tests/authkey_is_stored.sh \
        os/butane/ucore.bu os/butane/ucore.ign \
        os/butane/tests/test_units_load_their_env.sh tests/verify.sh
git commit -m "fix: deliver the tailscale auth key to the unit that needs it"
```

Expected: `Success! The configuration is valid.`

---

### Task 3: D3 Build the OS image from the ucore image, not plain CoreOS

**Files:** `os/build-os-image.sh` (rewrite), `os/tests/test_build_os_image.sh` (extend), `CHANGELOG.md` (modify)

**Interfaces:** same outputs. Last stdout line stays a `/providers/Microsoft.Compute/images/...` id, so `pipelines/devbox-os.yml` and the Terraform `os_image_id` contract do not change.

The defect: the script downloads `coreos-installer download --stream stable --platform azure`,
which is Fedora's plain CoreOS VHD. The design consumes ucore. A VM booted from
that image is not the OS this repo configures: no `tailscaled` package, no
`podman-restart.service` contract, `zincati` instead of `rpm-ostreed-automatic.timer`.

ucore publishes no Azure VHD, and the design forbids forking the image. So build
one from the published container with `image-builder`, which is the supported
path for turning any bootc image into a disk image.

- [ ] **Step 1: Extend the test to require the ucore source**

Add to `os/tests/test_build_os_image.sh`, before the final `echo`:

```bash
# The published image must be derived from ucore, not from plain Fedora CoreOS.
# A plain FCOS boot gives no tailscaled, no podman autostart contract, and
# zincati instead of the ucore update path, so every host unit fails quietly.
grep -q 'ghcr.io/ublue-os/ucore' "$script" \
  || fail "build script does not reference the ucore image"
grep -q 'image-builder' "$script" \
  || fail "build script does not use image-builder to produce a bootc disk image"
if grep -q 'coreos-installer download' "$script"; then
  fail "build script still downloads the plain Fedora CoreOS VHD"
fi

# The source must be pinned by digest, matching the design's consume-by-digest rule.
grep -Eq 'ghcr\.io/ublue-os/ucore@sha256:[0-9a-f]{64}' "$script" \
  || fail "ucore image is not pinned by digest"

echo "os image is built from the pinned ucore image"
```

- [ ] **Step 2: Run it to verify it fails**

Run: `./os/tests/test_build_os_image.sh`
Expected: `FAIL: build script does not reference the ucore image`

- [ ] **Step 3: Rewrite the build script**

Replace the download-and-upload body of `os/build-os-image.sh` with a
bootc-image-builder step. Keep the precondition style, the `DRY_RUN` contract, and
the provenance line. The digest is the design's recorded one.

```bash
#!/usr/bin/env bash
# Turn the published ucore bootc image into an Azure managed image.
#
# Fedora publishes an Azure VHD for plain CoreOS, and ucore publishes none. Booting
# plain CoreOS gives a host this repo's Ignition does not match: no tailscaled
# package, no podman autostart contract, and zincati instead of ucore's update path.
#
# image-builder is the supported way to produce a disk image from a bootc image.
# The source is pinned by digest and consumed unmodified, per design decision 1.
set -euo pipefail

# Digest recorded in the design's verified-facts table. Bumping it is a deliberate
# change that rolls every VM, not a routine refresh.
UCORE_IMAGE="${UCORE_IMAGE:-ghcr.io/ublue-os/ucore@sha256:7906a70efe7482704fdb232c7e5d2a3068a0c5520ef46d3f7f6b9f8fc0e899b9}"
# Pinned by digest, not `:latest`. The pipeline runs weekly on a cron, so a moving
# tag would swap the builder underneath an unchanged config and make the published
# image non-reproducible with nothing in the diff to review.
IMAGE_BUILDER="${IMAGE_BUILDER:-ghcr.io/osbuild/image-builder-cli@sha256:37b7c22483b03013f54030094683d8af8a83ee642c2a4dc9a51dcd9a79be6b6f}"
RG="${RG:?RG is required}"
STORAGE_ACCOUNT="${STORAGE_ACCOUNT:?STORAGE_ACCOUNT is required}"
CONTAINER="${CONTAINER:-images}"
LOCATION="${LOCATION:-westeurope}"
DRY_RUN="${DRY_RUN:-0}"

command -v podman >/dev/null || { echo "podman not installed; image-builder needs a privileged container" >&2; exit 1; }
command -v az >/dev/null || { echo "az not installed" >&2; exit 1; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

echo "building a vhd from ${UCORE_IMAGE}" >&2
if [ "$DRY_RUN" != "1" ]; then
  mkdir -p "$work/output"
  # --privileged and the container-storage mount are what image-builder documents
  # for the container path. The output VHD is the only artifact we keep.
  podman run --rm --privileged \
    --security-opt label=type:unconfined_t \
    --volume "$work/output:/output" \
    --volume /var/lib/containers/storage:/var/lib/containers/storage \
    "$IMAGE_BUILDER" build \
    --output-dir /output \
    --bootc-ref "$UCORE_IMAGE" \
    vhd
  vhd="$(find "$work/output" -name '*.vhd' -print -quit)"
  [ -f "$vhd" ] || { echo "no vhd produced" >&2; exit 1; }
  # Provenance next to the artifact. This is what an auditor asks for.
  sha256sum "$vhd" | tee "$vhd.sha256" >&2
fi

name="devbox-ucore-$(date -u +%Y%m%d)"
blob="${name}.vhd"

if [ "$DRY_RUN" = "1" ]; then
  echo "dry run: would build $UCORE_IMAGE and upload to $STORAGE_ACCOUNT/$CONTAINER as $blob"
  echo "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/${RG}/providers/Microsoft.Compute/images/${name}"
  exit 0
fi

az storage blob upload --account-name "$STORAGE_ACCOUNT" -c "$CONTAINER" \
  -f "$vhd" -n "$blob" --overwrite --only-show-errors
az image create -g "$RG" -n "$name" --location "$LOCATION" --os-type Linux \
  --hyper-v-generation V2 \
  --source "https://${STORAGE_ACCOUNT}.blob.core.windows.net/${CONTAINER}/${blob}" \
  --only-show-errors -o none

az image show -g "$RG" -n "$name" --query id -o tsv
```

- [ ] **Step 4: Fix the pipeline's container engine**

`pipelines/devbox-os.yml` installs `coreos-installer` from a pinned image, which is
no longer used. Delete that step and its comment.

Do not symlink docker to podman. A symlink accepts `--version` and then fails on the
flags image-builder needs: docker rejects `--security-opt label=type:...` (an SELinux
option) and has no `/var/lib/containers/storage`. Install real podman instead, and
print its version so the agent records what actually ran:

```yaml
      - script: |
          set -euo pipefail
          sudo apt-get update
          sudo apt-get install -y --no-install-recommends podman
          podman --version
        displayName: install podman for image-builder
```

The `AzureCLI@2` wrapper and its `RG`/`STORAGE_ACCOUNT` exports stay.

- [ ] **Step 5: Run the test again**

Run: `./os/tests/test_build_os_image.sh`
Expected: `os image is built from the pinned ucore image`

- [ ] **Step 6: Record it in the changelog**

Under `## Unreleased` → `### Fixed`:

```markdown
- The OS image is now built from the pinned ucore bootc image with
  `image-builder`, not from Fedora's plain CoreOS VHD. The previous script
  published an OS without `tailscaled`, without ucore's podman autostart
  contract, and with zincati in place of ucore's update path.
```

- [ ] **Step 7: Commit**

```bash
git add os/build-os-image.sh os/tests/test_build_os_image.sh pipelines/devbox-os.yml CHANGELOG.md
git commit -m "fix(os): build the image from ucore, not plain Fedora CoreOS"
```

---

### Task 4: D4 Guard every quadlet EnvironmentFile against having no writer

**Files:** `host/tests/test_quadlet_persistence.sh` (extend)

**Interfaces:** none. A guard only.

The quadlet's `EnvironmentFile=/etc/opencode/env` is correct: `oc-secrets` writes
exactly that path. But the same class of defect as D2, a config naming something no
component produces, would fail at boot as an unset variable rather than a missing
file. This pins the contract before the next occurrence, and pins the password
variable name to both sides.

- [ ] **Step 1: Extend the quadlet test**

Add to `host/tests/test_quadlet_persistence.sh`, before the final `echo`:

```bash
# Every EnvironmentFile the quadlet names must be written by a component we ship.
# A reference to a file nothing produces is how the tailnet key went missing, and
# the failure surfaces at boot as a variable that is merely unset, not as a
# missing-file error.
while read -r path; do
  grep -rqF "$path" "$(dirname "$q")/../bin" "$(dirname "$q")/../../os/butane/ucore.bu" \
    || fail "no component writes the quadlet's EnvironmentFile: $path"
done < <(grep -E '^EnvironmentFile=' "$q" | cut -d= -f2)

# The container's password comes from that file, so the writer and the reader must
# agree on the name. oc-secrets writes it with printf rather than a literal line,
# so match the variable name in a write, not a line start.
grep -q "OPENCODE_PASSWORD=" "$(dirname "$q")/../bin/oc-secrets" \
  || fail "oc-secrets does not write OPENCODE_PASSWORD"
grep -q 'OPENCODE_PASSWORD' "$(dirname "$q")/../bin/oc-idle-check" \
  || fail "oc-idle-check does not read the password oc-secrets writes"
```

- [ ] **Step 2: Run it to prove it passes for the right reason**

Run: `./host/tests/test_quadlet_persistence.sh`
Expected: `persistent data is on the data disk`

Then prove the guard is not vacuous: temporarily change the quadlet to
`EnvironmentFile=/etc/opencode/missing.env`, rerun, and confirm
`FAIL: no component writes the quadlet's EnvironmentFile: /etc/opencode/missing.env`.
Revert the change. A guard never observed failing is not a guard.

- [ ] **Step 3: Commit**

```bash
git add host/tests/test_quadlet_persistence.sh
git commit -m "test(host): assert every quadlet EnvironmentFile has a writer"
```

---

### Task 5: D5 Document what first boot actually does

**Files:** `docs/runbook.md` (modify), `README.md` (modify), `tests/docs_complete.sh` (extend)

**Interfaces:** none. Documentation and its guard.

The defect after D3: the OS image is built directly from the ucore bootc image, so
first boot is a single boot with no autorebase. The runbook must say how to prove
the box really is ucore, because a silent fallback to plain CoreOS is the failure
mode D3 exists to prevent. Naming `tailscaled` matters too: it is the unit most
likely to be down when the box is unreachable.

- [ ] **Step 1: Extend the docs guard**

Add to `tests/docs_complete.sh`, before the final `echo`:

```bash
# The published image is built from ucore. An operator needs a command that proves
# the booted OS is ucore and not the plain CoreOS image this repo used to publish.
grep -riq "rpm-ostree status" "$root/docs/runbook.md" \
  || fail "runbook does not tell the operator how to confirm the booted OS is ucore"
grep -riq "tailscaled" "$root/docs/runbook.md" \
  || fail "runbook does not name tailscaled, the unit most likely to be down"
```

- [ ] **Step 2: Run it to verify it fails**

Run: `./tests/docs_complete.sh`
Expected: `FAIL: runbook does not tell the operator how to confirm the booted OS is ucore`

- [ ] **Step 3: Add the boot verification to the runbook**

In `docs/runbook.md`, replace the body of stage 6 with:

```markdown
### 6. Verify first boot

The image is a disk built from the ucore bootc image, so the box is ucore on its
first boot with no rebase stage. Prove that before trusting anything above it:

```sh
ssh core@devbox "rpm-ostree status"
```

The booted deployment must name `ghcr.io/ublue-os/ucore`. If it names
`fedora-coreos`, the published image is the old plain-CoreOS artifact: rebuild it
with `./os/build-os-image.sh` and re-apply. Every host unit below depends on ucore
packages, so nothing else will work until this is right.

Then confirm the three devbox units and the daemon the tailnet path needs:

```sh
ssh core@devbox "systemctl is-active tailscaled oc-secrets oc-tailnet opencode"
ssh core@devbox "sudo podman ps --format '{{.Names}} {{.Status}}'"
```

All four units must report `active` and the container must be `healthy`. If
`opencode` is not active, `oc-secrets` failed first: check
`sudo journalctl -u oc-secrets -n 40`. If `tailscaled` is not active, the box has
no tailnet path and needs Bastion; check `sudo journalctl -u tailscaled -n 40`.
```

- [ ] **Step 4: State the reachability chain in the README**

Add a row to the README's component table, after the OS image row:

```markdown
| Tailnet path | `tailscaled` enabled by Ignition, then `oc-tailnet.service` | both must be up; without them the box is Bastion-only |
```

- [ ] **Step 5: Run the guard again**

Run: `./tests/docs_complete.sh`
Expected: `docs complete`

- [ ] **Step 6: Run the whole gate**

Run: `./tests/verify.sh`
Expected: `VERIFY: all suites pass`

- [ ] **Step 7: Commit**

```bash
git add docs/runbook.md README.md tests/docs_complete.sh
git commit -m "docs: how to prove the box booted ucore, and the tailnet dependency"
```

---

## Batch E: operator steps, unchanged in shape

These need a live subscription. D1 to D3 change what they exercise, not the order.

| Step | Command | Success looks like |
|---|---|---|
| E1 publish OS image | run `pipelines/devbox-os.yml`, or `./os/build-os-image.sh` | last stdout line is `/providers/Microsoft.Compute/images/devbox-ucore-...` |
| E2 apply | `terraform -chdir=terraform apply -var-file=terraform.tfvars` | precondition passes, VM created, no public IP in the plan |
| E3 confirm the OS is ucore | `ssh core@devbox "rpm-ostree status"` | the booted deployment names `ghcr.io/ublue-os/ucore` |
| E4 confirm the tailnet path | `ssh core@devbox "systemctl is-active tailscaled oc-tailnet"` | `active` twice |
| E5 build container | run `pipelines/devbox-image.yml` | `:prod` exists, smoke gate passed, digest recorded |
| E6 first boot check | `journalctl -u oc-secrets -u oc-tailnet -u opencode` | all active, `podman ps` healthy |
| E7 pair client | `opencode pair --url https://<host>.<tailnet>.ts.net` | desktop app connects, TUI connects with `--server` |
| E8 cost model | leave the box idle 50 minutes | `oc-idle-check` logs `idle for 45m` |

E3 and E4 are new. Without them, E1 could still publish the wrong image and E4
would fail at the last step with no clear cause.

## Batch F: vendoring

Unchanged from `docs/vendoring.md`. Two edits at copy time: prefix every pipeline
path, and decide whether Terraform moves at all.

## Definition of done

- `./tests/verify.sh` ends `VERIFY: all suites pass`.
- `terraform -chdir=terraform validate` reports `Success`.
- Each of D1, D2, D3 has a guard that was observed failing before the fix.
- `CHANGELOG.md` records the three fixes under `Unreleased` → `Fixed`.
- Batch E is listed as operator-only, with its unverified status stated.
