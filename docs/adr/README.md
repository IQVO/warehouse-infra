# Architecture Decision Records

Every decision record of `warehouse-infra`, in number order. The **Status**
column is copied from each ADR's own `## Status` section, which is the
ground truth. ADR bodies are not edited after acceptance: a later decision
amends or supersedes an earlier one with its own ADR
([ADR 0001](0001-record-architecture-decisions.md)).

| ADR | Title | Status (from the ADR body) |
| --- | --- | --- |
| [0001](0001-record-architecture-decisions.md) | Record architecture decisions in `docs/adr/` | Accepted (2026-10-17) |
| [0002](0002-application-delivery-boundary.md) | Application delivery boundary: Terraform owns the platform, Helm and ArgoCD own the applications | Accepted (2026-10-17). Amended by ADR 0003 (D6). Phases 1 to 4 merged (phase 2 by ADR 0004; phase 3: values in `helm-values/`, two-source Applications; phase 4 by ADR 0005; phase 5 by ADR 0006); phase 6 merged (ADR 0007 in four steps; the live state moved by one migration, ADR 0008) |
| [0003](0003-per-application-terraform-state.md) | Each application gets its own Terraform state | Accepted (2026-10-17). Amends ADR 0002 D6; implemented by ADR 0002 phase 6 (2026-10-18) |
| [0004](0004-one-application-registry.md) | Every application is registered through one module and one registry | Accepted (2026-10-17). Implements ADR 0002 phase 2; renames the module to `modules/application`. State moves recorded; image-hash follow-up done; decision 4 ended by ADR 0005 |
| [0005](0005-database-provisioning-by-jobs.md) | Application roles and databases are provisioned by Jobs, and the platform names no application | Accepted (2026-10-18). Implements ADR 0002 D4 (phase 4) |
| [0006](0006-declarative-gateway-api.md) | The Gateway API objects are `kubectl_manifest` resources, and the CRD bundle is vendored | Accepted (2026-10-18). Implements ADR 0002 D5 (phase 5) |
| [0007](0007-state-split-in-four-steps.md) | The state split lands in four steps, and the registry is a data file | Accepted (2026-10-18). Implements ADR 0002 D6 and ADR 0003; all four steps done; live state moved 2026-10-18 (ADR 0008) |
| [0008](0008-one-migration-for-the-layers.md) | One migration moves the live state into all three layers | Accepted (2026-10-18). Amends ADR 0007 decisions 2 and 4; run on the live state 2026-10-18 |

## Adding an ADR

1. Take the next free number (check this table and open pull requests).
2. Create `NNNN-kebab-case-title.md` with this skeleton:

   ```markdown
   # ADR NNNN: <title>

   ## Status

   Proposed | Accepted (YYYY-MM-DD)

   ## Context

   ## Decision

   ## Consequences
   ```

3. Add a row to the table above in the same pull request.
4. If the ADR replaces or changes an earlier one, set the earlier ADR's
   Status line to `Superseded by ADR NNNN` or `Amended by ADR NNNN` and
   update its row here.

## Decisions recorded before this log

Older decisions are still prose. An ADR that changes one of them cites it
and points it at the ADR (ADR 0001, decision 6):

- `README.md`: "Where the manifests live", "Deploying a new bounded context
  (GitOps via ArgoCD)", "Design notes".
- [`docs/exposure/localhost-edge-topology.md`](../exposure/localhost-edge-topology.md):
  Nginx `:80` for assets and Kong `:8000` for APIs, never chained.
- [`docs/scalability/pgbouncer-connection-pooling.md`](../scalability/pgbouncer-connection-pooling.md):
  PgBouncer in transaction mode in front of every OLTP database.
