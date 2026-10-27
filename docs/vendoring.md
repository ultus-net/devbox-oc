# Vendoring this into an existing Azure DevOps repo

This repo is a build repo. It is meant to be copied into a larger Azure DevOps
repository as one subtree, not consumed as a submodule and not kept as a second
source of truth.

## What moves

Copy these paths, unchanged except for the two edits below:

| Path | Why it moves |
|---|---|
| `image/` | the dev container: Dockerfile, toolchain list, smoke test, digest record |
| `os/` | the OS image pipeline script and the Butane/Ignition source |
| `host/` | the scripts and quadlet baked into the OS image |
| `terraform/` | all Azure resources |
| `pipelines/` | the two pipeline fragments |
| `tools/` | the operator's wake-and-connect wrapper |
| `tests/` | the verification gate |
| `docs/` | runbook and vendoring notes |

## What does not move

- Terraform state, `terraform/.terraform/`, and any `tfplan`.
- Any `.env`, password file, or Key Vault reference pointing at a personal vault.
- A personal `opencode.json` with your themes and keybinds. That is your config,
  not the project's toolchain.
- This repo's git history. Land one commit under `infra/devbox/` and archive the
  build repo, so the target repo is the only source of truth.

## Two edits required at vendoring time

1. **Point the pipeline paths at the new location.** Both pipeline files assume
   they sit at the repository root. In a larger repo they will live under
   something like `infra/devbox/`, so every `./image/`, `./os/`, `./host/` and
   `./terraform/` reference needs that prefix. The `trigger: paths:` block needs
   it too, or the pipeline will never fire.

2. **Choose where Terraform state lives.** If the platform team owns the resource
   group, delete `terraform/` entirely and vendor only `image/`, `os/`, `host/`,
   `tools/`, and `tests/`. Their IaC creates the VM, disks, identity and NAT
   Gateway, and you become a guest with a pull permission. Do not let two tools
   manage the same resource.

## Registry

The build repo defaults to an ACR named in `pipelines/devbox-image.yml`. Confirm
the real registry name before the first run; it is a placeholder.

Basic SKU is enough. Repository-scoped Entra roles work on all three SKUs, so
least privilege is not a reason to pay for Standard or Premium. The Premium
retention policy only purges *untagged* manifests, so it does not solve `sha-*`
tag accumulation either; a purge step is needed on every SKU. Premium becomes
necessary only if policy forbids public network access on the registry, since
private endpoint is Premium-only.

## Service connection

Use workload identity federation, not a secret. The pipeline identity needs
`Container Registry Repository Writer` (push and pull, no delete). Grant it no
rights over the VM: the pipeline builds images, it does not manage the host.

## After the copy

```sh
cd <target-repo>/infra/devbox
./tests/verify.sh
```

It must end with `VERIFY: all suites pass` before you open the PR. The gate needs
no Azure credentials and no container engine, so it runs on any agent.

Then confirm the two placeholders the build repo could not resolve:

- `pipelines/devbox-image.yml`: the ACR name.
- `pipelines/devbox-os.yml`: the resource group and storage account. Storage
  account names are globally unique, so the value here is certainly wrong.
