# Analytics Event Envelope — v1

Status: **Superseded (2026-09-30)** by the fleet standard *CloudEvents 1.0 is
the ONLY event envelope* · Owner: platform/architecture

> **Superseded.** The flat envelope in §2 (`event_id` / `event_type` /
> `occurred_at` / `source` / `schema_version` / `data`) is no longer emitted
> or accepted anywhere. Every message on `warehouse.<ctx>.analytics` (and on
> `warehouse.<ctx>.events`) is now a CloudEvents 1.0 event in structured
> content mode (`content-type: application/cloudevents+json; charset=UTF-8`)
> with `specversion`, `id`, `source=/warehouse/<repo>`,
> `type=com.warehouse.<subdomain>.<bounded-context>.<entity>.<EventName>`,
> `subject`, `time`, `datacontenttype=application/json` and
> `dataschema=urn:warehouse:<repo>:analytics:<EventName>:v<N>` (which
> replaces `schema_version`). `data` payloads are unchanged. See the
> fleet standard in warehouse-docs
> (`docs/strategic-design/event-standard-cloudevents.md`), each service's
> "CloudEvents 1.0 as the mandatory event envelope" ADR, and the cutover
> runbook `docs/cloudevents-cutover.md`. The topic split (§1), payload
> rules (§3), registry (§5) and non-goals (§6) below still apply; the
> envelope (§2) and the `schema_version` rule in §4 do not.

This is the **published language** for the analytical plane. Every service emits its
report-input domain events onto its own **analytics topic** wrapped in this envelope.
It is deliberately separate from the *integration* event contract: analytics rides a
dedicated topic so the operational integration contract is never coupled to reporting.

---

## 1. Two topics per service — do not conflate them

| Topic | Purpose | Consumers | Contract |
|---|---|---|---|
| `warehouse.<ctx>.events` | Operational **integration** — one service reacting to another (e.g. wes reacting to `TaskCompleted`). | Other services' inbound consumers. | Curated, minimal, stable. Existing. **Not changed by analytics work.** |
| `warehouse.<ctx>.analytics` | **Analytical** feed — the service's report-input event stream. | Only that service's own analytics **projector**. | This Envelope v1. New. |

`<ctx>` is the bounded context short name: `fulfillment`, `wes`, `order`,
`inventory`, `facility`, `workforce`.

Rationale: a service's report may need many more event types than its integration
contract exposes, and those events change on a different cadence. Keeping them on a
separate topic means adding a report-input event never risks surprising an
integration consumer, and analytics retention can be tuned independently.

---

## 2. The envelope

A CloudEvents-inspired wrapper. JSON, UTF-8. One event per Kafka message.

```json
{
  "event_id":    "01J9Z...",             // globally unique id for THIS emission (ULID/UUID). Idempotency key.
  "event_type":  "TaskClaimed",          // PascalCase domain event name (matches DomainEvent.EventName()).
  "occurred_at": "2026-08-25T18:42:11Z", // RFC3339 UTC; the domain event's OccurredAt(), NOT publish time.
  "source":      "fulfillment-execution",// emitting service (repo/module name).
  "schema_version": 1,                   // envelope version. Bumped only on a breaking envelope change.
  "data": { /* event_type-specific object, see §3 */ }
}
```

| Field | Type | Required | Notes |
|---|---|---|---|
| `event_id` | string | yes | Unique per emission. Consumers dedupe on it (`ProcessedEvents`). |
| `event_type` | string | yes | Discriminator. Consumers **switch** on it and **ignore unknown types**. |
| `occurred_at` | string (RFC3339 UTC) | yes | Business time from the domain event. Drives report time-bucketing and freshness lag. |
| `source` | string | yes | Emitting service. |
| `schema_version` | int | yes | Envelope version (this doc = 1). |
| `data` | object | yes | Payload; shape depends on `event_type`. Opaque to the envelope. |

**Kafka message key** = the aggregate id (e.g. `task_id`), so all events for one
aggregate land on the same partition and are consumed in order.

**Headers**: OTel trace context is injected into Kafka message headers (reuse each
service's `observability` carrier) so a projector span is a child of the producing
span. Headers carry transport concerns only; never put contract data in headers.

---

## 3. `data` payloads

`data` is an `event_type`-specific JSON object. Rules:

- Field names are `snake_case`.
- Include the identifiers and measures the **report** needs — not the whole aggregate.
- Keep it flat and denormalized where cheap; the projector should not have to call back.
- **Evolution is additive**: you may ADD optional fields to a `data` shape without a
  version bump. Consumers must ignore unknown `data` fields. Removing or renaming a
  field, or changing its type/meaning, is breaking (see §4).

Example (`fulfillment-execution`, topic `warehouse.fulfillment.analytics`):

```json
{ "event_type": "TaskClaimed",
  "data": { "task_id": "T-123", "station_id": "S-7", "task_type": "Pick" } }

{ "event_type": "TaskCompleted",
  "data": { "task_id": "T-123", "station_id": "S-7", "task_type": "Pick",
            "work_unit_id": "O-99" } }

{ "event_type": "WeightDiscrepancyDetected",
  "data": { "package_id": "P-5", "expected_g": 1200, "actual_g": 1500 } }
```

Each service documents its own `data` shapes in its
`docs/docs/analytics/<report>.md` (per-service report contract).

---

## 4. Versioning

- **Additive `data` change** (new optional field): no version bump. Ship it.
- **Breaking `data` change** (remove/rename/retype a field, or change its meaning):
  publish the new shape under a **new `event_type`** (e.g. `TaskCompletedV2`) OR bump
  the whole analytics topic to `warehouse.<ctx>.analytics.v2`. Prefer a new
  `event_type` for a single event; reserve a topic bump for a wholesale envelope change.
- **Envelope structural change** (a new required top-level field, changed semantics):
  bump `schema_version` and the topic suffix together; run both topics until all
  projectors have cut over.

Consumers MUST tolerate: unknown `event_type` (skip), unknown `data` fields (ignore),
and out-of-order duplicates (dedupe on `event_id`).

---

## 5. Per-service registry

Each service registers, in its ADR and report doc, the two facts below. Filled in as
each service ships its report (Phase 1/2/3 of the analytics plan).

| Service (`<ctx>`) | Analytics topic | Report-input `event_type`s |
|---|---|---|
| fulfillment-execution (`fulfillment`) | `warehouse.fulfillment.analytics` | TaskCreated, TaskClaimed, LeaseExpired, TaskCompleted, ItemPicked, PackageSealed, WeightDiscrepancyDetected, LabelApplied, PackageDiverted *(confirm vs events.go)* |
| wes-work-planning (`wes`) | `warehouse.wes.analytics` | *(TBD — confirm from events.go)* |
| order-management (`order`) | `warehouse.order.analytics` | *(TBD)* |
| inventory-storage (`inventory`) | `warehouse.inventory.analytics` | *(TBD)* |
| facility-layout (`facility`) | `warehouse.facility.analytics` | *(TBD — needs Kafka enabled first)* |
| workforce-management (`workforce`) | `warehouse.workforce.analytics` | *(TBD)* |

---

## 6. Non-goals

- No central schema registry (kept simple — this doc IS the registry).
- No Avro/Protobuf for now; JSON envelope. If schema enforcement becomes necessary,
  a registry can be introduced behind the same envelope without changing consumers.
- No cross-service DB reads, ever. The analytics topic is the only seam.
