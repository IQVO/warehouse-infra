# ADR 0001: Record architecture decisions in `docs/adr/`

## Status

Accepted (2026-10-17).

## Context

warehouse-infra makes the decisions that shape every deploy of the fleet:
each service repo owns its own Helm chart, ArgoCD installs it, Terraform
owns the environment, the localhost edge keeps Nginx and Kong independent,
PgBouncer sits in front of every OLTP database, and Kong configuration lives
in the application charts. None of these is written down as a decision
record. They exist as prose that is edited in place:

- `README.md` sections "Where the manifests live", "Deploying a new bounded
  context (GitOps via ArgoCD)" and "Design notes";
- `docs/exposure/localhost-edge-topology.md`;
- `docs/scalability/pgbouncer-connection-pooling.md`;
- comments at the top of the Terraform files.

Prose edited in place loses the date and the reason of a decision, and
nothing marks a decision as replaced. Parts of it have already gone stale
(the "Design notes" said routing needs no Gateway API CRDs and that images
are tagged `:local`; both stopped being true). Every service repo in the
fleet keeps ADRs; warehouse-infra was the only repo that shapes deploys
without them.

## Decision

1. Architecture decisions for this repo are recorded in `docs/adr/`, one
   Markdown file per decision, named `NNNN-kebab-case-title.md`. Numbers
   are assigned in order and never reused.
2. Format, the same as the service repos: a `# ADR NNNN: <title>` heading,
   then `## Status`, `## Context`, `## Decision`, `## Consequences`.
   `## Alternatives considered` and `## References` are optional.
3. Status is one of `Proposed`, `Accepted (<date>)`, `Superseded by ADR
   NNNN` or `Amended by ADR NNNN`. After acceptance the body is not edited;
   only the Status line changes. A changed decision is a new ADR that
   supersedes or amends the old one.
4. `docs/adr/README.md` is the index. Its Status column is copied from each
   ADR's own Status section, which stays the ground truth.
5. A change to this repo that alters a recorded decision ships its ADR in
   the same pull request.
6. The earlier prose decisions listed above are not backfilled as a batch.
   When an ADR changes one of them, it cites the prose it replaces, and the
   same pull request points that prose at the ADR.

## Consequences

- Reviewers and agents find the reason for an infra shape in one place,
  with a date, instead of reconstructing it from commit history.
- Decisions taken before this ADR stay in the prose listed above until an
  ADR touches them, so the log is incomplete by design for older decisions.
- The fleet's guide linter (`scripts/harness/guide_lint.py`) checks
  `ADR-NNNN` citations against the template's `docs/docs/adr` layout only.
  Guides in this repo cite ADRs by file path instead, which the same linter
  checks for existence.
