# ADR 0003: Each application gets its own Terraform state

## Status

Accepted (2026-10-17). Amends [ADR 0002](0002-application-delivery-boundary.md),
decision D6: the `terraform/20-apps` layer holds one state per application
instead of one state for all applications. Implemented with ADR 0002
phase 6.

## Context

ADR 0002 D6 splits the single root module into three states: cluster,
platform and applications. That stops platform work and application work
from blocking each other, but every application still shares the one
`20-apps` state.

The cost of sharing one state was measured on 2026-10-17. Two sessions
worked on the cluster at the same time, and one of them held the state lock
for about 75 minutes with back-to-back plans. Each plan took 15 to 25
minutes, because it hashes every sibling repo checkout (`fileset` over each
repo) and walks about 126 resources. Under ADR 0002 alone, a `20-apps` plan
for one context would still hash all seventeen repos and lock out a session
working on any other context.

Every application is already an instance of one configuration: after ADR
0002 phase 2 each one is a single `modules/bounded-context` call that differs
only in its inputs. Nothing in one application's resources depends on
another's.

## Decision

1. **One state per application.** `terraform/20-apps` stays one
   configuration. Each application is a Terraform CLI workspace named after
   the application, so its state lives in
   `terraform/20-apps/terraform.tfstate.d/<name>/` with its own lock. The
   `default` workspace holds nothing.
2. **The workspace is chosen per command, never selected.** Every command
   sets `TF_WORKSPACE=<name>`. `terraform workspace select` is not used: the
   selected workspace is stored in the working directory's shared
   `.terraform/environment` file, so two sessions selecting different
   workspaces would race on it.
3. **One registry file.** `terraform/apps.yaml` lists every application and
   its module inputs. `20-apps` reads its own entry as
   `local.registry[terraform.workspace]`, guarded by a precondition that
   fails on `default` or on a name missing from the registry. `10-platform`
   reads only the names, for the facts that are about the set of
   applications: the web gateway's frontend routes and the per-context
   dashboards.
4. **Platform facts come from the platform state.** `20-apps` reads the
   platform's outputs (PgBouncer and Postgres addresses, the Gateway, the
   Kafka brokers) through `terraform_remote_state` on the local backend. No
   application reads another application's state.
5. **Make targets.** `make app-plan APP=<name>` and `make app-apply
   APP=<name>` for one application; `make apps-plan` and `make apps-apply`
   walk the registry one application at a time. Every target passes a
   `-lock-timeout`, so a second session queues instead of failing.
6. **Prerequisites.** The same as ADR 0002 D6: D2 to D4 must have landed. An
   application's state can only stand alone once the platform no longer
   lists application passwords. The migration moves each application's
   resources out of the shared state into its workspace with `terraform
   state mv -state-out=terraform.tfstate.d/<name>/terraform.tfstate`, and is
   verified per application with the ADR 0002 D3 plan-parity check.

## Consequences

Positive:

- Two sessions working on different applications never wait on each other.
- An application plan hashes one repo and reads only that application's
  resources and the platform's outputs, so it takes seconds instead of
  minutes.
- The blast radius of an application apply is that application: it cannot
  replace another application's image, Secret or `Application`.

Accepted costs:

- Refreshing the whole fleet means seventeen sequential applies (`make
  apps-apply`) instead of one.
- Two sessions working on the SAME application still serialize on its lock.
  That is the correct behaviour.
- Renaming an application is a state migration, as it already is for any
  Terraform address.
- `terraform.tfstate.d/` holds secrets exactly like `terraform.tfstate`.
  Today's `.gitignore` covers only `terraform/terraform.tfstate*`, so the
  phase that creates the workspaces adds the new paths to it in the same
  pull request.

## Alternatives considered

- **One state for every application** (ADR 0002 D6 as first written).
  Rejected: it keeps the contention between applications that this ADR
  exists to remove.
- **One root directory per application**, each holding a backend and one
  module block. This is HashiCorp's documented alternative to workspaces,
  and the right choice when deployments need different backends or
  credentials. Not chosen here: every application shares one backend, one
  set of credentials and one configuration, which is the case workspaces
  are for. Seventeen working directories would mean seventeen `terraform
  init` runs and provider copies, and registering an application would mean
  creating a directory. Revisit if applications ever need separate
  credentials.
- **Terragrunt.** Rejected: a second tool for a problem the Terraform CLI
  already solves at this scale.

## References

- HashiCorp, "Manage workspaces" (use cases, when not to use multiple
  workspaces, alternatives): https://developer.hashicorp.com/terraform/cli/workspaces
- HashiCorp, `TF_WORKSPACE` environment variable:
  https://developer.hashicorp.com/terraform/cli/config/environment-variables#tf_workspace
