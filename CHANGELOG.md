# Changelog

All notable changes to this project. One entry per landed change, newest first.

## Unreleased

### Added

- Fedora toolbox container image with OpenCode installed from the verified glibc
  npm artifact, pinned and sha512-checked at build time. The upstream ghcr image
  is musl-only and cannot be inherited on a glibc base.
- Idle gate that deallocates the VM after 45 idle minutes, with five busy signals,
  an operator pin file, boot grace, and fail-closed probes.
- Key Vault bootstrap writing `/etc/opencode/env` at mode 0600, and managed-identity
  ACR login writing `/etc/containers/auth.json`, both over IMDS with no Azure CLI
  on the host.
- Image pipeline that builds, smoke-gates before promotion, promotes to `:prod`,
  and records the resolved digest for rollback.
- OS image publish script and pipeline that build an Azure VHD from the upstream
  ucore-minimal bootc container, pinned by digest, and create the managed image as
  Gen2.
- Butane source and a compiled Ignition document, plus the podman quadlet that
  runs the container with every persistent path on the data disk.
- `docs/pipelines.md` recording the one-time Azure DevOps setup: the pipeline
  points at this public GitHub repo directly, with no vendored copy and no GitHub
  credential.
- Guard test asserting the OS image stays bootc-sourced and digest-pinned, is
  created as Gen2, and that no autorebase unit returns.
- Idempotent tailnet join with a durable, non-ephemeral node and SSH over tailnet
  identity.
- Terraform that boots from the published managed image with Ignition, with no
  public IP and an explicit deny for inbound internet traffic.
- Guard test asserting the Key Vault name stays derivable from tfvars, so a
  revert to a random suffix fails the gate rather than the first deploy.
- Guard tests for the three invariants that are easy to regress: no public
  ingress, no scheduled hard stop, and a destroy-protected data disk.
- Wake-and-connect wrapper that starts the VM, polls health, then opens the TUI.
- `tests/verify.sh`, one gate that runs every suite then shellchecks every script.
- Copyable `terraform.tfvars.example` documenting every required variable without
  defaults, so a first `plan` fails on a value rather than on a missing file.
- Pull-request verification pipeline that runs the whole suite on any PR touching
  the devbox subtree. It holds no service connection, so a fork can run it.
- Operating runbook covering first deployment from clone to a connected client,
  plus data disk restore, container and OS rollback, tailnet rejoin, snapshot
  pruning, and the idle gate.
- `AGENTS.md` recording the invariants a change must not break, the gate command,
  and the test-writing rules this repo learned the hard way.
- MIT licence.
- `docs/deployment-plan.md`: the phase-ordered plan for the first real run
  against `rg-csh-dev`. The plan is written against the Bicep in Azure DevOps
  project `AzureAppDev`, repo `csh-dev`, which owns that resource group today, and
  replaces the Container Apps deployment with a Bicep-owned VM. It records the
  three resources that remain, the six impedance points a naive port fails on, the
  actual October cost of 455.64 NZD against a 200 NZD budget, and the decision to
  pin the VM awake so the Hermes Discord gateway stays reachable. It prices the
  new shape at 183 to 196 NZD/month with no NAT gateway, no static IP and no
  storage account, and keeps the budget at 200 rather than raising it to cover the
  cost.
- `docs/headless-hosting-options.md`: whether the OpenCode server can run
  serverless. It cannot scale to zero on Container Apps, because OpenCode forces
  SQLite WAL mode and WAL needs shared memory on one host, while Azure Files is the
  only durable volume Container Apps offers. NFS Azure Files is mountable and still
  fails, so the locking point is not the blocker. Session state survives a restart,
  so the blocker is the storage type and not the scale-to-zero. The OpenCode claims
  carry the script that produced them: WAL forced, the same session id after a
  restart, 134 to 147 MiB idle RSS, 134 OpenAPI paths, and 401/401/200 for no
  credentials, a wrong password and the right one. The
  doc prices a `B2als_v2` anchor plus ACA jobs at 118 to 131 NZD/month as a floor,
  rising to 133 to 175 at a plausible 50 to 100 job-hours, with break-even against
  `B2as_v2` at 135 job-hours. It corrects two errors from the first draft: there is
  no `opencode attach` subcommand, and the API lives at `/api`, not `/global`.
  Finally it records the live state: `csh-dev-env` and `csh-dev-hermes` were deleted
  on 2026-11-03, so the jobs substrate must be rebuilt rather than merely kept.
- Cockpit published over the tailnet on its own HTTPS port, default 8443. ucore
  ships Cockpit and switches firewalld to the server profile so it is reachable,
  so the box would otherwise have a second root-equivalent door from the VNet.

### Changed

- `docs/deployment-plan.md` and `docs/headless-hosting-options.md`: reconciled with
  live state after the operator deleted `csh-dev-env` and `csh-dev-hermes` on
  2026-11-03 in preparation for this deployment model. Phase 6 is now a fresh
  stand-up of Hermes on the VM rather than a cutover, because there is no serving
  gateway to overlap with and the bot is offline until the phase lands. The
  inventory drops to the three resources that actually remain.

  Four measurement findings changed the plan, and each replaced a claim it had made
  confidently. A `what-if` of the committed template fails preflight validation with
  `MaxNumberOfGlobalEnvironmentsInSubExceeded`: the subscription holds six Container
  Apps environments against a limit of five, so `csh-dev-env` cannot be recreated and
  the plan no longer keeps `modules/environment.bicep` to do it. Removing only
  `modules/storage.bicep` produces 11 `BCP057` errors, because three other module calls
  and two outputs read `storage.outputs`, so Phase 2 now names the whole ACA surface
  as one atomic removal instead of a one-file edit. The ACA-removal template, before
  the VM modules are composed, builds with zero errors and its `what-if` returns
  `1 to modify, 4 no change, 1 unsupported`, so the checks no longer demand "no
  changes": `module budget` never sets `endDate` and ARM recomputes it on every
  preview. And the deleted `csh-dev-plane-identity` left a
  `Key Vault Secrets User` grant on the vault whose service principal no longer
  resolves, which Phase 7 now removes.

  `modules/jobs.bicep` is the Shape-A worker, queue-driven over the storage account
  this plan deletes, so it is deleted rather than reused as-is. The claim that a
  Consumption environment has no standing charge survives only as a provisional
  statement in `docs/headless-hosting-options.md`, labelled provisional and with the
  contradicting meter named, and the meter's scope is what to re-check if the jobs
  substrate is ever rebuilt.

  The plan also stops claiming this repo's Terraform tests guard the deployed VM.
  `terraform/tests/no_public_ip.sh` reads a `terraform show -json` plan, so it would
  pass over a plan that no longer describes the box, while
  `data_disk_protected.sh` scans `main.tf` and would fail the gate outright once the
  disk block leaves it. Phase 2 now names the two replacement readers in `csh-dev`,
  the retirement of `data_disk_protected.sh`, and the `AGENTS.md` and `README.md`
  claims that need updating. All of it is outstanding work rather than existing
  coverage.

  The cost section now carries a measured November instead of a projection alone.
  The same CostManagement query with daily granularity shows the storage account at
  15.21 and 15.35 NZD per day on 2026-11-01 and 11-02, 1.84 on the delete day, and
  no row for either deleted resource after it. At that rate the account alone
  crosses the 200 NZD budget on day 14. `rg-csh-dev` is 37.83 NZD month-to-date,
  32.39 of it storage, so the delete is the largest single saving in the plan and
  billing confirms it landed.
- The OS image is built from the ucore-minimal bootc container instead of being
  plain Fedora CoreOS that rebased onto ucore at boot. Fedora publishes no ucore
  VHD, so the previous design applied ucore's bare-metal install recipe to a cloud
  image: three boots, two marker files, and a network dependency on first boot.
  Building the VHD from the same container ucore publishes gives one boot and the
  same OS.
- Azure DevOps builds this public GitHub repo directly. The vendoring step, which
  copied the tree into a larger repository as one subtree, is removed along with
  the path-prefix edits it required on every pipeline.

### Removed

- `ucore-unsigned-autorebase.service`, `ucore-signed-autorebase.service`, their
  `/etc/ucore-autorebase` marker directory, and `test_autorebase.sh`. The image
  boots ucore, so nothing needs to rebase it.
- `docs/vendoring.md`, replaced by `docs/pipelines.md`.

### Fixed

- The OS pipeline dropped `AZURE_CONFIG_DIR` and `HOME` when it crossed the
  `sudo` boundary. AzureCLI@2 keeps its token there, so on a real agent `az` ran
  as root with no credential and reported nobody logged in, after a long build.
  Both variables are preserved now, and `pipelines/tests/test_os_pipeline.sh`
  guards that with the podman install and the builder digest pin. That guard also
  stopped matching substrings: it tokenises the logical line, drops the comment,
  and requires the script path in command position behind `sudo`, so a commented
  invocation is caught.

- The digest pin accepted `@sha256:` with nothing after it, which resolves to
  whatever the registry serves. It now requires 64 hex digits, in pure bash
  because the precondition cases run with a stripped `PATH` with no `grep`.

- `test_bootc_image.sh` read only the Butane source, so a stale or hand-edited
  `ucore.ign` reached a VM unguarded while the parity check skipped for want of
  Butane. It now scans both documents, including every scalar in the parsed
  document rather than three named keys, and the ban list gains `bootc switch`.

- The documentation claimed things the code does not do. `docs/pipelines.md` said
  all three pipelines carry a service connection and that a pipeline applies
  Terraform. Neither is true: only the two image pipelines carry one, and
  `terraform apply` is a manual step. The runbook read the rollback digest from
  `/srv/devbox/image/prod-digest.txt`, a path nothing writes, because the record
  lives in the repo. `README.md` listed 14 of the gate's 25 suites, called the
  container update idle-gated when the health check is what gates it, and claimed
  a second documented negative control that does not exist.

- The service connection's role table granted Contributor alone, which fails at
  apply with `AuthorizationFailed`: the configuration creates five role
  assignments unconditionally, and a sixth when the scheduled start is enabled.
  It now names User Access Administrator scoped to the resource group.

- Cockpit no longer listens on `0.0.0.0:9090`. ucore-minimal's shipped
  `cockpit.socket` binds every interface, and the service behind it runs
  `privileged` with `/` mounted, so the box had a root-equivalent web console
  reachable from the VNet and the tailnet, bypassing the one-door design. An
  Ignition drop-in resets the listen list and rebinds it to `127.0.0.1:9090`.
  Publishing it through `tailscale serve` keeps it usable over WireGuard.
  `host/tests/test_cockpit_loopback.sh` fails the gate if the drop-in, the reset
  ordering, the loopback target, or the port separation regresses; six mutants,
  all caught.

- The verification pipeline now installs Butane, pinned to 0.29.0 by sha256, and
  fails if the artifact check reports itself skipped. Without a compiler the
  reproducibility suite printed `SKIP` and the gate returned success, so a
  hand-edited `ucore.ign` passed CI while the gate claimed to have checked it.
  The pinned binary reproduces the committed artifact byte-for-byte.

- The env-file guard in `test_quadlet_persistence.sh` no longer guesses at how
  `oc-secrets` writes, and no longer reads the script to find out. Six rounds of
  pattern matching had each fixed one shape and left the class: the checks accepted a
  `chmod` carrying an unrelated redirect, an `echo "wrote $OUT_FILE" >&2`, and an `mv`
  to `${OUT_FILE}.new`, while rejecting `mv -f`, `mv --`, `install -m`, `cp`, `tee`,
  `dd of=`, a backslash-wrapped `mv`, and a variable declared inside a function.
  Running the writer from this guard was tried next and was worse: it supplied
  `OUT_FILE`, which systemd never does, so it passed a writer that refuses to run
  without it and writes nothing at boot, and its `grep -x` accepted
  `OPENCODE_PASSWORD=probe-password` followed by `OPENCODE_PASSWORD=legacy`. Parsing
  the writer and evaluating the fragment with bash was worse again: the eval executed
  code from the file being audited, and a non-line-initial assignment was invisible to
  the parser, so a conditional override and a second assignment both passed.
  The path is now a single definition in the unit env file that Ignition writes, and
  the guard checks the whole chain from parsed configuration: `oc-secrets.service` and
  `oc-idle.service` load that env file, the env file defines `OUT_FILE` exactly once,
  and the value equals the `EnvironmentFile=` the container loads. Nothing executes a
  shipped script or evaluates its text. `host/tests/boot_env.py` does the parsing, and
  it reads a unit's own `dropins:` blocks too, so a drop-in that sets `OUT_FILE` is
  caught rather than invisible. Its value rules were checked against `systemd-run` on
  ten env-file shapes and agree on all ten, including that a trailing `# staging` is
  part of the value rather than a comment.
- The quadlet may load only the one path `oc-secrets` writes. It used to accept any
  Ignition storage file that defined `OPENCODE_PASSWORD`, which allowed a static
  password in a config file to replace the Key Vault fetch, and a
  `[Container] Environment=OPENCODE_PASSWORD=...` was not checked at all even though
  podman's `--env` beats `--env-file`.
- No shipped file may define `OPENCODE_PASSWORD` at all, from any route. The previous
  check covered the quadlet only, and two paths around it stayed green: an Ignition
  storage file at the declared path, which bakes the secret into the VM's custom_data
  and the deployment history, and a `.container.d/` drop-in whose
  `[Container] Environment=` the podman generator merges into `--env`. The rule is now
  on every definition the parser can see, so it does not depend on which file the
  password arrives in.
- `oc-idle-check` reads the password file from `OUT_FILE` and from nothing else. It had
  accepted an `ENV_FILE` override, which took precedence over the definition the guards
  check, so a stale `ENV_FILE` in the idle env file left every guard green while the
  probe read the wrong password. `T13` now passes the probe two files that disagree on
  the password and requires it to honour `OUT_FILE`, replacing a text rule that
  accepted spellings it did not anticipate.
- `oc-idle-check` no longer carries its own copy of the password path. It derives it
  from `OUT_FILE`, which `/etc/devbox/oc-secrets.env` defines, and its unit loads that
  file. Moving the path in the one definition used to leave the idle gate reading the
  old file with every guard still green. An absent `OUT_FILE` is not fatal there: it
  means the env file never arrived, so the gate treats it as "no env file" and still
  deallocates rather than failing every five minutes while the box bills. `T12` covers
  that case, because `T10` deleted the file but still passed a path and so could not
  see a gate that dies when the variable is absent.
- `oc-secrets` no longer defaults `OUT_FILE`. The path is defined once, in
  `/etc/devbox/oc-secrets.env`, and the script fails closed when it is absent rather
  than inventing one. That removes the second definition that let the two drift apart,
  and the container's `Requires=oc-secrets.service` turns a missing path into a
  visible failure instead of a silent write nobody reads.
  `host/tests/test_oc-secrets.sh` checks this behaviourally: with `OUT_FILE` absent the
  writer must refuse *and* say why. Any default, append, or assignment makes it
  proceed instead, so one check covers every shape rather than enumerating spellings.
  Two earlier attempts enumerated them and each missed one: a `:=` default passed both
  a readonly run and an `OUT_FILE=` token scan, and a token scan also rejected a
  comment that merely mentioned the path. The suite also runs the writer under
  `env -i` with a systemd-like `PATH`, so a writer depending on an interactive tool
  fails here rather than at boot.
- The OpenCode password secret name is now checked against the secret Terraform
  creates, which the Tailscale auth key already had. A drift between `oc-secrets` and
  `azurerm_key_vault_secret.opencode_password` produces a Key Vault 404 at boot that
  reads like a permissions bug. `terraform/tests/password_secret_name_matches.sh`
  reads the `:-` default without evaluating it and checks every shipped `SECRET_NAME`
  definition through `host/tests/boot_env.py`. The resource's `name` is read by
  `terraform/tests/hcl_name.py`, which strips `#`, `//` and `/* */` comments and
  heredoc bodies, tracks brace depth so a nested `name` does not count, and requires
  exactly one plain string literal. An awk/regex reader accepted a heredoc that
  mentioned the attribute and a concatenation that merely contained a quoted string;
  both are now reported by line. The first version of the scanner claimed to strip
  block comments and did not, so a legal file was rejected as "sets name 2 times" and
  as "has no name attribute"; fifteen shapes now cover that, including a `}` and a
  `name` inside a block comment.
- `host/tests/test_oc-secrets.sh` compares the effective password rather than a
  matching line: the last assignment of the key, with one surrounding pair of quotes
  removed. Those are the rules that decide the value for the line the writer emits. A
  `grep -x` for the first matching line passed a file that also carried a later
  `OPENCODE_PASSWORD=legacy`, which systemd prefers.
- The `enabled` flag in all three unit suites is read by a YAML parser through
  `os/butane/tests/unit_enabled.py`. Each suite had its own derivation and each one
  broke on valid YAML that compiles to the same flag: a hardcoded indent, then an
  indent taken from the unit's `- name:` line, which a blank line after `- name:`
  reduces to the empty string. That last shape made every unit compare as disabled,
  so the source could enable a unit the artifact disabled and the comparison still
  returned success. `enabled: yes`, `enabled: on`, and a trailing comment now count,
  and an absent key stays distinct from an explicit false. PyYAML is an explicit
  requirement: all three suites fail loudly without it, and the PR pipeline installs
  `python3-yaml` beside shellcheck.
- Six guard defects from the sixth review round, all reproduced by mutation before
  and after the fix. `test_quadlet_persistence.sh` matched a path by substring and
  did not require a write, so it accepted a `chmod` line, a bare `echo` mention, a
  writer for `${OUT_FILE}_BACKUP`, and a writer for a longer path; three rounds of
  regex hardening had each fixed one shape and left the class. It now asserts a
  decidable contract: every `EnvironmentFile=` the quadlet loads must equal either
  the path `oc-secrets` declares as `OUT_FILE` (quotes, `export`, and a `:-`
  fallback normalised) or an exact Ignition storage path, and the writer must still
  carry a write through that variable. The stated limitation is that this proves
  the reader and the declared writer agree, not that the writer's code path is
  reached at runtime. The Ignition branch had been computed into a variable nothing
  read, so it never counted at all. `test_autorebase.sh` and
  `test_units_have_scripts.sh` derived `enabled` from a hardcoded indent and a
  line-end anchor, so `enabled: yes` and `enabled: true  # comment` failed while a
  decoy at the wrong depth could pass; that round derived the indent from the unit's
  own `- name:` line, and the YAML-parser replacement came in the next one.
  `test_units_load_their_env.sh` counted a `NAME=x` line inside a
  heredoc body as a default; heredoc bodies are stripped before assignments are
  read, column-zero assignments are parsed per semicolon-separated statement, and
  structural judgement runs on code with expansions and quoted strings removed, so
  a brace in an expansion is no longer mistaken for a shell block.
- Five gaps from the fifth review round, one of them a regression introduced by the
  round before. `test_units_load_their_env.sh` had been widened to accept any
  indented assignment as a local default, so `if false; then VAR=x; fi` counted as
  a definition and the silent-unset case passed again; assignments now have to be
  at column zero, while `local` and `declare` stay accepted anywhere because they
  are function-scoped by nature. `test_quadlet_persistence.sh` still accepted a
  path that was only read or mentioned, and matched it as a substring, so a writer
  for `/etc/opencode/env-backup` satisfied `/etc/opencode/env`; it now requires
  either an exact Ignition storage path or a host script that assigns the exact
  path and writes through that variable. `test_units_have_scripts.sh` skipped the
  enablement comparison for units with no `enabled:` key, so the artifact could
  enable a unit the source never enables. `test_autorebase.sh` searched the whole
  unit block for `enabled: true`, which an `enabled: true` line inside `contents: |`
  satisfied while Butane rendered no flag. The artifact check left its temp
  directory behind on any path that skipped the explicit cleanup, and now cleans up
  through an EXIT trap.
- Seven more guard gaps, found by the next review round and confirmed the same
  way: mutation applied, guard watched passing, then watched failing. Three were
  section-blind, which is the same defect class as the comment-blind checks fixed
  below. `test_autorebase.sh` found `ConditionPathExists=` and `WantedBy=` anywhere
  in a unit, so moving either into `[Service]` passed while systemd logged
  `Unknown key` and ignored it. `test_tailscale_enabled.sh` accepted the
  `systemctl enable tailscaled` line in `[Unit]`, where it never runs.
  `test_units_have_scripts.sh` compared the artifact to its source in one
  direction only and never compared `enabled`, so the artifact could keep a unit
  the source dropped, or drop an enablement the source declares.
  `test_units_load_their_env.sh` treated only `NAME=` as a local default, so a
  script using `export NAME=x` or `readonly NAME=x` reported a false failure.
  `test_quadlet_persistence.sh` searched the writer files as raw text, so a
  `# TODO: write /etc/...` comment satisfied a reference nothing produced.
  `authkey_is_stored.sh` rejected a valid multi-line `depends_on` list, which
  `terraform fmt` accepts and preserves.
- The committed `ucore.ign` was not what `build-placeholder.sh` produces: it had
  been rebuilt with ad-hoc values, so it differed in three storage files. It is now
  generated by that script, and the gate recompiles and diffs it whenever Butane is
  available, so a hand-built or stale artifact fails rather than shipping.
- Six guard tests passed on mutations that reproduced the exact production
  failures they claim to prevent. Each was confirmed by making the mutation and
  watching the guard report success, then fixed and re-confirmed as failing.
  `test_autorebase.sh` compared marker names to literals, so renaming stage 1's
  marker passed while leaving a reboot loop; it now binds the marker a stage
  writes to the marker the next stage reads. `test_quadlet_persistence.sh` grepped
  `EnvironmentFile=` anywhere in the file, so commenting it out, deleting it, or
  moving it into `[Unit]` all passed; it now reads the `[Container]` section only.
  `test_tailscale_enabled.sh` was section-blind, so `After=` in `[Service]` passed
  even though systemd ignores it. Both autorebase units could lose `[Install]` and
  still pass, leaving each unit `static` and never enabled. `test_units_have_scripts.sh`
  checked two named units in the compiled `ucore.ign` and never compared it to
  `ucore.bu`, so the whole autorebase pair could vanish from the artifact. And
  `authkey_is_stored.sh` accepted a commented-out `depends_on`, contradicting its
  own comment.
- `tailscaled.service` enablement did not survive the rebase onto ucore. Ignition's
  `enabled: true` writes only a preset line, and systemd applies presets once, on
  the first boot, which is still Fedora CoreOS with no `tailscaled` package. The
  preset was applied to nothing, so the unit reported `disabled` on the booted
  host and the tailnet worked only because `oc-tailnet.service` carries an
  unconditional `Wants=`. The signed-autorebase stage now enables the unit on a
  boot where it exists.
- `test_units_load_their_env.sh` only checked `${VAR:?}` syntax, so a variable the
  script reads with no fallback could be dropped from the env file its unit loads
  and the guard would still pass. It now checks reads with no local default too,
  and skips scripts that source an env file written at runtime.
- Three defects made a correctly deployed box unreachable. `tailscaled` was never
  enabled, so the tailnet join had no daemon to talk to and the box was
  Bastion-only. The Tailscale auth key was a required variable that no resource
  wrote to Key Vault, and `oc-tailnet.service` never loaded the env file that names
  the vault, so the join ran with no key source at all. And nothing ever rebased the
  box off the Fedora CoreOS image it installs from onto ucore, so the host ran an OS
  with no `tailscaled` package, zincati in place of ucore's update path, and none of
  the assumptions every host unit makes. Each defect now has a guard, and every one
  of those guards was observed failing before its fix.
- The quadlet's `EnvironmentFile` is now guarded: every file it names must have a
  component that writes it. A config pointing at a file nothing produces is how the
  tailnet key went missing, and it fails at boot as an unset variable rather than a
  missing file. The guard matches an uncommented line, so commenting one out does
  not satisfy it.
- The Tailscale secret name is now checked across the three places that must agree:
  the Ignition build default, the Terraform secret, and the compiled `ucore.ign`
  that Terraform actually ships. Checking only the source would leave a fix that
  never reaches the host.
- The Key Vault name is derived from the subscription id instead of a random
  suffix, so Ignition can be generated before the first apply. A random suffix
  made first deployment circular: Ignition needs the name, the name needed the
  apply, and the apply needs the Ignition.
- `srv-data.mount` was rejected by systemd, because a mount unit's `Where=` must
  match its filename. Renamed to `srv.mount`.
- The Logic App recurrence used `week_days`, which the azurerm provider does not
  accept. Corrected to `on_these_days`.
- Persistent session data was mounted from a podman named volume, which lands on
  the OS disk and would be lost on every VM rebuild. Now bind mounts under `/srv`.
- `get.coreos-installer.dev` does not resolve, so the OS pipeline extracts the
  installer from the pinned upstream container instead of downloading it.
- Four test assertions could not fail: a fake curl that assumed the URL was the
  last argument, JSON defaults that broke on brace expansion, a pipeline subshell
  that swallowed `exit 1`, and a digest check that returned `echo`'s status.
- An idle-gate script committed mode 0644 made every test pass vacuously.
- A failed secret bootstrap used to serve nothing while still billing. The quadlet
  now carries `Requires=oc-secrets.service`, and the idle gate treats an unreadable
  API as idle when the container is not running, so the box stops either way.
- On first boot with a failed Key Vault fetch there is no env file, and the idle
  gate exited there without ever probing, so the box still billed. It now falls
  through with no password and lets the container check decide.
- `os/butane/build.sh` wrote Butane's output straight into the target, so a failed
  compile left an empty file where a bootable Ignition document was. It now stages
  the output and moves it into place only after the assertions pass.
- The Key Vault suffix is sized against the prefix instead of truncating the
  assembled name, which silently ate hex characters at the longest prefix.
- Three guards could pass on text that did not mean what they claimed: a
  state-derived hash satisfied the vault-derivability check, a `Requires=` line
  inside `[Container]` satisfied the dependency check, and an `echo` mentioning
  `tests/verify.sh` satisfied the pipeline check.

### Known gaps

- No `terraform plan` or `apply` has run: no subscription available here.
- The container image has never been built: no container engine available here.
- The OS image has never been built. `image-builder` has not produced a VHD here,
  so the bootc build path, the `vhd` output type, and a Gen2 boot are all
  unverified against a real Azure subscription.
- All three pipeline files parse as YAML but have never executed.
- `pipelines/devbox-image.yml` and `pipelines/devbox-os.yml` carry placeholder
  registry and storage account names that must be set before first use.
- `podman-auto-update.timer` is not gated on idleness. It follows `:prod` on its
  own schedule and restarts the container when the tag moves, so an update can
  land during a running session. The health check decides whether the new image
  is kept, not whether a session is in flight. The design intended an idle gate;
  none is implemented.
- The image-integrity suite is skipped in CI, because nothing there extracts the
  tarball it inspects. The sha512 check runs only where someone has one, so a
  corrupted artifact would pass the pipeline gate.
- `systemd-analyze verify` cannot check the quadlet: it rejects a `.container`
  file, because the podman generator, not systemd, produces the unit.
