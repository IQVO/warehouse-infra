# Analytics Data-Product Governance Charter

Status: **Accepted** · Applies to: all warehouse-systems services · Sibling of the MCP governance charter

This charter governs the **analytical plane** of warehouse-systems: the per-service
"reports." It is intentionally lightweight — a **data mesh without a data platform**.
Each service owns its analytical data product end to end; there is no central
warehouse, lake, or ETL team.

---

## 1. Principles (the four data-mesh tenets, applied cheaply)

1. **Domain ownership.** The read side lives IN the owning service's repo. The team
   that owns the OLTP write model owns its report. No shared analytics codebase.
2. **Data as a product.** Each report is a versioned, documented, addressable artifact
   with an owner, a contract, and an SLA. It is reachable two ways: a REST resource
   (`GET /reports/...`) and a curated MCP tool.
3. **Self-serve.** Reuse the platform each service already runs — Kafka, Postgres,
   chi, the MCP SDK, the Helm chart. The analytical store is just a second Postgres.
   No new central infrastructure.
4. **Federated governance.** This charter + the event envelope contract (originally
   Envelope v1; since 2026-09-30 the fleet-mandatory CloudEvents 1.0 standard, see
   `envelope-v1.md`'s superseded note) + a per-service ADR are the whole governance surface. Rules below are global; everything else is
   the owning team's choice.

---

## 2. Architecture rules (non-negotiable)

- **Kafka is the only seam.** A service's report is built solely from its own
  `warehouse.<ctx>.analytics` topic. **No service reads another service's database**,
  ever. No synchronous cross-service calls to build a report.
- **Separate analytics topic.** Analytics events go on `warehouse.<ctx>.analytics`,
  never on the integration topic `warehouse.<ctx>.events`. See Envelope v1.
- **Isolated analytical store.** A **separate analytical database** per service, with
  its own credentials (`ANALYTICS_DATABASE_URL`), its own migration set, and a
  **read-only role** for the reports binary. The report never contends with OLTP:
  the projector is the only writer, the reports binary connects read-only, and the
  OLTP service never opens the analytics DB at all.
  - **Today (baseline):** a dedicated `*_analytics` database in the existing Postgres
    release (fits `warehouse-infra/terraform/postgres.tf` + `init-databases.sql.tftpl`),
    with a separate role. This is the required minimum — logical isolation + least
    privilege, zero new infra.
  - **Promotion path:** because the only coupling is the `ANALYTICS_DATABASE_URL`
    connection string, the analytics database can be moved to a **physically separate
    Postgres instance/release** later — when reporting load, backup cadence, or
    blast-radius isolation justifies it — without touching application code. Design
    to this seam now; promote when demanded (same posture as the MCP-auth OAuth seam).
- **Three-process split, single writer.** Per service:
  - `cmd/<svc>` — OLTP (unchanged by analytics work).
  - `cmd/<svc>-projector` — the **only writer** of the analytical store. Consumes the
    analytics topic, applies idempotent projections, runs the analytical migrations.
  - `cmd/<svc>-reports` — **read-only reader**. Opens the analytical store with a
    read-only role and serves `GET /reports/...`. Never writes; never migrates.
- **MCP calls REST.** The report MCP tool calls the reports binary's REST. No process
  opens an analytical DB connection it doesn't own.
- **Additive adapters only.** Analytics is inbound/outbound adapters + a new read-model
  region (`internal/analytics/`). The OLTP **domain and application layers are not
  modified**. `arch-test` must prove the OLTP layers do not import the analytics store.
- **Eventually consistent by design.** Reports are rebuilt from events, not
  dual-written from OLTP. They meet a freshness SLA, not real-time consistency.

---

## 3. Data-product contract (every report must declare)

Each report documents, in `docs/docs/analytics/<report>.md`:

- **Name & owner** — the report and the owning service/team.
- **Grain** — the row key (e.g. per task-type × station × hour).
- **Inputs** — the `event_type`s consumed (must match the Envelope v1 registry).
- **Interface** — REST endpoint(s) + query params + response DTO; the MCP tool name
  and its schema. Read-only scope.
- **Freshness SLA** — see §4.
- **Versioning** — how the report's shape evolves (additive fields are non-breaking;
  a breaking change is a new endpoint/tool version).

---

## 4. Freshness SLA (the analytical plane's one quality number)

- **Definition:** freshness lag = `now − max(occurred_at applied to the store)`.
- **Target:** p95 event-to-report lag **< 30s** under normal load.
- **Exposed:** every reports binary serves `GET /reports/<name>/freshness` returning
  the current lag. The Phase-4 e2e smoke test asserts each report reflects driven OLTP
  activity within this SLA.
- Breaching the SLA is an operational alert (projector lag / consumer down), not a
  correctness bug — the report catches up when the projector does.

---

## 5. Naming

- Analytics topic: `warehouse.<ctx>.analytics`.
- Consumer group: `<ctx>-analytics`.
- Analytical DB env: `ANALYTICS_DATABASE_URL` (distinct from OLTP `DATABASE_URL`).
- Binaries: `cmd/<svc>-projector` (writer), `cmd/<svc>-reports` (reader).
- Read-model region: `internal/analytics/report/`.
- REST: `GET /reports/<name>` and `GET /reports/<name>/freshness`.
- MCP tool: `get_<ctx>_<name>_report` (curated, intent-level, read-only).

---

## 6. Process & delivery

- **GitFlow**: analytics ships on `feature/analytics-data-product` → PR into
  `develop`, never direct to main. CI green before merge. Publishing is main-only.
- **Quality gate**: `make check` before commit, `make check-all` before push
  (includes `arch-test` proving OLTP↔analytics isolation).
- **ADR required** per service: `ADR-00NN-analytical-data-product.md`, linking this
  charter and Envelope v1.
- **CLAUDE.md** is updated from the interactive session after the feature merges
  (dispatched agents cannot edit it), recording the analytics region, the two new
  binaries, the analytics topic, and the report endpoints/tool.

---

## 7. Rollout order

1. **Phase 0** — this charter + Envelope v1 (done).
2. **Phase 1** — fulfillment-execution pilot (reference implementation).
3. **Phase 2** — facility-layout Kafka enablement (only service without Kafka).
4. **Phase 3** — fan out to wes-work-planning, order-management, inventory-storage,
   workforce-management (+ facility-layout), one PR per repo.
5. **Phase 4** — cross-service freshness smoke test in `e2e-tests`.

Full task-level plan:
`warehouse-systems/.hermes/plans/2026-08-25_190000-per-service-analytics-data-products.md`.
