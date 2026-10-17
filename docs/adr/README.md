# Architecture Decision Records

Every decision record of `warehouse-infra`, in number order. The **Status**
column is copied from each ADR's own `## Status` section, which is the
ground truth. ADR bodies are not edited after acceptance: a later decision
amends or supersedes an earlier one with its own ADR
([ADR 0001](0001-record-architecture-decisions.md)).

| ADR | Title | Status (from the ADR body) |
| --- | --- | --- |
| [0001](0001-record-architecture-decisions.md) | Record architecture decisions in `docs/adr/` | Accepted (2026-10-17) |
| [0002](0002-application-delivery-boundary.md) | Application delivery boundary: Terraform owns the platform, Helm and ArgoCD own the applications | Accepted (2026-10-17). Amended by ADR 0003 (D6). Phase 1 (module pilot) merged and its state moves recorded; phases 2 to 6 open |
| [0003](0003-per-application-terraform-state.md) | Each application gets its own Terraform state | Accepted (2026-10-17). Amends ADR 0002 D6; implemented with ADR 0002 phase 6 |

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
