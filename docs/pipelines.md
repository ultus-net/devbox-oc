# Build this repo from Azure DevOps

This repo is the single source of truth. It is public and lives at
`github.com/ultus-net/devbox-oc`. Azure DevOps builds it directly and deploys
into the work subscription. Nothing is copied, vendored, or forked into another
repository.

## Why there is no vendoring step

An earlier design copied this tree into a larger Azure DevOps repository as one
subtree under `infra/devbox/`. That step existed only because the company repo was
assumed to be the source of truth. It cost a prefix edit on every pipeline path
and a second copy that could drift.

Building from GitHub removes both. A public repository needs no credential for
Azure Pipelines to clone it, so the pipeline holds no GitHub secret.

## What the operator sets up once

These are console steps in the Azure DevOps project. They are not in this repo
because they are project state, not code.

1. **Create the pipeline, pointing at GitHub.** In Azure DevOps: Pipelines →
   New pipeline → GitHub → select `ultus-net/devbox-oc`. Because the repo is
   public, no GitHub service connection is required to read it.

2. **Point the pipeline at the existing YAML.** Each pipeline file is already in
   this repo. Create three pipelines, one per file:

   | Pipeline file | When it runs |
   |---|---|
   | `pipelines/devbox-verify.yml` | every pull request |
   | `pipelines/devbox-os.yml` | manual or scheduled, publishes the OS image |
   | `pipelines/devbox-image.yml` | on `main` when `image/` changes |

3. **Create the Azure service connection.** Both image pipelines reference
   `azureSubscription: devbox-image`. Create a service connection with that exact
   name, or rename it in both pipeline files. Use workload identity
   federation, not a secret.

   `pipelines/devbox-verify.yml` holds no service connection on purpose, so a
   fork can run the PR gate unchanged. Do not point it at one.

4. **Grant the service connection least privilege.** It needs:

   | Scope | Role | Why |
   |---|---|---|
   | The resource group | Contributor | create the VM, disk, network, Key Vault |
   | The container registry | `Container Registry Repository Writer` | push and pull, no delete |
   | The resource group | User Access Administrator | create the role assignments the Bicep declares |

   The last row is required and is not obvious. The `csh-dev` Bicep grants Key
   Vault Secrets User and the ACR role to the VM identity. Contributor cannot
   grant either, so the deploy fails with `AuthorizationFailed`. User Access
   Administrator is the narrow built-in that can grant them. Scope it to the
   resource group, not the subscription.

   The Terraform stack in this repo is the port record and is never applied, so
   its own role list is history rather than a requirement.

## The one write back to GitHub

`pipelines/devbox-image.yml` records the promoted digest in
`image/prod-digest.txt` and pushes that commit to `main`. This keeps the rollback
record in git, next to the Dockerfile it describes.

A public repository cannot be written to from Azure Pipelines without a
credential. If you would rather not grant one, the alternative is to publish the
digest as a pipeline artifact instead. That is a change to one step in
`pipelines/devbox-image.yml`, not a redesign. Decide before the first image build,
because the digest record is what makes a rollback deterministic.

## Registry

The image pipeline targets the ACR `cshdevacrb6lmephspqf2u`, created by the
`acr` module in the `csh-dev` Bicep. The `uniqueString(resourceGroup().id)`
suffix is stable for `rg-csh-dev`, so the name does not move on redeploy. A
different resource group gets a different suffix, and the pipeline variable must
be updated with it.

Basic SKU is enough. Repository-scoped Entra roles work on all three SKUs, so
least privilege is not a reason to pay for Standard or Premium. The Premium
retention policy only purges *untagged* manifests, so it does not solve `sha-*`
tag accumulation either; a purge step is needed on every SKU. Premium becomes
necessary only if policy forbids public network access on the registry, since
private endpoint is Premium-only.

## Terraform state

There is no Terraform state, because the stack in `terraform/` is the port record
and is never applied. If the record is ever revived, state must not live in this
repo and must not live on the pipeline agent: use an Azure Storage backend with
state locking.

Do not let two tools manage the same resource. The deployed VM, network, disk,
ACR and Key Vault belong to the `csh-dev` Bicep.

## First run order

1. `./tests/verify.sh` locally. It must end with `VERIFY: all suites pass`.
2. Run `pipelines/devbox-os.yml` once to publish the OS image. Note the managed
   image ID it prints.
3. Run the `csh-dev` pipeline once with `deployVm=false`. It creates the network,
   disk, ACR, Key Vault and logs.
4. Build Ignition per `docs/runbook.md`, upload the result as a secure file named
   `ucore.ign` in the pipeline library, then queue the `csh-dev` pipeline with
   `deployVm=true` and `vmImageId` set to the image ID from step 2.
5. Run `pipelines/devbox-image.yml` to build and promote the container image.
6. Follow `docs/runbook.md` from the first boot.

## Confirm the gate before trusting a PR

The verify pipeline needs no Azure credentials and no container engine. A fork
can run it unchanged. It fails rather than skips when `shellcheck`, PyYAML, or
Butane is missing.
