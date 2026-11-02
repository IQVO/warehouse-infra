# ADR 0010: Adopt the fleet REST API guideline

## Status

Accepted (2026-11-02). Complements [ADR 0002](0002-application-delivery-boundary.md): this repo owns no
service API, only its callers.

## Context

The fleet cuts over to one REST API guideline (the warehouse-docs REST guideline, `STANDARD.md`): noun
routes with no custom-method suffix (`:verb`), an `Idempotency-Key` on every POST and PATCH (global key,
reuse answers 409 `idempotency-key-reused`, replays carry `Idempotency-Replayed`), and paged collections
as `{items,nextCursor}` with `limit` and `cursor`. The cutover is hard: no aliases, no toggles.

`warehouse-infra` exposes no API of its own, but it calls some routes: the retail-network seed script and
one route string in a values-file comment.

## Decision

Follow the fleet standard; this repo only updates its callers, in the same release as the providers.

| Old | New |
|---|---|
| `POST /delivery-offers:quote` | `POST /delivery-quotes` |
| `POST /nodes/{id}:activate` | `POST /nodes/{id}/activations` |
| `POST /nodes/{id}:retire` | `POST /nodes/{id}/retirements` |
| `POST /lanes/{id}:close` | `POST /lanes/{id}/closures` |
| `POST /catalog-items/{id}:discontinue` | `POST /catalog-items/{id}/discontinuations` |
| `POST /containers/{lpn}:break` (comment in `helm-values/fulfillment-execution.yaml`) | `POST /containers/{lpn}/case-breaks` |

- `scripts/seed-retail-network.py` sends an `Idempotency-Key` on every POST; the `--verify --quote` call,
  previously keyless, now sends a fresh `seed-rn:quote:<uuid>` key. Its list reads already use `items` and
  `nextCursor`.
- Kong and nginx routes are prefix-based; no per-route path in `charts/` or `terraform/` names a renamed verb.
- No exemptions: there is no OpenAPI spec or paged collection in this repo.

## Consequences

BREAKING for the seed script against pre-cutover providers: it must run against the cluster only after the
providers' REST cutover PRs are deployed. No Terraform or cluster change.
