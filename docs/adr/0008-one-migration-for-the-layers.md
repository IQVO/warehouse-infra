# ADR 0008: One migration moves the live state into all three layers

## Status

Accepted (2026-10-18). Amends [ADR 0007](0007-state-split-in-four-steps.md)
decisions 2 and 4 (how the migrations of steps 2 and 3 run). Implements
[ADR 0002](0002-application-delivery-boundary.md) D6 and
[ADR 0003](0003-per-application-terraform-state.md). Run on the live state on
2026-10-18 (source serial 2432, 210 addresses = 2 + 49 + 159): after
refresh-only applies of `00-cluster` and `10-platform`, those two layers and
all 17 workspaces planned "No changes" with a real refresh. The one flaw found
while running it, `terraform state` needing the modules installed, is fixed in
the script.

## Context

ADR 0007 cuts the split into four pull requests, and step 2 ships
`scripts/migrate-app-state.sh`, which moves one application at a time out of the
shared root state into its workspace. Step 3 then moves the cluster out of
what remains. Run as written, that is 17 live rewrites of a 7.5 MB state that
holds every secret, one per application, and an 18th for the cluster, with the
root's `platform` output recorded by an apply in between. After each one the
state is half moved, and a checkout from before the move would plan to create
what the script just moved.

Step 2's code merged first, and nothing has been migrated. Step 3's code is
ready, so the whole split can be moved at once.

## Decision

1. **One script, one run.** `scripts/migrate-state-to-layers.sh` moves the
   cluster (`kind_cluster.warehouse`, `null_resource.kubeconfig`) into
   `00-cluster`, each `module.application["<name>"]` into the workspace state
   of `20-apps` as `module.application`, and leaves the rest as `10-platform`.
   It replaces `migrate-app-state.sh`, which this change deletes.
2. **It works on a copy and leaves the source alone.** The script writes the
   three layers' states next to the source, refuses to overwrite one, checks
   that source = cluster + platform + applications, and never modifies the
   source. The operator renames the source once the verification plans are
   clean. Rolling back is deleting the layer states and using the commit before
   the split.
3. **The contract keeps its shape.** `10-platform` publishes the same sensitive
   `platform` output step 2 defined, so `20-apps` changes by the path of one
   remote state. The cluster fields of that output now come from `00-cluster`'s
   `connection` output, and the providers of `10-platform` read it too.
4. **The kubeconfig stays the relative `./kubeconfig`.** `kind_cluster`
   replaces the cluster when `kubeconfig_path` changes, and every existing
   state holds `./kubeconfig`. `00-cluster` runs from its own directory, so the
   file is `terraform/00-cluster/kubeconfig`; an absolute path planned a
   replacement of the cluster in the first rehearsal.
5. **An unknown workspace is an error, not a warning.** Step 2 guarded the
   workspace with a `check` block, which only warns: `TF_WORKSPACE=typo
   terraform apply` would create an ArgoCD Application, a role and a database
   named `typo`. A precondition on the `workspace` output stops the plan. Its
   predicate depends on the platform state, so `terraform validate`, which has
   no state and runs in the default workspace, skips it.
6. **What leaves the platform.** The `database_urls` and
   `analytics_database_urls` outputs (each application's `database_url` and
   `analytics_database_url` output in `20-apps` replace them), `ops_agent_route`
   (nothing read it), `moved-applications.tf` (its moves were recorded on the
   live state on 2026-10-17) and the web gateway's dependency on
   `module.application` (it resolves every upstream at request time, so it
   starts before the Services exist).

7. **`20-apps` declares no `backend` block.** Step 2 wrote an empty
   `backend "local" {}`. With it, every `terraform init` after the first
   workspace state exists asks to migrate the workspaces and fails without a
   terminal (`Error asking for state migration action: input is disabled`), so
   a fresh clone, a provider bump or `scripts/tf.sh` could never initialise the
   layer once the migration had run. The default backend is the local one and
   writes the same files.

## Consequences

- One live rewrite, to be run with the maintainer's go-ahead from a checkout at
  or after this change, followed by refresh-only applies of `00-cluster` and
  `10-platform` (they record the outputs the layers above read) and a plan of
  every workspace.
- The first apply of each workspace records its `workspace` output; until then
  a plan of it shows that one output as new.
- After the migration a checkout older than this change plans to create every
  resource, because the old root state is renamed. The guides say never to
  apply from one.
- The layers are applied in order the first time (`00-cluster`, `10-platform`,
  `20-apps`); `scripts/up.sh` does it.

## Alternatives considered

- **Keep the per-application script, as ADR 0007 says.** Rejected for the
  reasons in the context: 18 rewrites instead of one.
- **`20-apps` reads the cluster's credentials from `00-cluster` itself.**
  Rejected: it adds a second contract object for no gain. One `platform`
  object is what step 2 reviewed.
