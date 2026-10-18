# ADR 0007: The state split lands in four steps, and the registry is a data file

## Status

Accepted (2026-10-18). Implements [ADR 0002](0002-application-delivery-boundary.md)
D6 and [ADR 0003](0003-per-application-terraform-state.md) (phase 6). Step 1
(the registry) is merged with this ADR. All four steps are done: the
registry, `terraform/20-apps`, the layers `00-cluster` and `10-platform` with
one migration for all of them ([ADR 0008](0008-one-migration-for-the-layers.md)),
and the cleanup. The live state was moved on 2026-10-18.

## Context

ADR 0002 D6 splits the root module into `00-cluster`, `10-platform` and
`20-apps`; ADR 0003 gives `20-apps` one workspace per application. Both
waited for D2 to D5, which have landed:

- the platform no longer reads an application password (ADR 0005), so a
  platform layer can stand without the application layer;
- the Gateway API objects are ordinary resources (ADR 0006);
- every application is one instance of `modules/application` (ADR 0004).

Reading the configuration for the split shows what still ties the two sides:

- **Application facts sit in hand-maintained maps.** `local.services` (12
  entries with derived names and a `chart_path` nothing reads),
  `local.analytics_services`, `local.argocd_repo_owner`, the database names in
  `network-*.tf`, `local.frontend_remotes` and the `other_applications` map
  describe the same 17 applications in five places. The platform needs only
  the frontend remotes (for the web gateway); the application layer needs all
  of them.
- **`frontends.tf` mixes the layers.** The web gateway is platform; the image
  hashes of the frontends are application inputs.
- **Two root outputs read application passwords** (`database_urls`,
  `analytics_database_urls`), so they belong to the application layer.
- **Platform to application is one-way.** The application layer reads the
  namespaces, the Postgres object, PgBouncer's address, the ArgoCD namespace,
  the cluster name and `local.gateway_ready`. Nothing flows back.

A state split is the one change here that cannot be checked by comparing two
plans of the same configuration, and it rewrites the live state. It has to be
cut into steps, each of which can be verified on its own.

## Decision

1. **The registry is `terraform/apps.yaml`.** One entry per application, with
   the fields the file's header documents (`kind`, `repo_owner`,
   `deploy_with`, `build_image`, `database`, `analytics`, `frontend_remote`,
   `site`). Database and role names follow the convention (the application
   name with dashes as underscores, `_analytics` for the second database).
   The five maps above become derivations from it. `local.services` keeps
   its consumers (the `services` output, `database_urls`) and drops
   `chart_path`.
2. **Four steps, each its own pull request.**
   1. **Registry.** Pure refactor, no state change. Checked by comparing the
      derived values with the old maps and a plan against the live state.
   2. **`20-apps`.** A new directory with one `module.application` instance
      and the workspace-per-application layout of ADR 0003. It reads the
      platform through `terraform_remote_state` of the root, which publishes
      one `platform` output. The state moves with `terraform state mv
      -state-out=terraform.tfstate.d/<app>/terraform.tfstate`.
   3. **`00-cluster`.** `kind_cluster` and the kubeconfig export leave the
      root. The rest becomes `10-platform`, whose providers read the cluster
      credentials from `00-cluster`'s output instead of from a resource in
      the same configuration.
   4. **Cleanup.** `moved-applications.tf` (its moves are recorded), the make
      targets, `.gitignore`, the guides and the skills.
3. **Each layer publishes one object.** `00-cluster` publishes the cluster
   name, endpoint, CA and client credentials and the kubeconfig path.
   `10-platform` publishes the namespaces, the Postgres object of ADR 0005,
   PgBouncer's address, the ArgoCD namespace and the Gateway readiness value.
   A layer reads only the layers below it, through `terraform_remote_state`
   on the local backend. A missing lower state is a plan error that names the
   layer to apply first.
4. **A migration is recorded, never improvised.** Each state-moving step ships
   a script that moves addresses with `terraform state mv`, takes a backup
   first, and prints the counts before and after. It runs from a checkout at
   or after the merge, only with the maintainer's go-ahead, and is followed by
   a `-refresh=false` plan of every affected layer (and every workspace), each
   of which must say "No changes".
5. **One variable file.** The layers keep reading `terraform/terraform.tfvars`
   through `-var-file`. A layer ignores variables it does not declare.

## Consequences

Positive:

- Each step is small enough to verify, and only steps 2 and 3 touch the live
  state.
- Application facts live in one reviewable file, so ADR 0003's
  `local.registry[terraform.workspace]` and the platform's frontend list read
  the same source.
- Registering an application is one entry in `apps.yaml` and two value files.

Negative:

- Until step 4 the repository holds both layouts, and the guides must say
  which steps have landed.
- After a state-moving step, a checkout from before it cannot plan correctly:
  it would plan to create what moved out. The migration therefore starts by
  fast-forwarding the shared checkout, as the earlier recorded moves did.
- The comments that told each service's history in `locals.tf` are gone. The
  rationale that still holds moved to `apps.yaml`'s header, the module and the
  ADRs.

## Alternatives considered

- **One pull request for the whole split.** It would mix a file move, a
  provider change and a live state rewrite, and a plan comparison could not
  separate them.
- **Splitting the state first and the registry later.** Both layers need the
  application list, and copying the five maps into two directories would
  create the drift the registry removes.
- **Keeping the HCL maps and sharing them as a module.** Terraform has no
  include, so each layer would instantiate the module to read the list, and
  the make targets of ADR 0003 (`apps-plan` walks the registry) could not read
  it at all. A YAML file is readable by Terraform in every layer and by the
  scripts.
