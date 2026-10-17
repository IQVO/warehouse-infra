# ADR 0004: Every application is registered through one module and one registry

## Status

Accepted (2026-10-17). Implements [ADR 0002](0002-application-delivery-boundary.md)
phase 2 and decides what that phase left open. Renames the module ADR 0002
D3 and [ADR 0003](0003-per-application-terraform-state.md) call
`modules/bounded-context` to `modules/application`.

## Context

ADR 0002 phase 1 moved two contexts onto the module: order-management and
network-inventory-planning. Phase 2 says "all contexts onto the module", but
the rest of the fleet is not uniform:

- Twelve contexts share one chart shape (Kong routes, MCP, analytics
  values) and are generated from `local.services`.
- network-inventory-planning and network-fulfillment each have a database
  but a chart of their own, so their values are computed in their own files.
  network-fulfillment's chart reads one analytics key, not two.
- warehouse-ops-agent has no database and no local build: its image comes
  from a registry. It needs one Secret that is not generated, the Anthropic
  API key.
- warehouse-console and the EventCatalog (`ecosystem`) are static sites.
  Their only image is built from the repo root, and its tag goes to
  `image.tag`, not `frontend.image.tag`.

The console, the EventCatalog and the ops agent are not bounded contexts, so
a module named `bounded-context` would mislabel three of its seventeen
instances. Before this change, five hand-written ArgoCD Applications, three
hand-written frontend builds, two hand-written image builds and four
hand-written Secrets sat next to the module, each its own copy of what the
module does.

## Decision

1. **The unit is an application.** An application is one deployable with
   its own chart and its own ArgoCD Application. The module becomes
   `modules/application`, called as `module.application`. A bounded context
   normally ships one application; nothing stops it from shipping more.
2. **One registry.** `terraform/applications.tf` defines `local.applications`
   as the merge of:
   - `local.service_applications`, generated from `local.services`: the
     contexts that share `services.tf`'s chart shape;
   - `local.other_applications`, one explicit entry per application whose
     values are computed in its own file (`network-fulfillment.tf`,
     `network-inventory-planning.tf`, `ops-agent.tf`, `frontends.tf`).

   No resource outside the module creates an application's ArgoCD
   Application, Secret, generated password or image build.
   `terraform/argocd-apps.tf` is deleted.
3. **Widen the module's inputs; don't fork it.**
   - `frontend.dir` and `frontend.values_key` cover the static sites (built
     from `.`, tag set on `image.tag`).
   - `secrets` creates `<name>-<key>` Secrets from data the root supplies.
     The values may be sensitive; the keys may not, because they drive
     `for_each`.
   - `analytics_database.secret_keys` names the keys the analytics Secret
     carries. The default is the pair facility-layout's chart reads.
   - `image = null` means the image comes from a registry, and the values
     own its repository and tag.
4. **The platform reads passwords by literal key.** Until ADR 0002 phase 4,
   the Postgres initdb script and the PgBouncer userlist need every OLTP
   password. They read them through `local.app_db_passwords`, which has one
   line per database-backed application:
   `"<name>" = module.application["<name>"].db_password`.
   - Never use a for expression over `module.application`. A computed key
     makes the reader depend on the whole module call, its image builds and
     Applications included. `terraform graph` shows the edge to
     `module.application (close)`, so Postgres would wait for every build.
   - A missing line fails the plan, because `local.service_passwords`
     indexes the map.
   - The chart values sit in their own map, `local.application_helm_values`,
     outside the registry. The registry holds the platform contract; phase 3
     takes the values out of Terraform.

5. **A pure refactor, proved by plan parity** (ADR 0002 D3).
   - Every image hash keeps its exact definition. network-inventory-planning
     does not hash `analytics/migrations/`, and network-fulfillment hashes
     only `**/*.go`, not its `migrations/`. Moving both onto the module
     default changes two image tags, so it ships as its own change.
   - The `moved` blocks live in `terraform/moved-applications.tf`, including
     the phase 1 ones. One extra block moves `module.bounded_context` to
     `module.application`.
6. **Recording moves on a live state.** `apply -target=<moved address>`
   also applies that resource's pending drift, for example an image rebuild
   someone else's checkout caused. When the live state carries unrelated
   drift, record the moves with a `terraform state mv` script instead,
   after fast-forwarding every checkout that could apply. Then confirm with a
   `-refresh=false` plan that nothing is left to move.

## Consequences

Positive:

- Registering an application means one registry entry. A context with the
  shared shape adds itself to `local.services`.
- Every application gets the same platform contract. An Application can no
  longer miss a Secret it depends on, or carry a hand-copied hash.
- ADR 0003's per-application state has one module call to wrap.

Accepted costs:

- Until ADR 0002 phase 3, the values are still computed in five places:
  `services.tf` plus four special files. The registry unifies only the
  platform contract.
- A database-backed application also needs its line in
  `local.app_db_passwords` until phase 4.
- Two image-hash definitions stay inconsistent until their follow-up
  change.
- Once the moves are recorded, an apply from a checkout older than this
  change plans to replace every application's password and Secret.
  Postgres keeps the old passwords, because initdb runs only once, so every
  login would fail. Every checkout that can apply must be fast-forwarded
  first: the hazard phase 1 had for two contexts, now for all of them.

## Alternatives considered

- **Keep `modules/bounded-context` and register the console, the
  EventCatalog and the ops agent under it anyway.** Rejected: the name would
  be wrong for three instances. Renaming now costs one `moved` block;
  renaming after ADR 0003 splits the state would cost a migration per
  application.
- **A second module for static sites.** Rejected: it would differ from the
  first by two inputs, and the two modules would drift (ADR 0002 rejected
  per-application modules for the same reason).
- **Leave the special cases as hand-written resources.** Rejected: they
  are exactly the copies ADR 0002 set out to remove, and ADR 0003 cannot
  give them a state of their own.

## References

- HashiCorp, "Refactoring" (`moved` blocks, chained moves, renaming a module
  call): https://developer.hashicorp.com/terraform/language/modules/develop/refactoring
- HashiCorp, "Module composition":
  https://developer.hashicorp.com/terraform/language/modules/develop/composition
