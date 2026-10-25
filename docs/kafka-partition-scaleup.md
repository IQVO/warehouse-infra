# Kafka partition scale-up: 1 -> 8 partitions per business topic

Status: accepted (2026-09-27)

## Context

Every business Kafka topic in the fleet (the shared single-broker Bitnami
Kafka this repo deploys) was provisioned with 1 partition, confirmed live
via `kafka-topics.sh --describe --bootstrap-server localhost:9092`. A
1-partition topic caps horizontal consumer scaling at exactly one active
consumer per consumer group no matter how many replicas of a service run
(WMS production-readiness plan §3.2). `__consumer_offsets` (50 partitions)
is Kafka's own internal topic and is out of scope — untouched.

## Decision

Raise every active business topic from 1 to 8 partitions:

```
warehouse.order-management.events        warehouse.order-management.analytics
warehouse.inventory.events                warehouse.inventory.analytics
warehouse.work-planning.events            warehouse.wes.analytics
warehouse.fulfillment.events              warehouse.fulfillment.analytics
warehouse.workforce.events                warehouse.workforce.analytics
warehouse.facility.events                 warehouse.facility.analytics
warehouse.labor-performance.events        warehouse.labor-performance.analytics
warehouse.process-path-management.events  warehouse.process-path-management.analytics
                                           warehouse.network-fulfillment.analytics
```

`replication.factor` stays 1 (single-broker cluster; unrelated to this
change).

### Why `kafka-topics.sh --alter`, not `terraform apply`, for the existing 17 topics

This repo has no `kafka_topic` (or Mongey-provider) Terraform resource —
there is no `required_providers` entry for one in `versions.tf`. Every
topic here is auto-created by a service's own `kafka-go` Writer
(`AllowAutoTopicCreation: true`), so the ONLY Terraform-visible knob is
the broker's own `num.partitions` default in the `kafka.tf` Helm values
(`overrideConfiguration`). Bumping that value:

- Changes the partition count for a **newly** auto-created topic only.
- Does **nothing** to the 17 topics that already exist — Kafka has no
  "resize on next apply" semantics, and Helm/Terraform have no visibility
  into per-topic state inside the broker at all (that lives in Kafka's own
  metadata, not the Helm release).

So the existing topics were bumped **live**, directly against the broker:

```
kubectl exec -n warehouse-systems kafka-controller-0 -c kafka -- \
  kafka-topics.sh --alter --bootstrap-server localhost:9092 \
  --topic <topic> --partitions 8
```

This is safe and additive:
- Kafka partition counts can only ever be **increased**, never decreased —
  `--alter --partitions` is exactly the supported growth path, not a
  workaround.
- It does not touch existing messages, offsets, or the topic's identity
  (`TopicId` is unchanged before/after for all 17 topics — verified).
- It requires no consumer-group changes: kafka-go's default partitioner
  (murmur2, same as the Java client) simply starts hashing new/existing
  keys across 8 partitions instead of 1 going forward.

`kafka.tf`'s `overrideConfiguration["num.partitions"]` was ALSO set to
`8` in the same change, purely so Terraform's declared state doesn't
silently drift from (or fight) the live cluster: a future `terraform
apply` must not revert a fresh auto-created topic back to Kafka's own
default of 1. `terraform plan` after this change shows **zero**
Kafka/topic-related diff beyond applying that one Helm value — confirmed
against the live `kind` cluster.

## Verification

- `kafka-topics.sh --describe` after the alter: all 17 business topics
  show `PartitionCount: 8`, `TopicId` unchanged from before, replication
  factor still 1. `__consumer_offsets` untouched at 50 partitions.
- Watched every affected pod's logs for ~90s post-change: no errors, no
  rebalance-storm log lines, no `FindCoordinator`/group errors.
- Diffed restart counts fleet-wide immediately before/after the live
  `--alter` calls: **zero** pods restarted from the partition change
  itself. (A later, SEPARATE step — applying the Terraform
  `num.partitions` Helm-value change via `terraform apply -target=
  helm_release.kafka` — triggered a real Kafka broker pod upgrade/restart,
  which in turn re-triggered the ALREADY-KNOWN, ALREADY-DOCUMENTED
  boot-time dial-reset bug (plan §2.1: every pod's first outbound Kafka/
  Postgres dial after a Kafka restart hits `connection reset by peer`) on
  a handful of dependents — `order-management`, `labor-performance`, and
  its projector. Each recovered on its own retry/backoff within seconds
  and is `Running` and healthy; this is the pre-existing bug the plan
  already tracks as an open issue, not a regression from this change.)
- `terraform plan` after applying the Helm value: no pending diff on
  `helm_release.kafka` or any topic-related resource (remaining plan diff
  is pre-existing, unrelated drift — rebuilt local Docker image hashes for
  every service's `null_resource.build_and_load`, and the already-known
  `warehouse-ops-agent` missing-`ANTHROPIC_API_KEY` check-block warning).
- `make check` (tf-fmt-check, tf-validate, helm-lint, shellcheck,
  chart-selector-check): all green.

## Producer partition-key audit (round-robin risk on ordered topics)

The scalability plan (§3.2) flags a real risk this change newly exposes:
going from 1 partition to 8 means a producer that publishes **without** a
partition key now scatters an aggregate's events across partitions in
whatever order the broker/round-robin picks — per-aggregate ordering,
which was accidentally guaranteed by there only ever being one partition,
breaks. Every outbound Kafka publisher in the fleet was read to check.

**Producers that DO set a correct aggregate-scoped key (safe today):**

| Repo | File | Key |
|---|---|---|
| facility-layout | `internal/adapters/outbound/kafka/publisher.go`, `analytics_publisher.go` | `aggregateKey(event)` |
| process-path-management | `internal/adapters/outbound/kafka/publisher.go` (`Encode`) | `PathId` / `SiteId` |
| network-fulfillment | `internal/adapters/outbound/kafka/publisher.go`, `analytics_publisher.go` | `aggregateKey(event)` = `NetworkRef` |
| labor-performance | `internal/adapters/outbound/kafka/integration_publisher.go` | `AssociateId` |
| labor-performance | `internal/adapters/outbound/kafka/analytics_publisher.go` | `TaskType` |
| fulfillment-execution | `internal/adapters/outbound/kafka/publisher.go`, `analytics_publisher.go` | `TaskId` / `PackageId` |
| wes-work-planning | `internal/adapters/outbound/kafka/publisher.go`, `analytics_publisher.go` | `WorkUnitId` / `PathId` |
| order-management | `internal/adapters/outbound/kafka/analytics_publisher.go` | `OrderID` |
| inventory-storage | `internal/adapters/outbound/kafka/analytics_publisher.go` | `SKU` |
| workforce-management | `internal/adapters/outbound/kafka/analytics_publisher.go` | `AssociateId` / `PathId` / `BuildingId` |

**Producers publishing WITHOUT a partition key on an order-sensitive topic
(bug this partition bump newly exposes — flagged, NOT fixed here per task
scope; each is in a different repo and needs its own PR):**

1. **order-management**, `internal/adapters/outbound/kafka/publisher.go:231`
   — `kafkago.Message{Value: msg, Headers: headers}` (no `Key`). Publishes
   `OrderAllocated` / `OrderPartiallyAllocated` / `OrderRepromised` onto
   `warehouse.order-management.events`. `OrderRepromised` in particular
   must never race an earlier `OrderAllocated` for the same order — with 8
   partitions and no key, kafka-go's default round-robin balancer can now
   land them on different partitions, and a slow/lagging partition can
   deliver them out of order to a consumer. Fix: key by `OrderID`
   (the analytics publisher in the same repo already does this correctly
   — mirror it).

2. **inventory-storage**, `internal/adapters/outbound/kafka/publisher.go:151`
   — `kafkago.Message{Value: msg, Headers: headers}` (no `Key`). Publishes
   `StockReserved` / `ReservationRevoked` onto `warehouse.inventory.events`.
   A revoke racing a reserve for the same `SKU`/reservation can now land on
   different partitions. Fix: key by `SKU` (again, mirror the repo's own
   analytics publisher, which already keys by `SKU`).

3. **workforce-management**, `internal/adapters/outbound/kafka/publisher.go`
   (`Encode`, ~line 134: `Encoded{Topic: Topic, EventType:
   committed.EventName(), Value: b}`) — no `Key`, and the doc comment
   states this explicitly: *"Messages carry no key — the existing
   integration contract has none, and the outbox must reproduce the direct
   path's wire format byte-for-byte rather than change it."* Publishes one
   `ShiftPlanCommitted` message per `PathPlan` line onto
   `warehouse.workforce.events`. Multiple lines for the SAME
   `building_id`/`shift_id`/`path_id` can now be scattered across 8
   partitions instead of landing in the single-partition topic's
   guaranteed order. Fix: key by `PathId` (mirrors the repo's own
   analytics publisher). This one is explicitly called out in the
   producer's own comment as an intentional wire-format freeze, so a fix
   needs a deliberate compatibility decision (a consumer that assumes
   partition-ordering vs. one that doesn't) — flagging for a follow-up
   task, not touching it here.

None of these three ever set a key; this is not new information exposed
mid-way through the code, all three publishers are unconditionally
key-less on every event they publish to their respective topic. Every
other publisher in the fleet already keys by the correct aggregate id.

This is a real, pre-existing latent bug that the fleet's 1-partition
topology was accidentally masking — not something introduced by this
change. Filed here for a follow-up per-repo fix; out of scope for this
infra-only PR per the task's explicit instruction not to touch other
repos' producer code from this change.
