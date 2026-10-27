# Devbox follow-on plan: deployment readiness

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans.

**Goal:** Take the repo from "validates" to "an operator can deploy it without guessing", and close the one parked review finding.

**Spec:** `docs/superpowers/specs/2026-10-27-devbox-opencode-design.md`
**Prior plan:** `docs/superpowers/plans/2026-10-27-devbox-implementation.md` (tasks 1 to 12, complete)

## Why this plan exists

Tasks 1 to 12 built and verified every component. Three gaps remain that no task owned:

1. The repo has no documented, copyable way to supply the eight required Terraform variables. An operator must read `variables.tf` and infer.
2. The runbook covers recovery, not first deployment. The path from `git clone` to "TUI connected" is undocumented, including the Ignition regeneration that the placeholder precondition now blocks on.
3. `tests/verify.sh` runs locally only. A vendored repo needs it as a PR gate, or the invariants decay.

Plus one parked review finding: a failed Key Vault fetch leaves the container running without auth and without idle shutdown.

## Batches

Batch A needs no Azure access and no container engine. Batch B requires the operator's subscription. Batch C is hygiene.

| Batch | Tasks | Needs |
|---|---|---|
| A | A1 tfvars, A2 first-deploy runbook, A3 verify pipeline, A4 fail-closed bootstrap | nothing external |
| B | B1 publish OS image, B2 apply, B3 build container, B4 first-boot check, B5 client pairing | Azure subscription, container engine |
| C | C1 licence and changelog close-out | nothing external |

---

## Batch A

### A1: Supply the required variables without reading source

**Files:** `terraform/terraform.tfvars.example` (create), `.gitignore` (modify), `terraform/tests/variables_documented.sh` (create)

**Interfaces:** produces a file the operator copies to `terraform/terraform.tfvars`.

- [ ] **Step 1: Write the failing test**

```bash
#!/usr/bin/env bash
# Every variable with no default must appear in terraform.tfvars.example, or an
# operator cannot know it is required until plan fails.
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL: $1" >&2; exit 1; }

example="$here/terraform.tfvars.example"
[ -s "$example" ] || fail "terraform.tfvars.example missing"

# A variable block with no `default` line is required.
required="$(awk '
  /^variable "/ { name=$2; gsub(/"/, "", name); has_default=0; inblock=1; next }
  inblock && /^[[:space:]]*default[[:space:]]*=/ { has_default=1 }
  inblock && /^}/ { if (!has_default) print name; inblock=0 }
' "$here/variables.tf")"

[ -n "$required" ] || fail "no required variables found; the awk scan is broken"

for v in $required; do
  grep -qE "^[[:space:]]*${v}[[:space:]]*=" "$example" \
    || fail "required variable not in tfvars.example: $v"
done

echo "all required variables documented"
```

- [ ] **Step 2: Run it to verify it fails**

Run: `chmod +x terraform/tests/variables_documented.sh && ./terraform/tests/variables_documented.sh`
Expected: `FAIL: terraform.tfvars.example missing`

- [ ] **Step 3: Write `terraform/terraform.tfvars.example`**

Every line commented out, because a half-filled tfvars that silently keeps a
placeholder is worse than an obvious missing file. Required variables first, with
the failure each one causes if wrong.

- [ ] **Step 4: Add tfvars and plans to `.gitignore`**

`terraform/*.tfvars`, `!/terraform/*.tfvars.example`, `*.tfplan`, `*.plan.json`.

- [ ] **Step 5: Run the test to verify it passes**

Run: `./terraform/tests/variables_documented.sh`
Expected: `all required variables documented`

- [ ] **Step 6: Wire into the gate, commit**

`run "variables documented" ./terraform/tests/variables_documented.sh`

Commit: `feat(terraform): document the required variables in a copyable example`

### A2: First-deployment runbook

**Files:** `docs/runbook.md` (modify), `tests/docs_complete.sh` (modify)

**Interfaces:** consumes the deployment order the pipelines assume.

- [ ] **Step 1: Extend the doc test to require the deployment path**

Add topics `first deploy`, `regenerate`, `pair`.

- [ ] **Step 2: Run it, expect failure**

Run: `./tests/docs_complete.sh`
Expected: `FAIL: no documentation for: first deploy`

- [ ] **Step 3: Write the section**

Covers, in order: copy tfvars, publish the OS image (`pipelines/devbox-os.yml`),
set `os_image_id` from its output, regenerate Ignition with real values
(`./os/butane/build.sh`), `terraform apply`, confirm the placeholder precondition
passes, build the container image, verify first boot, pair the desktop app.
State the two commands an operator runs to confirm success at each stage.

- [ ] **Step 4: Verify and commit**

Run: `./tests/docs_complete.sh` → `docs complete`
Commit: `docs: first deployment path from clone to connected client`

### A3: Run the gate on every pull request

**Files:** `pipelines/devbox-verify.yml` (create), `pipelines/tests/test_pipeline_shape.sh` (create)

**Interfaces:** produces a pipeline that runs `tests/verify.sh` on PRs touching the subtree.

- [ ] **Step 1: Write the failing test**

Asserts the YAML parses, triggers on `pr`, has no `azureSubscription` input (the
gate must need no credentials), and invokes `tests/verify.sh`.

- [ ] **Step 2: Run it, expect failure**

Expected: `FAIL: pipelines/devbox-verify.yml missing`

- [ ] **Step 3: Write the pipeline**

`pr:` trigger on the subtree paths, `ubuntu-latest`, install shellcheck via apt,
run `./tests/verify.sh`. No service connection.

- [ ] **Step 4: Verify and commit**

Run: `./pipelines/tests/test_pipeline_shape.sh` → passes
Commit: `feat(pipeline): gate pull requests on the verification suite`

### A4: A failed bootstrap must not serve traffic

Closes the parked review finding.

**Files:** `host/quadlet/opencode.container` (modify), `os/butane/ucore.bu` (modify), `host/tests/test_quadlet_persistence.sh` (modify), `os/butane/ucore.ign` (regenerate)

**Interfaces:** the quadlet gains a hard dependency on the secret unit.

- [ ] **Step 1: Write the failing test**

Extend the quadlet test: assert the file contains `Requires=oc-secrets.service`, so
a Key Vault failure prevents the container starting rather than running it without
credentials.

- [ ] **Step 2: Run it, expect failure**

Expected: `FAIL: quadlet does not require oc-secrets.service`

- [ ] **Step 3: Add `Requires=` and regenerate**

In the quadlet `[Unit]` section add `Requires=oc-secrets.service`. Rationale: the
project fails closed everywhere else, and a box serving without auth or idle
shutdown is worse than one that refuses to start. Regenerate `ucore.ign`.

- [ ] **Step 4: Verify, run the gate, commit**

Run: `./tests/verify.sh` → all pass
Commit: `fix(host): fail closed when the secret bootstrap fails`

---

## Batch B: operator-dependent deployment

These need a real subscription and a container engine. They are steps for the
operator to run, not agent tasks, because every one of them mutates live Azure
state.

| Step | Command | Success looks like |
|---|---|---|
| B1 publish OS image | run `pipelines/devbox-os.yml`, or `./os/build-os-image.sh` | last stdout line is a `/providers/Microsoft.Compute/images/...` id |
| B2 apply | `terraform -chdir=terraform apply -var-file=terraform.tfvars` | precondition passes, VM created, no public IP in the plan |
| B3 build container | run `pipelines/devbox-image.yml` | `:prod` exists, smoke gate passed, digest recorded |
| B4 first boot | `sudo journalctl -u oc-secrets -u oc-tailnet -u opencode` on the host | all three active, `podman ps` shows the container healthy |
| B5 pair client | `opencode pair --url https://<host>.<tailnet>.ts.net` | desktop app connects, TUI connects with `--server` |

Then confirm the cost model works: leave the box alone for 50 minutes with no
session and verify it deallocates (`oc-idle-check` logs "idle for 45m").

## Batch C: close-out

### C1: Licence and final changelog

Add a licence, and move the `Unreleased` entries to a dated release once Batch B
passes. Per the repo standards, open work items belong in the forge's tracker; when
this is vendored, these batches become issues there.
