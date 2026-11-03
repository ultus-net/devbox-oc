# Can the OpenCode server be serverless?

Verdict: **the server cannot scale to zero on Container Apps, but most of the work
can move off the VM.** The blocker is one SQLite constraint, not a preference, and
it does not apply to the job containers.

Measured 2026-11-03 and 2026-11-04 against OpenCode 2.1.4 (the version the image
pins, `image/Dockerfile:27`) and 2.2.1, plus Microsoft Learn and the Azure retail
prices API. Region `newzealandnorth`, 730 hours/month, 1 USD = 1.7773 NZD.

## How the OpenCode claims were measured

The block below is the script that was run, from the repo root, on the shipped
2.1.4. It writes only under `.scratch/`, which `.gitignore:18` ignores. It was run
as written and its output is summarized after it.

```sh
S=.scratch/headless; PORT=5031; PW=pw-restart-proof
rm -rf "$S"; mkdir -p "$S/data"
serve() {
  XDG_DATA_HOME="$S/data" XDG_CONFIG_HOME="$S/cfg" HOME="$S" \
    OPENCODE_SERVER_PASSWORD="$PW" opencode serve --port "$PORT" \
    --hostname 127.0.0.1 &
  PID=$!; sleep 20
}

serve
ls "$S/data/opencode/"                       # opencode.db -wal -shm
python3 -c "import sqlite3,sys; print(sqlite3.connect(sys.argv[1]) \
  .execute('PRAGMA journal_mode').fetchone()[0])" "$S/data/opencode/opencode.db"
ps -o rss= -p "$PID"                         # KiB

curl -s -u "opencode:$PW" -X POST -H 'content-type: application/json' \
  -d '{"title":"restart-proof"}' "http://127.0.0.1:$PORT/api/session"
kill "$PID"; wait "$PID" 2>/dev/null || true

serve
curl -s -u "opencode:$PW" "http://127.0.0.1:$PORT/api/session"   # same id
curl -s -u "opencode:$PW" "http://127.0.0.1:$PORT/openapi.json" \
  | python3 -c "import json,sys; d=json.load(sys.stdin); print(len(d['paths']))"
kill "$PID"; wait "$PID" 2>/dev/null || true
```

Output, in order and lightly reflowed: the data dir contains `log opencode.db
opencode.db-shm opencode.db-wal repos`, then `wal`, then `143888` KiB (140.5 MiB),
then a session with id `ses_e5ec7dd9affevMf6tQmNgtgez1`, then **the same id after
the restart**, then `134`. So WAL is forced, and session state survives a process
restart. A separate run of the same block printed `144256`, and the `134` is the
OpenAPI path count.

Authentication was checked separately on the shipped 2.1.4, because a password
variable that the binary ignores would make the `-u` flags prove nothing:
`OPENCODE_SERVER_PASSWORD=sekret-xyz` gives 401 with no credentials, 401 with a
wrong password, and 200 with the right one.

Start time needs its own harness, because it is a duration rather than a file
state. It polls the server's first log line and subtracts the exec timestamp:

| Run | Time to bind | RSS |
|---|---|---|
| data-dir cold, no DB | 0.14 s | 146 MiB |
| data-dir warm, DB present | 0.12 s | 147 MiB |

RSS varies run to run: four measurements on an idle empty data dir span 134 to 147
MiB, so quote that range rather than a single figure. Bind time spans 0.12 to
0.14 s across the two runs above, and is reported as "under 0.2 s" wherever a
round figure is needed.

The October cost figures are not reproduced above. They come from the plan's own
CostManagement query, documented at `docs/deployment-plan.md:235-246`, re-run here
for October 2026 grouped by `ResourceId` and by `Meter`. Reuse that recipe rather
than a second one.

## The blocker, in one chain

| Link | Evidence |
|---|---|
| OpenCode forces SQLite WAL mode | Measured above on 2.1.4 and on 2.2.1: a fresh data dir gains `-wal` and `-shm` on start, and `PRAGMA journal_mode` returns `wal` |
| WAL needs shared memory on one host | sqlite.org/wal.html: "All processes using a database must be on the same host computer; WAL does not work over a network filesystem. This is because WAL requires all processes to share a small amount of memory" |
| Container Apps has no block-disk volume | The storage-mounts page's permanent-storage row has one entry, Azure Files. "Azure Container Apps doesn't support mounting file shares from Azure NetApp Files or Azure Blob Storage" |
| Azure Files cannot carry the wal-index | The wal-index is an `mmap`ed region shared between processes. NFS Azure Files *is* mountable by Container Apps (the docs list both `AzureFile` and `NfsAzureFile`), but it still fails: SQLite's requirement is shared memory on one host, and NFS offers no shared `mmap` region. The SMB locking objection is therefore the wrong argument, and NFS does not fix it |

So an ACA-hosted server has nowhere durable to put `opencode.db`. Ephemeral
storage is per-replica and dies with the replica, bounded at 8 GiB above 1 vCPU.

**What is not the blocker.** Session state survives a restart, measured above.
Scale-to-zero would be safe given block storage. Container Apps does not offer
block storage and a VM does. That is the whole difference.

**Workarounds, rejected:**

- `PRAGMA locking_mode=EXCLUSIVE` does allow WAL without shared memory
  (sqlite.org/wal.html §8), but it must be set before the first database access,
  OpenCode exposes no such setting, and it forecloses ever having a second replica.
  It would require forking OpenCode.
- Copy the DB down at start and sync back at shutdown. There is nowhere to copy it
  to, because the storage account is deleted by operator decision. Even with one,
  the sync-back depends on a graceful shutdown, and an eviction mid-write leaves a
  diverged database that cannot be merged.

## What the measurements change

**One headless server is small, and starts instantly.** 134 to 147 MiB RSS idle, and
under 0.2 s to bind. The 341 MiB figure in the current plan
(`docs/deployment-plan.md:328-330`) is the average across 16 interactive instances
on a workstation, which is a different object.

That reopens the sizing question. One server plus the Hermes gateway plus the host
is roughly **0.6 to 1.2 GiB**, which fits `B2als_v2` at 4 GiB without the 8 GiB the
current plan buys.

**The client is HTTP, and the real API is at `/api`.** Correcting two errors in an
earlier draft of this doc:

- There is no `opencode attach` subcommand. `opencode --help` on 2.1.4 and on 2.2.1
  lists `serve`, `api`, `run`, `session`, `service`, `pair`, `mini`, and no
  `attach`. A client reaches a remote server with `opencode pair --url <url>`, which
  prints a one-time `.../auth/connect/<token>` link, measured.
- `GET /event` and `GET /global/event` are not the API paths. They return the web
  app's HTML. The OpenAPI document has no `/global/*` route at all, the real paths
  are `GET /api/event` and `POST /api/session`, and the document describes itself as
  an "Experimental HttpApi surface for selected instance routes".

ADR `0001-aca-over-vm.md` rejected Container Apps partly because "ingress is
HTTP-only so no IDE can attach over SSH". That text is in this repo at
`docs/superpowers/specs/2026-10-27-devbox-opencode-design.md:107`, and the ADR itself
lives in the ADO repo `csh-dev` at `docs/decisions/0001-aca-over-vm.md`
(`docs/deployment-plan.md:26`). The justification does not hold for OpenCode: the
client is HTTP with SSE, which is what ACA ingress terminates. The experimental
label is a real risk, but it is not an SSH gap.

## The shapes, priced

Fixed lines are identical in every VM shape: E10 data disk 24.36, disk transactions
0 to 4, P6 OS disk 18.14, ACR Basic 9.01, Key Vault 0.03, snapshots 2.1 to 10.6.
**Fixed subtotal 53.64 to 66.14 NZD/month.**

| Shape | VM compute | Static total | With 0 job-hours |
|---|---|---|---|
| A: `B2as_v2` pinned, everything local | 129.48 | 183.12 to 195.62 | same |
| **B: `B2als_v2` anchor plus ACA jobs** | 64.74 | **118.38 to 130.88** | floor |
| B variant: `B2ats_v2` 1 GiB | 16.22 | 69.86 to 82.36 | rejected, see below |
| C: ACA server scale-to-zero plus jobs | 0 | 53.64 to 66.14 | **do not build, fails on WAL** |

Shape C's row is the fixed floor only, which is why it looks cheapest. It is the
shape that cannot run.

ACA rates measured for `newzealandnorth` from the retail API: vCPU active 0.000036
USD/s (0.2303 NZD per vCPU-hour), memory active 0.000005 USD/s per GiB (0.0320 NZD
per GiB-hour), idle 0.000005 for both. Free grant per subscription per month:
180,000 vCPU-seconds and 360,000 GiB-seconds, which is **25 job-hours** at
2 vCPU / 4 GiB.

Shape B is a floor, not a total. Add job hours at 0.5886 NZD each beyond the free
grant, each cell rounded independently:

| Job-hours/month | Billable after grant | Job cost | Shape B total |
|---|---|---|---|
| 0 to 25 | 0 | 0.00 | 118.38 to 130.88 |
| 50 | 25 | 14.72 | 133.10 to 145.60 |
| 100 | 75 | 44.15 | 162.53 to 175.03 |
| 135 | 110 | 64.75 | 183.13 to 195.63 |
| 245 | 220 | 129.49 | 247.87 to 260.37 |

Break-even is **135 job-hours a month against `B2as_v2`** (135 total, of which 110
are billable). At that point B costs the same as A and buys nothing. Below it, B
wins by up to 64.74 NZD/month, about 777 NZD/year. One developer doing 2 to 4 hours
of attended agent work a day is 40 to 80 hours a month, of which the fan-out
portion is a fraction, so 50 to 100 job-hours is the plausible band and B lands at
133 to 175 NZD.

`B2ats_v2` is rejected because 1 GiB is below the 0.6 to 1.2 GiB steady state a
server plus Hermes plus the host needs. It is not rejected on price.

## Hermes forces something to be always on

It holds a Discord gateway websocket and must answer at any hour, so no shape gets
to zero. On the VM it costs **zero marginal**, because the anchor is pinned anyway
and Hermes is memory only. That memory is still an estimate of 200 to 500 MiB, and
it can no longer be measured from the app, which has been deleted. Settle it with
`podman stats` once the quadlet runs.

In Container Apps it billed **97.66 NZD** in October. The month is measured; the
cause is not. The October cost query returns the amount, and an attempt to split it
by meter hit a 429, so no meter breakdown exists here. For scale, at the active
rates this doc uses and ignoring the idle rate, an always-on 1 vCPU / 2 GiB replica
is about 215 NZD/month and 0.5 vCPU / 1 GiB about 107. So 97.66 is only reachable
near the smaller size, and Hermes's actual vCPU and GiB are not recorded. Those two
figures are active-rate ceilings, not billing predictions. What is certain is the
bill itself: about 98 NZD/month for a process that delivers no state durability.

Hermes belongs on the VM. That is settled by the constraint, not by preference.

## The finding that changes the current plan, and its live state

The plan's Phase 7 deletes all six ACA modules, `plane`, `hermes`, `environment`,
`jobs`, `aca-storage` and `storage`, with their module calls
(`docs/deployment-plan.md:975-978`), and deletes the worker recipe parameter
(`:994-996`). The inventory no longer lists `csh-dev-env` as a resource to keep,
because it is already gone, and `modules/environment.bicep` is named as drift that
still declares it alongside `csh-dev-logs` (`:140-144`). The environment is what
jobs run in, and the workspace is where their logs land.

The live state has already moved past the plan. Read with `az` on 2026-11-04:

- `csh-dev-env` was deleted 2026-11-03T03:17Z (activity log,
  `Microsoft.App/managedEnvironments/delete`, Succeeded).
- `csh-dev-hermes` went with it. `az containerapp show` returns ResourceNotFound,
  because an app has no life outside its environment.
- Three resources remain in `rg-csh-dev`: `csh-dev-logs`, the Key Vault, and
  `csh-dev-hermes-identity`.

So the amendment is not "do not delete these later". It is **rebuild the substrate
for jobs when the plugin is built**, and the substrate cannot be rebuilt today.
Three specific plan edits follow:

1. Keep `csh-dev-logs` and give it a declarer. It is declared only by
   `modules/environment.bicep` (`docs/deployment-plan.md:32`), which Phase 2's
   preferred path and Phase 7 both delete along with the environment module. Move
   the workspace into its own module, or into `infra/main.bicep`, in the same
   change. Otherwise a kept workspace has no writer, which breaks the one-writer
   rule at `docs/deployment-plan.md:170`.
2. Strike the Hermes rollback window. It is spent: the app was deleted 2026-11-03,
   so Phase 6 is a fresh stand-up rather than a cutover.
3. **Delete `modules/environment.bicep` and do not recreate the environment.** This
   doc originally said keeping the module and letting an incremental deployment
   recreate the environment was free and correct. A `what-if` measured on 2026-11-04
   refutes it: the subscription already holds **six** Container Apps environments
   against a limit of five, so creating a seventh fails preflight validation with
   `MaxNumberOfGlobalEnvironmentsInSubExceeded`. Keeping the module would make every
   deployment fail, not silently cost nothing.

So the jobs design has a precondition this document did not previously name:
**one of the six existing environments must be retired before the substrate can
exist.** That is a decision for the owners of `rg-jhl-agent-prod`,
`rg-jhl-agent-dev-aue`, `rg-jhl-agent-prod-aue`, `rg-vera`, `rg-jacobsen-content` and
`rg-jcs-website-staging`, not something this repo can take.

Cost to keep, and what October proved. `csh-dev-logs` billed **0.00 NZD** in October
while receiving Hermes logs, which confirms the free ingestion grant rather than
asserting it: the Azure Monitor pricing footnote reads "the first 5 GB/month per
billing account in this tier are free". A Consumption environment appears to cost
nothing at rest, because the retail meter `Environment Management Hour` is scoped by
the pricing page footnote to "the Dedicated plan, private endpoint, and planned
maintenance", and October's breakdown has 19 meters and no such row while
`csh-dev-env` existed for the whole month.

Treat that as provisional rather than settled. The meter appeared in the retail API
with an `effectiveStartDate` of 2026-11-01, after the October window closed. If it
ever does apply to a Consumption environment it is 0.1 USD/hour, about 130
NZD/month, which would make shape B cost 248 to 261 NZD and lose to shape A. The
plan's CostManagement query, scoped to the environment's resource id after one job
run, settles it. This is also why the environment quota, not the meter, is the
blocker worth acting on first: a substrate that cannot be created has no meter bill.

## How a job gets the work, and gives it back

| Problem | Answer |
|---|---|
| No local disk, nothing shared with the VM | Git is the transport, which matches the repo's own backup model. The job clones from Azure DevOps at a specific commit |
| Uncommitted work cannot ride git | Dispatcher refuses a dirty tree, or pushes an `oc-job/<ts>` branch and points the job at it |
| Azure DevOps auth | Not yet decided. A PAT in a job container is a new secret surface, and workload identity federation for Azure DevOps is the alternative. Named as unverified below rather than assumed |
| Key Vault access | A separate user-assigned identity for jobs with `Key Vault Secrets User`. Not the VM identity, which must stay the only one on the VM so `host/bin/lib-imds.sh:5-11` sends no `client_id` |
| Dispatch | The plugin calls the jobs start API on the VM's managed identity. Needs a custom role with `jobs/read`, `jobs/start/action` and `jobs/executions/read` only. The reason is blast radius: built-in Contributor has no `dataActions` so it cannot read a secret value, but it can rewrite vault access policy, which reaches secret values indirectly, and it can delete the job and its environment |
| Ownership of the new resources | The jobs module, its identity, its role definition and its job definitions all go in `csh-dev` Bicep in ADO. That keeps one writer per resource group (`docs/deployment-plan.md:170`). No second tool writes `rg-csh-dev` |
| Results | The job pushes `oc-job/<execution>` back; the VM polls executions and merges |
| Re-entrancy | A retry re-pushes the same branch name, so the result must be overwritten, not appended. Idempotence is a requirement of the plugin, not a natural property |

Job cold start is **not** the server's sub-second bind. That figure is the server
binding its port. Job cold start is provisioning plus ACR pull plus repo clone, is
still an estimate, and is now a separable quantity. Settle it by timing one real
run.

## Recommendation

1. **Ship the plan for the VM, with the amendment edits above.** Keep
   `csh-dev-logs`, drop the spent rollback window, and delete the ACA modules rather
   than leaving them declared.
2. **Start on `B2as_v2`** as the plan says, because subagents are local until the
   plugin exists. Availability is confirmed for both SKUs: `az vm list-skus
   --location newzealandnorth --resource-type virtualMachines --size Standard_B2as_v2`
   returns it with no restrictions and zones 1, 2, 3, and the same check for
   `Standard_B2als_v2` returns the same.
3. **Free an ACA environment slot, then build the jobs plugin.** The plugin is what
   makes a 4 GiB anchor sufficient, and it is worth up to 64.74 NZD/month, but it
   cannot be scheduled until one of the six existing environments is retired. Treat
   the slot as the first task and the plugin as the second. Until the slot exists,
   `B2as_v2` is not a temporary choice, it is the only one.
4. **Resize to `B2als_v2`** after the plugin is proven, against the three-gate
   measurement already in the plan. Keep `B2as_v2` as the resize-back target.

That path lands at 118 to 131 NZD/month with no job hours, and 133 to 175 at the
plausible 50 to 100 job-hours. Until the slot is freed and the plugin lands, the
honest figure is the plan's own: 183 to 196. Against October's actual of 455.64 that
is still a large cut, and the further 65 NZD/month is contingent rather than
scheduled.

## What is not verified

- **Whether one of the six ACA environments can be retired to free a slot.** This
  is not an unknown fact, it is an untaken decision owned by other resource groups,
  and it now blocks the jobs design outright: the subscription is at the
  five-environment limit. It is the first item on any jobs plan.
- **Whether the `Environment Management Hour` meter can ever bill a Consumption
  environment.** October says no, but the meter only appeared 2026-11-01. Settle
  with the plan's CostManagement query after the first job run. This can move the
  recommendation once a slot exists.
- **Hermes RSS**, estimated 200 to 500 MiB. The app is deleted, so this now needs
  `podman stats` once the quadlet runs.
- **Job cold start.** Estimate the provisioning and pull portion only; the server
  portion is measured. Settle by timing one real run.
- **How a job authenticates to Azure DevOps** to clone and to push results.
- **Key Vault secret references on jobs specifically**, as opposed to apps. Managed
  identity is documented; smoke-test the secret path at first deploy.
- **Whether the OpenCode plugin can dispatch externally at all**, and whether the
  `/api` surface's "experimental" label survives a version bump. Needs a feasibility
  spike before the resize is scheduled.
- **Server memory growth under load.** Idle is measured at 134 to 147 MiB. Growth
  under concurrent subagents is not, and it is the number that decides whether 4 GiB
  is enough. Settle by running a real fan-out and sampling RSS.
