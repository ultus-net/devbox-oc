# Devbox ucore OS + Fedora Toolbox Container Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a reproducible Azure dev server whose OS is a signed ucore image and whose toolchain is a Fedora container, with idle-gated shutdown and direct client connection over a tailnet.

**Architecture:** A Fedora CoreOS derived OS image (`ucore-minimal`) boots from a managed image that a pipeline publishes from the upstream Azure VHD. A rootful podman quadlet runs the dev container, which carries OpenCode plus toolchains. Ignition configures the host; it carries no secrets. Secrets come from Key Vault over IMDS at boot. A systemd timer probes five OpenCode endpoints and deallocates the VM when idle.

**Tech Stack:** Terraform 1.9+ / azurerm 4.x, Fedora CoreOS, Butane/Ignition, podman quadlets, systemd, Azure DevOps Pipelines, ACR, Key Vault, IMDS + ARM REST, Tailscale.

**Spec:** `docs/superpowers/specs/2026-10-27-devbox-opencode-design.md`

## Global Constraints

- Fedora family only. No Ubuntu, no Debian, at any layer.
- No public IP on the VM NIC. No inbound NSG rule from `Internet`.
- Podman only. `docker.socket` is disabled upstream on ucore and Fedora CoreOS warns against mixing Docker and Podman workloads.
- Consume upstream `ucore-minimal` unmodified. No host packages installed at runtime. Runtime state goes in `/var` or on the data disk.
- Pin the OS image by digest. Never a moving tag for the OS.
- The container consumes a moving `:prod` tag; the resolved digest is committed to `image/prod-digest.txt`.
- Secrets never appear in `custom_data`, Ignition, an image layer, or git.
- The idle gate fails closed: any probe error means stay up.
- Scheduled start only. **No scheduled hard stop.**
- Every task ends with a commit. One logical change per commit.

## Review Focus

Failure modes the spec implies but no task's happy-path test covers. Each has a test in the task that owns the code.

1. **A probe that partially fails.** If `session/active` answers but `pty` times out, the gate must stay up rather than treat the missing answer as zero. Pinned in Task 2.
2. **A shutdown racing a session start.** A session created between probe and deallocate must survive. Pinned in Task 2.
3. **A cold container mistaken for idle.** On boot the API is not listening; that is not idleness. Pinned in Task 2.
4. **A rebuild that loses the data disk.** A stack teardown must be blocked by `prevent_destroy`, and a snapshot must be restorable. Pinned in Tasks 8 and 9.
5. **A promoted tag with no digest record.** Rollback with no recorded digest is unrecoverable. Pinned in Task 4.
6. **Persistent data on the OS disk.** A podman named volume lands in `/var/lib/containers/storage`, which is recreated with the VM, so a rebuild silently discards every session. This is the defect this plan's own review caught. Pinned in Task 6 step 2b.

---

## File Structure

| Path | Responsibility |
|---|---|
| `image/Dockerfile` | Fedora toolbox image with OpenCode installed from the verified glibc artifact |
| `image/toolchains.txt` | dnf package list, the operator's portable toolchain |
| `image/prod-digest.txt` | the resolved digest behind `:prod`, committed for rollback |
| `os/build-os-image.sh` | download FCOS Azure VHD, upload, create managed image |
| `os/butane/ucore.bu` | Ignition source: users, disks, quadlets, timers |
| `host/bin/` | `oc-secrets`, `oc-acr-login`, `oc-idle-check`, `oc-tailnet`, `oc-tailnet-up`, `oc-snapshot`, `lib-imds.sh` |
| `host/quadlet/opencode.container` | the dev container unit |
| `tools/oc` | operator's wake-and-connect wrapper |
| `terraform/` | Azure resources, one file per concern |
| `pipelines/devbox-image.yml` | build the container, promote, record digest |
| `pipelines/devbox-os.yml` | publish the OS managed image |
| `docs/runbook.md` | recovery, rollback, snapshot restore, tailnet rejoin |
| `docs/vendoring.md` | how this moves into the existing Azure DevOps repo |

`host/` is what gets baked into the OS image by Butane. `terraform/` never
manages the container. One owner per resource.

### Deleted by this plan

`host/compose.yaml` (replaced by a quadlet), `host/bin/oc-image-update`
(replaced by `podman auto-update`), all of `host/systemd/*` (replaced by
quadlets), and `terraform/*` as written (Ubuntu image, cloud-init). Removal
happens in the task that replaces each file.

---

### Task 1: Container image foundation

Establishes the image that every later task deploys or pulls.

**Files:**
- Modify: `image/Dockerfile`
- Keep: `image/toolchains.txt`
- Create: `image/prod-digest.txt`
- Test: `image/smoke.sh`

**Interfaces:**
- Produces: an image reference `<acr>.azurecr.io/devbox:<tag>` whose binary prints a version string starting with `opencode v`.

- [ ] **Step 1: Write the failing smoke test**

```bash
#!/usr/bin/env bash
# image/smoke.sh - asserts the image is fit to serve, not just to build.
set -euo pipefail
ref="${1:?usage: smoke.sh <image-ref>}"

run() { podman run --rm --entrypoint "" "$ref" "$@"; }

# 1. The binary exists and runs on this base's libc.
run opencode --version | grep -q '^opencode v'

# 2. The dev user exists with the pinned uid, so bind mounts line up.
run id -u dev | grep -qx 1000

# 3. Runtime tools the agent needs are present.
for t in git jq rg fd curl; do run command -v "$t" >/dev/null; done

# 4. It does not run as root.
test "$(podman image inspect "$ref" --format '{{.Config.User}}')" = "dev"

echo "smoke ok: $ref"
```

- [ ] **Step 2: Run it to verify it fails**

Run: `chmod +x image/smoke.sh && ./image/smoke.sh ghcr.io/anomalyco/opencode:2.1.4`
Expected: FAIL at the `id -u dev` check, because the upstream image has no `dev` user. This proves the test detects a missing user rather than passing vacuously.

If this machine has no usable container engine (docker socket permission denied,
no podman), record that and skip to step 2b. The smoke test still runs, but in the
pipeline from Task 4, where it becomes a blocking gate before promotion.

- [ ] **Step 2b: Verify the integrity check without a container engine**

The sha512 check is the load-bearing part of the build, so it must be provable
without Docker.

```bash
#!/usr/bin/env bash
# image/tests/test_integrity_logic.sh
# Runs exactly the Dockerfile's check: decode the base64 sha512 to hex, then
# compare against sha512sum of the tarball. Includes a negative control.
set -euo pipefail

OC_SHA512='o8EJ0ZsT4dzDKN+0mpG2EKbNGzJyp+F1++Av28UReRVfiEv+N34eZEnN/unkiMoerKHad6W6Ii7k4ukTnPNmNQ=='
tarball="${1:?usage: test_integrity_logic.sh <tarball>}"

expected="$(printf '%s' "$OC_SHA512" | base64 -d | od -An -tx1 | tr -d ' \n')"
actual="$(sha512sum "$tarball" | cut -d' ' -f1)"

[ "$actual" = "$expected" ] || { echo "integrity check FAILS" >&2; exit 1; }
echo "integrity check PASSES"

corrupt="$(mktemp)"
trap 'rm -f "$corrupt"' EXIT
cp "$tarball" "$corrupt"
printf 'x' >> "$corrupt"
if [ "$(sha512sum "$corrupt" | cut -d' ' -f1)" = "$expected" ]; then
  echo "negative control FAILED: corrupted input still matched" >&2
  exit 1
fi
echo "negative control passes: corruption is detected"
```

Run:
`curl -fsSL -o /tmp/oc.tgz https://registry.npmjs.org/@opencode/cli-linux-x64/-/cli-linux-x64-2.1.4.tgz && ./image/tests/test_integrity_logic.sh /tmp/oc.tgz`
Expected: `integrity check PASSES` then
`negative control passes: corruption is detected`

- [ ] **Step 3: Add the container config to the Dockerfile**

Add `containers-common` to the existing `dnf install` list in `image/Dockerfile`,
and append after the OpenCode install block:

```dockerfile
RUN install -d -m 0755 /etc/containers/registries.conf.d && \
    printf '%s\n' '[registries.search]' 'registries = ["docker.io"]' \
      > /etc/containers/registries.conf.d/010-devbox.conf
```

- [ ] **Step 4: Run the smoke test to verify it passes**

Run: `podman build -t devbox:local image/ && ./image/smoke.sh devbox:local`
Expected: `smoke ok: devbox:local`

- [ ] **Step 5: Create the digest record placeholder**

```bash
printf '%s\n' '# Written by pipelines/devbox-image.yml. Never hand-edit.' > image/prod-digest.txt
printf '%s\n' 'sha256:0000000000000000000000000000000000000000000000000000000000000000' >> image/prod-digest.txt
```

- [ ] **Step 6: Commit**

```bash
git add image/Dockerfile image/toolchains.txt image/smoke.sh image/prod-digest.txt
git commit -m "feat(image): Fedora toolbox base with verified glibc OpenCode install"
```

---

### Task 2: Idle gate with pin file and fail-closed probes

The single most safety-critical script. It must never stop a box that is doing
work.

**Files:**
- Modify: `host/bin/oc-idle-check`
- Create: `host/tests/test_oc-idle-check.sh`

**Interfaces:**
- Consumes: `/etc/opencode/env` containing `OPENCODE_PASSWORD`.
- Produces: exit 0 in all cases. Query params: `ENV_FILE`, `VM_ID_FILE`, `STATE`, `PIN_FILE`, `UPTIME_OVERRIDE`, `IDLE_MIN`, `BOOT_GRACE`, `DRY_RUN`. Writes `/var/lib/oc-idle/last-busy`, reads `/var/lib/oc-idle/pin`.

- [ ] **Step 1: Write the failing tests**

```bash
#!/usr/bin/env bash
# host/tests/test_oc-idle-check.sh
# Fake curl, date and az on PATH, so no network, clock or Azure is needed.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
script="$here/../bin/oc-idle-check"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }

setup() {
  rm -rf "$tmp/bin" "$tmp/state"
  mkdir -p "$tmp/bin" "$tmp/state"
  printf 'OPENCODE_PASSWORD=pw\n' > "$tmp/env"
  printf '/subscriptions/x/resourceGroups/r/providers/Microsoft.Compute/virtualMachines/v\n' > "$tmp/vmid"
  : > "$tmp/arm-calls"
  cat > "$tmp/bin/curl" <<'EOF'
#!/usr/bin/env bash
url="${*: -1}"
if [[ "$url" == *"/api/"* ]]; then
  ep="$(printf '%s' "$url" | sed 's|.*/api/||')"
  case " ${FAIL_EPS:-} " in *" $ep "*) exit 28 ;; esac   # timeout, like a real failure
  printf '%s' "${RESP:-{\"data\":[]}}"
  exit 0
fi
if [[ "$url" == *"169.254.169.254"* ]]; then printf '%s' '{"access_token":"tok"}'; exit 0; fi
if [[ "$url" == *"management.azure.com"* ]]; then echo "$url" >> "$ARM_CALLS"; exit 0; fi
exit 0
EOF
  cat > "$tmp/bin/date" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == "+%s" ]] && { printf '%s' "${NOW:-1000000}"; exit 0; }
exec /bin/date "$@"
EOF
  chmod +x "$tmp/bin/curl" "$tmp/bin/date"
}

run_gate() {
  PATH="$tmp/bin:$PATH" \
  ENV_FILE="$tmp/env" VM_ID_FILE="$tmp/vmid" STATE="$tmp/state/last-busy" \
  PIN_FILE="${PIN_FILE:-$tmp/state/pin}" ARM_CALLS="$tmp/arm-calls" \
  UPTIME_OVERRIDE="${UPTIME:-2000}" IDLE_MIN="${IDLE_MIN:-45}" \
  "$script" >/dev/null 2>&1 || true
}

# T1: a running session blocks shutdown.
setup; RESP='{"data":{"ses_1":{"type":"running"}}}' run_gate
[ ! -s "$tmp/arm-calls" ] || fail "T1 deallocated with a running session"

# T2: a partial failure blocks shutdown. pty times out, everything else empty.
setup; RESP='{"data":[]}' FAIL_EPS='pty' run_gate
[ ! -s "$tmp/arm-calls" ] || fail "T2 deallocated after a probe error"

# T3: boot grace blocks shutdown.
setup; RESP='{"data":[]}' UPTIME=100 run_gate
[ ! -s "$tmp/arm-calls" ] || fail "T3 deallocated inside boot grace"

# T4: the pin file blocks shutdown, even when idle and old.
setup; RESP='{"data":[]}' NOW=2000000
printf '1700000000\n' > "$tmp/state/last-busy"
: > "$tmp/state/pin"
run_gate
[ ! -s "$tmp/arm-calls" ] || fail "T4 deallocated while pinned"

# T5: genuinely idle past threshold and unpinned deallocates exactly once.
setup; RESP='{"data":[]}' NOW=2000000
printf '1700000000\n' > "$tmp/state/last-busy"
run_gate
[ "$(wc -l < "$tmp/arm-calls")" -eq 1 ] || fail "T5 expected exactly one deallocate call"

# T6: inside the threshold, no action.
setup; RESP='{"data":[]}' NOW=1000000
printf '999900\n' > "$tmp/state/last-busy"
run_gate
[ ! -s "$tmp/arm-calls" ] || fail "T6 deallocated inside the idle threshold"

echo "all idle-gate tests passed"
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `chmod +x host/tests/test_oc-idle-check.sh && ./host/tests/test_oc-idle-check.sh`
Expected: FAIL with `T4 deallocated while pinned`, because the pin file is not implemented. T1 and T2 should already pass, since fail-closed and the busy signals exist.

- [ ] **Step 3: Add the pin file and testability hooks**

This task keeps its own inline IMDS call. `lib-imds.sh` is created in Task 3, so
sourcing it here would make this task unbuildable on its own.

In `host/bin/oc-idle-check`, add alongside the other variable defaults:

```bash
PIN_FILE="${PIN_FILE:-/var/lib/oc-idle/pin}"
UPTIME_OVERRIDE="${UPTIME_OVERRIDE:-}"
```

Replace the uptime read with:

```bash
uptime_s="${UPTIME_OVERRIDE:-$(cut -d. -f1 /proc/uptime)}"
```

Immediately after the env and vm-id existence checks, add:

```bash
# Operator escape hatch. Work the five API signals cannot see lives behind this.
if [ -e "$PIN_FILE" ]; then
  printf '%s\n' "$(date +%s)" > "$STATE"
  exit 0
fi
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `./host/tests/test_oc-idle-check.sh`
Expected: `all idle-gate tests passed`

- [ ] **Step 5: Commit**

```bash
git add host/bin/oc-idle-check host/tests/test_oc-idle-check.sh
git commit -m "feat(host): idle gate with pin file and fail-closed probes"
```

---

### Task 3: Secret and ACR credential bootstrap

**Files:**
- Modify: `host/bin/oc-secrets`
- Create: `host/bin/oc-acr-login`
- Test: `host/tests/test_oc-secrets.sh`

**Interfaces:**
- Consumes: `VAULT_NAME`, `ACR_NAME` from `/etc/devbox/oc-secrets.env`.
- Produces: `/etc/opencode/env` with `OPENCODE_PASSWORD=...` at mode 0600, and `/etc/containers/auth.json` with an `auths` entry keyed on `<acr>.azurecr.io`.

- [ ] **Step 1: Write the failing test**

```bash
#!/usr/bin/env bash
# host/tests/test_oc-secrets.sh
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
fail() { echo "FAIL: $1" >&2; exit 1; }
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"

cat > "$tmp/bin/curl" <<'EOF'
#!/usr/bin/env bash
url="${*: -1}"
if [[ "$url" == *"169.254.169.254"* ]]; then printf '%s' '{"access_token":"tok"}'; exit 0; fi
if [[ "$url" == *"vault.azure.net/secrets/opencode-password"* ]]; then
  printf '%s' "${SECRET_RESP:-{\"value\":\"s3cret\"}}"; exit 0
fi
if [[ "$url" == *"/oauth2/exchange"* ]]; then printf '%s' '{"refresh_token":"r3fresh"}'; exit 0; fi
exit 0
EOF
chmod +x "$tmp/bin/curl"

# T1: writes the documented variable with tight permissions.
PATH="$tmp/bin:$PATH" VAULT_NAME=v OUT_FILE="$tmp/env" "$here/../bin/oc-secrets"
grep -qx 'OPENCODE_PASSWORD=s3cret' "$tmp/env" || fail "T1 wrong content"
[ "$(stat -c '%a' "$tmp/env")" = "600" ] || fail "T1 wrong mode"

# T2: an empty secret must not overwrite a good file.
printf 'OPENCODE_PASSWORD=old\n' > "$tmp/env"; chmod 600 "$tmp/env"
if SECRET_RESP='{"value":""}' PATH="$tmp/bin:$PATH" VAULT_NAME=v \
     OUT_FILE="$tmp/env" "$here/../bin/oc-secrets" 2>/dev/null; then
  fail "T2 should have refused an empty secret"
fi
grep -qx 'OPENCODE_PASSWORD=old' "$tmp/env" || fail "T2 clobbered the good file"

# T3: ACR login writes an auths entry for the registry hostname.
PATH="$tmp/bin:$PATH" ACR_NAME=myreg OUT="$tmp/auth.json" "$here/../bin/oc-acr-login"
jq -e '.auths["myreg.azurecr.io"].auth' "$tmp/auth.json" >/dev/null || fail "T3 no auths entry"
[ "$(stat -c '%a' "$tmp/auth.json")" = "600" ] || fail "T3 wrong mode"

echo "all secret tests passed"
```

- [ ] **Step 2: Run to verify it fails**

Run: `chmod +x host/tests/test_oc-secrets.sh && ./host/tests/test_oc-secrets.sh`
Expected: FAIL with `No such file or directory` on `oc-acr-login` at T3. T1 and T2 pass, because the existing script already writes atomically.

- [ ] **Step 3: Write `host/bin/oc-acr-login`**

```bash
#!/usr/bin/env bash
# Exchange the VM's managed identity for an ACR refresh token and write
# /etc/containers/auth.json. Keeps the ACR admin account disabled.
set -euo pipefail
ACR_NAME="${ACR_NAME:?ACR_NAME is required}"
OUT="${OUT:-/etc/containers/auth.json}"
REGISTRY="${ACR_NAME}.azurecr.io"

# shellcheck source=lib-imds.sh
. "$(dirname "$0")/lib-imds.sh"

umask 077
install -d -m 0700 "$(dirname "$OUT")"

token="$(imds_token https://management.azure.com/)"
creds="$(curl -fsS -m 20 -X POST "https://${REGISTRY}/oauth2/exchange" \
  --data-urlencode "grant_type=access_token" \
  --data-urlencode "service=${REGISTRY}" \
  --data-urlencode "access_token=${token}")"
refresh="$(printf '%s' "$creds" | jq -r '.refresh_token')"
[ -n "$refresh" ] && [ "$refresh" != "null" ] || { echo "oc-acr-login: no refresh token" >&2; exit 1; }

tmp="$(mktemp "$(dirname "$OUT")/.auth.XXXXXX")"
printf '{"auths":{"%s":{"auth":"%s"}}}\n' "$REGISTRY" \
  "$(printf '00000000-0000-0000-0000-000000000000:%s' "$refresh" | base64 -w0)" > "$tmp"
mv "$tmp" "$OUT"
chmod 0600 "$OUT"
```

- [ ] **Step 4: Create the shared IMDS helper it depends on**

Create `host/bin/lib-imds.sh`:

```bash
# shellcheck shell=bash
# One managed-identity token path, so three scripts cannot drift apart.
IMDS_ENDPOINT="http://169.254.169.254/metadata/identity/oauth2/token"

imds_token() {
  local resource="${1:-https://management.azure.com/}" enc
  enc="$(printf '%s' "$resource" | jq -sRr @uri)"
  curl -fsS -m 10 -H Metadata:true \
    "${IMDS_ENDPOINT}?api-version=2018-02-01&resource=${enc}" \
    | jq -r '.access_token'
}

kv_secret() {
  local vault="$1" name="$2" token
  token="$(imds_token https://vault.azure.net)" || return 1
  curl -fsS -m 20 -H "Authorization: Bearer ${token}" \
    "https://${vault}.vault.azure.net/secrets/${name}?api-version=7.4" | jq -r '.value'
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `./host/tests/test_oc-secrets.sh`
Expected: `all secret tests passed`

- [ ] **Step 6: Commit**

```bash
git add host/bin/oc-secrets host/bin/oc-acr-login host/bin/lib-imds.sh host/tests/test_oc-secrets.sh
git commit -m "feat(host): Key Vault env bootstrap and managed-identity ACR login"
```

---

### Task 4: Image pipeline with digest promotion

**Files:**
- Create: `pipelines/devbox-image.yml`
- Modify: `image/prod-digest.txt`

**Interfaces:**
- Consumes: `devbox-image` service connection (workload identity federation) holding `Container Registry Repository Writer`.
- Produces: `<acr>.azurecr.io/devbox:prod` pointing at the new digest, and `image/prod-digest.txt` committed with that digest.

- [ ] **Step 1: Write the pipeline**

```yaml
# pipelines/devbox-image.yml
trigger:
  branches: [main]
  paths:
    - image/*
pr: none

variables:
  acrName: devboxacr
  repo: devbox

jobs:
  - job: build
    pool: { vmImage: ubuntu-latest }
    steps:
      - task: AzureCLI@2
        displayName: Build and push
        inputs:
          azureSubscription: devbox-image
          scriptType: bash
          scriptLocation: inlineScript
          inlineScript: |
            set -euo pipefail
            tag="sha-$(Build.SourceVersion)"
            az acr login -n "$(acrName)"
            docker build -t "$(acrName).azurecr.io/$(repo):$tag" image/
            docker push "$(acrName).azurecr.io/$(repo):$tag"

      # Blocking gate. Invokes the real smoke test, so there is one definition of
      # "fit to serve" rather than an inline copy that drifts from image/smoke.sh.
      - script: |
          set -euo pipefail
          ENGINE=docker bash image/smoke.sh \
            "$(acrName).azurecr.io/$(repo):sha-$(Build.SourceVersion)"
        displayName: Smoke gate before promotion

      - task: AzureCLI@2
        displayName: Promote to prod and capture digest
        inputs:
          azureSubscription: devbox-image
          scriptType: bash
          scriptLocation: inlineScript
          inlineScript: |
            set -euo pipefail
            src="$(acrName).azurecr.io/$(repo):sha-$(Build.SourceVersion)"
            digest="$(az acr manifest show-metadata -r "$(acrName)" \
              -n "$(repo):sha-$(Build.SourceVersion)" --query digest -o tsv)"
            az acr import -n "$(acrName)" --source "$src" --image "$(repo):prod" --force
            echo "promoted $digest"
            printf '# Written by pipelines/devbox-image.yml. Never hand-edit.\n%s\n' \
              "$digest" > "$(Build.SourcesDirectory)/image/prod-digest.txt"

      - script: |
          git config user.name "devbox-ci"
          git config user.email "devbox-ci@users.noreply.github.com"
          git add image/prod-digest.txt
          git diff --staged --quiet || git commit -m "chore(image): promote to prod [skip ci]"
          git push
        displayName: Record digest
```

- [ ] **Step 2: Write the digest-format assertion**

Create the file. It is the only check on the rollback record, so it is a real
test file rather than an inline command.

```bash
#!/usr/bin/env bash
# image/tests/test_digest_record.sh
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
f="$here/prod-digest.txt"
fail() { echo "FAIL: $1" >&2; exit 1; }
[ -s "$f" ] || fail "digest record is empty"
grep -cE '^sha256:[0-9a-f]{64}$' "$f" | grep -qx 1 || fail "digest record must hold exactly one digest"
echo "digest record is well formed"
```

- [ ] **Step 3: Run it**

Run: `chmod +x image/tests/test_digest_record.sh && ./image/tests/test_digest_record.sh`
Expected: `digest record is well formed`

- [ ] **Step 4: Commit**

```bash
git add pipelines/devbox-image.yml image/prod-digest.txt image/tests
git commit -m "feat(pipeline): build, promote to prod, and record the container digest"
```

---

### Task 5: OS image publish script

**Files:**
- Create: `os/build-os-image.sh`
- Create: `pipelines/devbox-os.yml`

**Interfaces:**
- Produces: a managed image named `devbox-fcos-<stream>-<date>`, and prints its resource ID as the last line of stdout.

- [ ] **Step 1: Write the script**

```bash
#!/usr/bin/env bash
# Download the Fedora CoreOS Azure VHD, upload it, and create a managed image.
# Fedora publishes no CoreOS image in the Azure marketplace, so this step exists.
set -euo pipefail

STREAM="${STREAM:-stable}"
RG="${RG:?RG is required}"
STORAGE_ACCOUNT="${STORAGE_ACCOUNT:?STORAGE_ACCOUNT is required}"
CONTAINER="${CONTAINER:-images}"
LOCATION="${LOCATION:-westeurope}"
DRY_RUN="${DRY_RUN:-0}"

command -v coreos-installer >/dev/null || { echo "coreos-installer not installed; see docs/runbook.md" >&2; exit 1; }
command -v az >/dev/null || { echo "az not installed" >&2; exit 1; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

echo "downloading FCOS ${STREAM} azure vhd" >&2
coreos-installer download --decompress --stream "$STREAM" --platform azure \
  --format vhd.xz --directory "$work"
vhd="$(find "$work" -name '*.vhd' -print -quit)"
[ -f "$vhd" ] || { echo "no vhd produced" >&2; exit 1; }

# Provenance next to the artifact. This is what an auditor asks for.
sha256sum "$vhd" | tee "$vhd.sha256" >&2

name="devbox-fcos-${STREAM}-$(date -u +%Y%m%d)"
blob="${name}.vhd"

if [ "$DRY_RUN" = "1" ]; then
  echo "dry run: would upload $vhd to $STORAGE_ACCOUNT/$CONTAINER as $blob"
  echo "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/${RG}/providers/Microsoft.Compute/images/${name}"
  exit 0
fi

az storage blob upload --account-name "$STORAGE_ACCOUNT" -c "$CONTAINER" \
  -f "$vhd" -n "$blob" --overwrite --only-show-errors
az image create -g "$RG" -n "$name" --location "$LOCATION" --os-type Linux \
  --source "https://${STORAGE_ACCOUNT}.blob.core.windows.net/${CONTAINER}/${blob}" \
  --only-show-errors -o none

az image show -g "$RG" -n "$name" --query id -o tsv
```

- [ ] **Step 2: Verify the precondition failure mode**

Run: `chmod +x os/build-os-image.sh && STREAM=stable RG=rg-x STORAGE_ACCOUNT=x DRY_RUN=1 ./os/build-os-image.sh`
Expected: `coreos-installer not installed; see docs/runbook.md` with exit 1. That is the test: the script refuses rather than half-running.

- [ ] **Step 3: Verify the dry run on a machine that has the tool**

On the CI agent, or after installing `coreos-installer`, run the same command.
Expected: a line `dry run: would upload ...` followed by an image ID on the last line matching `/providers/Microsoft.Compute/images/devbox-fcos-stable-`.

- [ ] **Step 4: Write the pipeline**

```yaml
# pipelines/devbox-os.yml
trigger: none
pr: none
schedules:
  - cron: "0 4 * * 1"
    displayName: weekly OS image refresh
    branches: { include: [main] }
    always: true

jobs:
  - job: publish
    pool: { vmImage: ubuntu-latest }
    steps:
      - script: curl -fsSL https://get.coreos-installer.dev | sh -s -- -p /usr/local/bin
        displayName: install coreos-installer
      - task: AzureCLI@2
        displayName: publish managed image
        inputs:
          azureSubscription: devbox-image
          scriptType: bash
          scriptLocation: inlineScript
          inlineScript: |
            set -euo pipefail
            ./os/build-os-image.sh | tee image-id.txt
      - script: |
          echo "Apply this as os_image_id:"; tail -1 image-id.txt
        displayName: print the image id for Terraform
```

- [ ] **Step 5: Commit**

```bash
git add os/build-os-image.sh pipelines/devbox-os.yml
git commit -m "feat(os): publish the Fedora CoreOS Azure managed image"
```

---

### Task 6: Ignition from Butane

**Files:**
- Create: `os/butane/ucore.bu`, `os/butane/build.sh`
- Create: `host/quadlet/opencode.container`
- Delete: `host/compose.yaml`, `host/bin/oc-image-update`

**Interfaces:**
- Consumes: the scripts in `host/bin/`, copied into the image by the pipeline.
- Produces: `os/butane/ucore.ign`, valid JSON, containing units `oc-secrets.service`, `oc-idle.timer`, `oc-snapshot.timer`, the quadlet `opencode.container`, and `srv-data.mount`.

- [ ] **Step 1: Write the Butane source**

```yaml
# os/butane/ucore.bu
variant: fcos
version: 1.5.0
passwd:
  users:
    - name: core
      ssh_authorized_keys:
        - __SSH_PUBKEY__
storage:
  disks:
    - device: /dev/disk/azure/scsi1/lun0
      wipe_table: false
      partitions:
        - label: data
          number: 1
  filesystems:
    - device: /dev/disk/by-partlabel/data
      format: ext4
      label: data
      wipe_filesystem: false
  files:
    - path: /usr/local/sbin/oc-secrets
      mode: 0755
      contents:
        local: ../../host/bin/oc-secrets
    - path: /usr/local/sbin/oc-acr-login
      mode: 0755
      contents:
        local: ../../host/bin/oc-acr-login
    - path: /usr/local/sbin/oc-idle-check
      mode: 0755
      contents:
        local: ../../host/bin/oc-idle-check
    - path: /usr/local/sbin/oc-snapshot
      mode: 0755
      contents:
        local: ../../host/bin/oc-snapshot
    - path: /usr/local/sbin/oc-tailnet
      mode: 0755
      contents:
        local: ../../host/bin/oc-tailnet
    - path: /usr/local/sbin/oc-tailnet-up
      mode: 0755
      contents:
        local: ../../host/bin/oc-tailnet-up
    - path: /usr/local/sbin/lib-imds.sh
      mode: 0644
      contents:
        local: ../../host/bin/lib-imds.sh
    - path: /etc/devbox/oc-secrets.env
      mode: 0600
      contents:
        inline: |
          VAULT_NAME=__VAULT_NAME__
          ACR_NAME=__ACR_NAME__
    - path: /etc/devbox/oc-idle.env
      mode: 0600
      contents:
        inline: |
          IDLE_MIN=45
          BOOT_GRACE=900
    - path: /etc/devbox/oc-snapshot.env
      mode: 0600
      contents:
        inline: |
          DISK_ID=__DISK_ID__
          RG=__RG__
          SUBSCRIPTION_ID=__SUBSCRIPTION_ID__
systemd:
  units:
    - name: srv-data.mount
      enabled: true
      contents: |
        [Unit]
        Description=Devbox data disk
        [Mount]
        What=/dev/disk/by-label/data
        Where=/srv
        Type=ext4
        Options=defaults,noatime,nofail
        [Install]
        WantedBy=local-fs.target
    - name: oc-secrets.service
      enabled: true
      contents: |
        [Unit]
        Description=Write OpenCode env and ACR auth from Key Vault
        After=network-online.target srv-data.mount
        Wants=network-online.target
        [Service]
        Type=oneshot
        RemainAfterExit=yes
        EnvironmentFile=/etc/devbox/oc-secrets.env
        ExecStart=/usr/local/sbin/oc-secrets
        ExecStart=/usr/local/sbin/oc-acr-login
        [Install]
        WantedBy=multi-user.target
    - name: oc-idle.service
      contents: |
        [Unit]
        Description=Probe for idleness
        After=opencode.service
        [Service]
        Type=oneshot
        EnvironmentFile=/etc/devbox/oc-idle.env
        ExecStart=/usr/local/sbin/oc-idle-check
    - name: oc-idle.timer
      enabled: true
      contents: |
        [Unit]
        Description=Check idleness every 5 minutes
        [Timer]
        OnBootSec=20min
        OnUnitActiveSec=5min
        [Install]
        WantedBy=timers.target
    - name: oc-snapshot.service
      contents: |
        [Unit]
        Description=Snapshot the data disk
        After=srv-data.mount
        [Service]
        Type=oneshot
        EnvironmentFile=/etc/devbox/oc-snapshot.env
        ExecStart=/usr/local/sbin/oc-snapshot
    - name: oc-snapshot.timer
      enabled: true
      contents: |
        [Unit]
        Description=Nightly data disk snapshot
        [Timer]
        OnCalendar=*-*-* 02:00:00 UTC
        Persistent=true
        [Install]
        WantedBy=timers.target
    - name: oc-tailnet.service
      enabled: true
      contents: |
        [Unit]
        Description=Join the tailnet and serve OpenCode over TLS
        After=network-online.target oc-secrets.service
        Wants=network-online.target
        [Service]
        Type=oneshot
        RemainAfterExit=yes
        # Joins only when no state exists, then advertises the loopback port.
        ExecStart=/usr/local/sbin/oc-tailnet-up
        ExecStart=/usr/local/sbin/oc-tailnet
        [Install]
        WantedBy=multi-user.target
    - name: podman-restart.service
      enabled: true
      contents: |
        [Unit]
        Description=Restart podman containers that were running before reboot
        After=podman.socket oc-secrets.service
        [Service]
        Type=oneshot
        ExecStart=/usr/bin/podman start --all
        [Install]
        WantedBy=multi-user.target
```

- [ ] **Step 2: Write the quadlet**

The session database must live on the **data disk**, not a podman named volume.
A named volume sits in `/var/lib/containers/storage` on the OS disk, and the OS
disk is recreated with the VM, so a rebuild would discard every session. That
violates goal 4.

```ini
# host/quadlet/opencode.container
[Unit]
Description=OpenCode dev container
Wants=network-online.target
After=network-online.target oc-secrets.service

[Container]
Image=__ACR__.azurecr.io/devbox:prod
ContainerName=opencode
PublishPort=127.0.0.1:4096:4096
EnvironmentFile=/etc/opencode/env
Environment=HOME=/home/dev
Volume=/srv/repos:/home/dev/repos:Z
# Session DB and global tool state live on the data disk so a VM rebuild keeps
# them. Never a named volume: that lands on the OS disk.
Volume=/srv/opencode/share:/home/dev/.local/share/opencode:Z
Volume=/srv/opencode/config:/home/dev/.config/opencode:Z
Volume=/srv/opencode/state:/home/dev/.local/state/opencode:Z
AutoUpdate=registry

[Service]
Restart=always

[Install]
WantedBy=default.target
```

- [ ] **Step 2b: Assert the session data is on the data disk**

A review of this plan caught a named volume pointing the session DB at the OS
disk. This test keeps that from returning.

```bash
#!/usr/bin/env bash
# host/tests/test_quadlet_persistence.sh
set -euo pipefail
q="$(cd "$(dirname "$0")/../.." && pwd)/host/quadlet/opencode.container"
fail() { echo "FAIL: $1" >&2; exit 1; }
[ -f "$q" ] || fail "quadlet missing"

# Every volume that maps a persistent path must be under /srv, i.e. the data disk.
grep -E '^Volume=' "$q" | while read -r line; do
  src="$(printf '%s' "${line#Volume=}" | cut -d: -f1)"
  case "$src" in
    /srv/*) ;;
    *) fail "persistent volume outside the data disk: $src" ;;
  esac
done

# Named volumes are the specific mistake this guards against.
if grep -Eq '^Volume=[a-z0-9_-]+:/' "$q"; then
  fail "a named volume is used; it would live on the OS disk"
fi

# The session DB path specifically must be persisted.
grep -q '/home/dev/.local/share/opencode' "$q" || fail "session data is not persisted"
echo "persistent data is on the data disk"
```

Run: `chmod +x host/tests/test_quadlet_persistence.sh && ./host/tests/test_quadlet_persistence.sh`
Expected: `persistent data is on the data disk`. Then, to prove the test is not
vacuous, temporarily change one line to
`Volume=opencode-data:/home/dev/.local/share/opencode` and re-run.
Expected: `a named volume is used; it would live on the OS disk`. Revert.

- [ ] **Step 2c: Create the persistent directories at boot**

Add to the Ignition `storage.files` list a systemd unit that creates them with
the container's uid, since they sit on a freshly formatted data disk:

```yaml
    - name: oc-paths.service
      enabled: true
      contents: |
        [Unit]
        Description=Create persistent directory layout on the data disk
        After=srv-data.mount
        Requires=srv-data.mount
        Before=opencode.service
        [Service]
        Type=oneshot
        RemainAfterExit=yes
        ExecStart=/bin/sh -c 'install -d -o 1000 -g 1000 /srv/repos /srv/opencode/share /srv/opencode/config /srv/opencode/state'
        [Install]
        WantedBy=multi-user.target
```

- [ ] **Step 3: Write the compiler with a validation assertion**

```bash
#!/usr/bin/env bash
# Compile Butane to Ignition, substituting placeholders, then assert the output
# is Ignition rather than YAML wearing a .ign extension.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
: "${VAULT_NAME:?}" "${ACR_NAME:?}" "${DISK_ID:?}" "${RG:?}" "${SUBSCRIPTION_ID:?}" "${SSH_PUBKEY:?}"
out="${1:-$here/ucore.ign}"

tmp="$(mktemp)"
sed -e "s|__VAULT_NAME__|${VAULT_NAME}|g" \
    -e "s|__ACR_NAME__|${ACR_NAME}|g" \
    -e "s|__ACR__|${ACR_NAME}|g" \
    -e "s|__DISK_ID__|${DISK_ID}|g" \
    -e "s|__RG__|${RG}|g" \
    -e "s|__SUBSCRIPTION_ID__|${SUBSCRIPTION_ID}|g" \
    -e "s|__SSH_PUBKEY__|${SSH_PUBKEY}|g" \
    "$here/ucore.bu" > "$tmp"

podman run --interactive --rm quay.io/coreos/butane:release --pretty --strict < "$tmp" > "$out"
rm "$tmp"

jq -e '.ignition.version' "$out" >/dev/null || { echo "not valid ignition" >&2; exit 1; }
jq -e '.systemd.units | map(.name) | index("oc-idle.timer")' "$out" >/dev/null \
  || { echo "idle timer missing" >&2; exit 1; }
echo "ignition ok: $out"
```

- [ ] **Step 4: Prove the assertion is not vacuous**

Run with the required variables set: `./os/butane/build.sh /tmp/ok.ign`
Expected: `ignition ok: /tmp/ok.ign`.

Then temporarily replace the `podman run` line with `cat "$tmp" > "$out"` and
re-run. Expected: `not valid ignition` with exit 1. Restore the line.

- [ ] **Step 4b: Assert every baked-in script is present**

Butane fails the build on a missing `local:` file, so this guards the case where
a unit references a path nobody copied in.

```bash
#!/usr/bin/env bash
# os/butane/tests/test_units_have_scripts.sh
set -euo pipefail
ign="${1:?usage: test_units_have_scripts.sh <ign>}"
fail() { echo "FAIL: $1" >&2; exit 1; }
for p in /usr/local/sbin/oc-secrets /usr/local/sbin/oc-acr-login \
         /usr/local/sbin/oc-idle-check /usr/local/sbin/oc-snapshot \
         /usr/local/sbin/oc-tailnet /usr/local/sbin/oc-tailnet-up \
         /usr/local/sbin/lib-imds.sh; do
  jq -e --arg p "$p" '.storage.files | map(.path) | index($p)' "$ign" >/dev/null \
    || fail "not baked into the image: $p"
done
# Every ExecStart must point at a path the config actually provides.
for exe in $(jq -r '.systemd.units[]?.contents // empty' "$ign" \
             | grep -oE '^ExecStart=[^ ]+' | cut -d= -f2 | sort -u); do
  jq -e --arg p "$exe" '.storage.files | map(.path) | index($p)' "$ign" >/dev/null \
    || fail "unit runs a missing executable: $exe"
done
echo "all units reference baked-in scripts"
```

Run: `chmod +x os/butane/tests/test_units_have_scripts.sh && ./os/butane/tests/test_units_have_scripts.sh /tmp/ok.ign`
Expected: `all units reference baked-in scripts`. If it reports a missing
executable, add that file to the `storage.files` list and rebuild.

- [ ] **Step 5: Delete the superseded files**

```bash
git rm host/compose.yaml host/bin/oc-image-update
```

- [ ] **Step 6: Commit**

```bash
git add os/butane host/quadlet host/bin
git commit -m "feat(os): ignition config and podman quadlet replacing compose"
```

---

### Task 7: Idempotent tailnet join

**Files:**
- Modify: `host/bin/oc-tailnet-up`, `host/bin/oc-tailnet`
- Create: `host/tests/test_tailnet_up.sh`

**Interfaces:**
- Consumes: `AUTH_KEY_FILE` (default `/etc/devbox/tailscale-authkey`) or `TS_AUTHKEY_SECRET` for a Key Vault name.
- Produces: a joined node on first boot, and a no-op on subsequent boots.

- [ ] **Step 1: Write the failing test**

```bash
#!/usr/bin/env bash
# Proves the join is idempotent: a second run must not re-auth.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/state" "$tmp/devbox"
printf 'tskey-test\n' > "$tmp/devbox/tailscale-authkey"
: > "$tmp/up-calls"
cat > "$tmp/bin/tailscale" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == "up" ]] && { echo "$*" >> "$UP_CALLS"; exit 0; }
exit 0
EOF
chmod +x "$tmp/bin/tailscale"

export PATH="$tmp/bin:$PATH" STATE_DIR="$tmp/state" \
       AUTH_KEY_FILE="$tmp/devbox/tailscale-authkey" UP_CALLS="$tmp/up-calls"

"$here/../bin/oc-tailnet-up"
[ "$(wc -l < "$tmp/up-calls")" -eq 1 ] || { echo "FAIL: first boot did not join"; exit 1; }

: > "$tmp/state/tailscaled.state"
"$here/../bin/oc-tailnet-up"
[ "$(wc -l < "$tmp/up-calls")" -eq 1 ] || { echo "FAIL: rejoined with existing state"; exit 1; }

echo "tailnet join is idempotent"
```

- [ ] **Step 2: Run to verify it passes as a regression guard**

Run: `chmod +x host/tests/test_tailnet_up.sh && ./host/tests/test_tailnet_up.sh`
Expected: `tailnet join is idempotent`. The behaviour exists; the test locks it in before Task 7 changes the key source.

- [ ] **Step 3: Allow the key to come from Key Vault**

In `oc-tailnet-up`, before the state check:

```bash
# The key may arrive from Key Vault at boot instead of Ignition, which keeps it
# out of custom_data.
if [ ! -r "$AUTH_KEY_FILE" ] && [ -n "${TS_AUTHKEY_SECRET:-}" ]; then
  install -d -m 0700 "$(dirname "$AUTH_KEY_FILE")"
  # shellcheck source=lib-imds.sh
  . "$(dirname "$0")/lib-imds.sh"
  kv_secret "${VAULT_NAME:?}" "$TS_AUTHKEY_SECRET" > "$AUTH_KEY_FILE"
  chmod 0600 "$AUTH_KEY_FILE"
fi
```

- [ ] **Step 4: Re-run the test**

Run: `./host/tests/test_tailnet_up.sh`
Expected: `tailnet join is idempotent`

- [ ] **Step 5: Commit**

```bash
git add host/bin host/tests
git commit -m "feat(host): tailnet key from Key Vault, join stays idempotent"
```

---

### Task 8: Terraform boots from the managed OS image

**Files:**
- Rewrite: `terraform/main.tf`, `terraform/variables.tf`
- Create: `terraform/tests/no_public_ip.sh`

**Interfaces:**
- Consumes: `os_image_id`, the managed image ID printed by Task 5.
- Produces: a VM with no public IP, system-assigned identity, Ignition as `custom_data`, a data disk with `prevent_destroy`, Key Vault, and least-privilege role assignments.

- [ ] **Step 1: Write the ingress policy test**

```bash
#!/usr/bin/env bash
# terraform/tests/no_public_ip.sh - asserts no public ingress in a plan.
set -euo pipefail
plan="${1:?usage: no_public_ip.sh plan.json}"
fail() { echo "FAIL: $1" >&2; exit 1; }

if jq -e '[paths(scalars) as $p | select($p[-1] == "public_ip_address_id")
          | getpath($p) | select(. != null)] | length > 0' "$plan" >/dev/null 2>&1; then
  fail "a public IP is attached"
fi

if jq -e '[.. | objects | select(has("security_rule")) | .security_rule[]?
          | select(.direction == "Inbound" and .access == "Allow"
                   and (.source_address_prefix == "Internet" or .source_address_prefix == "*"))]
          | length > 0' "$plan" >/dev/null 2>&1; then
  fail "an inbound allow rule reaches the internet"
fi

echo "no public ingress"
```

- [ ] **Step 2: Run it against a plan**

Run: `terraform -chdir=terraform init -input=false && terraform -chdir=terraform plan -var os_image_id="$OS_IMAGE_ID" -out=tfplan && terraform -chdir=terraform show -json tfplan > /tmp/plan.json && ./terraform/tests/no_public_ip.sh /tmp/plan.json`
Expected: `no public ingress`. If Terraform is unavailable here, run it in CI and record the output; do not mark the step done without evidence.

- [ ] **Step 3: Replace the image source and custom_data**

In `terraform/main.tf`, on `azurerm_linux_virtual_machine.this`, replace the
`source_image_reference` block, the `custom_data` block, `admin_username`, the
`admin_ssh_key` block and `disable_password_authentication` with:

```hcl
  admin_username = "core"
  source_image_id = var.os_image_id

  # Ignition, not cloud-init. Fedora CoreOS consumes Ignition only.
  custom_data = base64encode(file("${path.module}/../os/butane/ucore.ign"))
```

`core` is the Fedora CoreOS default user, and Ignition sets its authorized_keys,
so there is no `admin_ssh_key` block and no password auth to disable.

Add to `terraform/variables.tf`:

```hcl
variable "os_image_id" {
  type        = string
  description = "Managed image ID of the published ucore image. Never a marketplace URN."
  validation {
    condition     = can(regex("^/subscriptions/.+/providers/Microsoft.Compute/images/.+$", var.os_image_id))
    error_message = "Must be a managed image resource ID, not a marketplace reference."
  }
}
```

Also remove the now-unused `ssh_public_key` variable and its `admin_ssh_key`
usage, and note in `variables.tf` that the operator's key lives in Ignition.

- [ ] **Step 4: Re-run the policy test and assert no Ubuntu traces**

Run: `terraform -chdir=terraform plan -var os_image_id="$OS_IMAGE_ID" -out=tfplan && terraform -chdir=terraform show -json tfplan > /tmp/plan.json && ./terraform/tests/no_public_ip.sh /tmp/plan.json`
Expected: `no public ingress`

Run: `grep -Rn "Canonical\|ubuntu" terraform/ || echo "no ubuntu references"`
Expected: `no ubuntu references`

- [ ] **Step 5: Commit**

```bash
git add terraform
git commit -m "feat(terraform): boot from the published ucore image with Ignition"
```

---

### Task 9: Data disk protection and restore drill

**Files:**
- Modify: `terraform/main.tf`
- Create: `terraform/tests/data_disk_protected.sh`, `docs/runbook.md`

**Interfaces:**
- Produces: a documented, rehearsed restore procedure and a test that keeps `prevent_destroy` on the data disk.

- [ ] **Step 1: Write the protection test**

```bash
#!/usr/bin/env bash
# terraform/tests/data_disk_protected.sh
set -euo pipefail
fail() { echo "FAIL: $1" >&2; exit 1; }
here="$(cd "$(dirname "$0")/.." && pwd)"
awk '/resource "azurerm_managed_disk" "data"/,/^}/' "$here/main.tf" \
  | grep -q 'prevent_destroy = true' || fail "data disk is not destroy-protected"
echo "data disk is destroy-protected"
```

- [ ] **Step 2: Run it**

Run: `chmod +x terraform/tests/data_disk_protected.sh && ./terraform/tests/data_disk_protected.sh`
Expected: `data disk is destroy-protected`

- [ ] **Step 3: Write the restore section of the runbook**

```markdown
## Restore the data disk

1. Deallocate the VM: `az vm deallocate -g rg-devbox-oc -n vm-devbox-oc`
2. Detach: `az vm disk detach -g rg-devbox-oc --vm-name vm-devbox-oc --name disk-devbox-oc-data`
3. List snapshots, newest last:
   `az snapshot list -g rg-devbox-oc --query "sort_by([].{n:name,t:timeCreated},&t)[-5:]" -o table`
4. Create a disk from the chosen snapshot:
   `az disk create -g rg-devbox-oc -n disk-devbox-oc-restore --source <snapshot-id>`
5. Attach the restore disk in place of the original, boot, and verify `/srv`.
6. Promote only after verification.

Never remove the original disk until the restored copy has been read.
```

- [ ] **Step 4: Rehearse steps 1 to 3 against a scratch resource group**

Run the three commands against a throwaway group holding one test disk and one
snapshot. Expected: the snapshot appears in the listing. Put that output in the
commit message. Do not run steps 4 to 6 against the live box.

- [ ] **Step 5: Commit**

```bash
git add terraform/tests docs/runbook.md
git commit -m "docs: data disk restore drill and destroy protection test"
```

---

### Task 10: Scheduled start without scheduled stop

**Files:**
- Modify: `terraform/main.tf`, `terraform/schedule.tf`
- Create: `terraform/tests/no_scheduled_stop.sh`

- [ ] **Step 1: Write the failing test**

```bash
#!/usr/bin/env bash
# terraform/tests/no_scheduled_stop.sh
set -euo pipefail
fail() { echo "FAIL: $1" >&2; exit 1; }
here="$(cd "$(dirname "$0")/.." && pwd)"
if grep -rq 'dev_test_global_vm_shutdown_schedule\|daily_recurrence_time' "$here"; then
  fail "a scheduled shutdown exists; the idle gate owns shutdown"
fi
grep -q 'azurerm_logic_app_workflow' "$here/schedule.tf" || fail "no scheduled start"
echo "start is scheduled, stop is not"
```

- [ ] **Step 2: Run it to verify it fails**

Run: `chmod +x terraform/tests/no_scheduled_stop.sh && ./terraform/tests/no_scheduled_stop.sh`
Expected: FAIL with `a scheduled shutdown exists`, because the scaffold still has that resource in `main.tf`.

- [ ] **Step 3: Remove the shutdown schedule**

Delete the entire `azurerm_dev_test_global_vm_shutdown_schedule` resource from
`terraform/main.tf`, along with the `schedule_stop_utc` variable. Leave
`schedule.tf` with the Logic App and its `start` action.

- [ ] **Step 4: Re-run the test**

Run: `./terraform/tests/no_scheduled_stop.sh`
Expected: `start is scheduled, stop is not`

- [ ] **Step 5: Commit**

```bash
git add terraform
git commit -m "feat(terraform): scheduled start only; idle gate owns shutdown"
```

---

### Task 11: Operator wake-and-connect wrapper

**Files:**
- Create: `tools/oc`, `tools/tests/test_oc.sh`

**Interfaces:**
- Consumes: `OC_VM`, `OC_RG`, `OC_URL`.
- Produces: starts the VM, polls health, then hands over to the TUI. `--print-server` prints the URL instead of exec'ing.

- [ ] **Step 1: Write the failing test**

```bash
#!/usr/bin/env bash
# tools/tests/test_oc.sh - proves the wrapper starts, waits, then execs.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
: > "$tmp/log"
cat > "$tmp/bin/az" <<'EOF'
#!/usr/bin/env bash
echo "az $*" >> "$LOG"
[[ "$*" == *"get-instance-view"* ]] && echo "PowerState/deallocated"
exit 0
EOF
cat > "$tmp/bin/curl" <<'EOF'
#!/usr/bin/env bash
echo "curl" >> "$LOG"
n=$(grep -c '^curl$' "$LOG" 2>/dev/null || true)
[ "${n:-0}" -ge "${HEALTHY_AFTER:-2}" ]
EOF
cat > "$tmp/bin/opencode" <<'EOF'
#!/usr/bin/env bash
echo "opencode $*" >> "$LOG"
EOF
chmod +x "$tmp/bin/"*

PATH="$tmp/bin:$PATH" LOG="$tmp/log" OC_VM=vm OC_RG=rg OC_URL=https://oc.test \
  HEALTHY_AFTER=3 POLL_INTERVAL=0 "$here/../oc"

grep -q 'az vm start' "$tmp/log" || { echo "FAIL: did not start the VM"; exit 1; }
[ "$(grep -c '^curl$' "$tmp/log")" -ge 3 ] || { echo "FAIL: did not poll to health"; exit 1; }
grep -q 'opencode --server https://oc.test' "$tmp/log" || { echo "FAIL: wrong server arg"; exit 1; }
echo "wrapper starts, waits, then execs"
```

- [ ] **Step 2: Run it to verify it fails**

Run: `chmod +x tools/tests/test_oc.sh && ./tools/tests/test_oc.sh`
Expected: FAIL with `FAIL: did not start the VM`, because `tools/oc` does not exist.

- [ ] **Step 3: Write the wrapper**

```bash
#!/usr/bin/env bash
# Start the devbox if deallocated, wait until OpenCode answers, then hand over to
# the TUI pointed at the tailnet URL. Cold start is 60 to 120 seconds.
set -euo pipefail

: "${OC_VM:?}" "${OC_RG:?}" "${OC_URL:?}"
POLL_INTERVAL="${POLL_INTERVAL:-5}"
TIMEOUT="${TIMEOUT:-300}"
PRINT_ONLY=0
[ "${1:-}" = "--print-server" ] && PRINT_ONLY=1

power="$(az vm get-instance-view -g "$OC_RG" -n "$OC_VM" \
  --query "instanceView.statuses[?starts_with(code,'PowerState/')].code | [0]" \
  -o tsv 2>/dev/null || echo unknown)"

case "$power" in
  PowerState/running) ;;
  PowerState/deallocated|PowerState/stopped|unknown)
    echo "starting ${OC_VM} (cold start is 60 to 120s)" >&2
    az vm start -g "$OC_RG" -n "$OC_VM" --only-show-errors >&2
    ;;
  *) echo "unexpected power state: $power" >&2; exit 1 ;;
esac

deadline=$(( $(date +%s) + TIMEOUT ))
until curl -fsS -m 5 -o /dev/null "${OC_URL}/api/info"; do
  [ "$(date +%s)" -gt "$deadline" ] && { echo "timed out waiting for ${OC_URL}" >&2; exit 1; }
  sleep "$POLL_INTERVAL"
done

if [ "$PRINT_ONLY" = "1" ]; then echo "$OC_URL"; exit 0; fi
exec opencode --server "$OC_URL"
```

- [ ] **Step 4: Run the test**

Run: `./tools/tests/test_oc.sh`
Expected: `wrapper starts, waits, then execs`

- [ ] **Step 5: Commit**

```bash
git add tools
git commit -m "feat(tools): wake-and-connect wrapper with health polling"
```

---

### Task 12: Documentation and vendoring

**Files:**
- Create: `README.md`, `CHANGELOG.md`, `docs/vendoring.md`
- Modify: `docs/runbook.md`
- Create: `tests/docs_complete.sh`

- [ ] **Step 1: Write the failing documentation check**

```bash
#!/usr/bin/env bash
# tests/docs_complete.sh - a doc set missing the recovery path is incomplete.
set -euo pipefail
fail() { echo "FAIL: $1" >&2; exit 1; }
root="$(cd "$(dirname "$0")/.." && pwd)"
for f in README.md CHANGELOG.md docs/runbook.md docs/vendoring.md; do
  [ -s "$root/$f" ] || fail "missing or empty: $f"
done
for topic in restore rollback tailnet snapshot vendoring; do
  grep -riq "$topic" "$root/docs" "$root/README.md" || fail "no documentation for: $topic"
done
echo "docs complete"
```

- [ ] **Step 2: Run it to verify it fails**

Run: `chmod +x tests/docs_complete.sh && ./tests/docs_complete.sh`
Expected: FAIL with `missing or empty: README.md`

- [ ] **Step 3: Write the four documents**

`README.md` states the architecture in one paragraph, the three update cadences,
the idle contract **including what is not protected**, and how to run every test
suite.

`CHANGELOG.md` opens with an Unreleased section listing the twelve tasks.

`docs/runbook.md` covers restore, rollback of both layers, tailnet rejoin, and
snapshot pruning.

`docs/vendoring.md` lists what moves into the existing Azure DevOps repo: keep
`image/`, `os/`, `host/`, `terraform/`, `pipelines/`, `tools/`, `tests/`. Do not
move terraform state, `.env` files, personal `opencode.json`, or this repo's git
history.

- [ ] **Step 4: Re-run the check**

Run: `./tests/docs_complete.sh`
Expected: `docs complete`

- [ ] **Step 5: Commit**

```bash
git add README.md CHANGELOG.md docs tests
git commit -m "docs: architecture, runbook, vendoring, and doc completeness check"
```

---

## Verification

Run every suite the repo owns, in one place:

```bash
for t in host/tests/*.sh tools/tests/*.sh terraform/tests/*.sh \
         image/tests/*.sh os/butane/tests/*.sh tests/*.sh; do
  echo "== $t"
  "$t" || exit 1
done
./image/smoke.sh devbox:local
```

Expected: every suite prints its success line, and `smoke ok: devbox:local`.
