# Kafka DLQ runbook: triage and redrive with scripts/dlq-redrive.sh

Status: active (2026-10-17)

## What a dead-letter queue entry is

Every fleet consumer dead-letters a poison message instead of blocking its
partition: the message is republished unchanged to `<source-topic>.dlq` with
three diagnostic headers added:

| Header | Meaning |
|---|---|
| `x-dlq-source-topic` | The topic the message originally arrived on — the redrive target. |
| `x-dlq-error` | The consumer's error string, verbatim. This is the triage key. |
| `x-dlq-failed-at` | RFC3339 UTC timestamp of the failed delivery attempt. |

The message body is untouched: a CloudEvents 1.0 event in structured content
mode, so the envelope attributes (`id`, `type`, `source`, `time`) are inside
the JSON value. The DLQ is a backlog, not an archive — messages stay there
until someone triages and either redrives or discards them.

## Broker access (the only supported path)

The single in-cluster broker advertises in-cluster DNS, so `kubectl
port-forward` does not work. All Kafka CLI access runs inside the broker pod:

```
kubectl exec -n warehouse-systems kafka-controller-0 -c kafka -- \
  bash -c 'env KAFKA_HEAP_OPTS=-Xmx128m kafka-topics.sh --bootstrap-server localhost:9092 --list'
```

The `KAFKA_HEAP_OPTS=-Xmx128m` prefix is mandatory (`.claude/rules/events-cloudevents.md`):
the CLI tools share the broker container's memory limit and their full-heap
defaults have OOMKilled the broker before. `scripts/dlq-redrive.sh` applies it
to every call it makes. Expect a `TimeoutException` ERROR line at the end of
each scan — that is the console consumer's normal "topic drained" exit, not a
failure.

## Triage

Start wide, then narrow:

```
# Every .dlq topic with its message count and x-dlq-error values grouped:
scripts/dlq-redrive.sh --list

# One DLQ, no filters — partition/offset/timestamp/error/type/CloudEvents id
# of every message, nothing republished:
scripts/dlq-redrive.sh --topic warehouse.slotting-optimization.events.dlq

# Narrow by error substring, CloudEvents type suffix, CreateTime, or count:
scripts/dlq-redrive.sh --topic warehouse.slotting-optimization.events.dlq \
  --error "unknown process path" --type SlotPlanApproved --since 2026-10-14T00:00:00Z --max 5
```

Dry-run is the default. The tool refuses any `--topic` that does not match
`warehouse.*.dlq`, and never writes to a `.dlq` topic.

## The 2026-10-14 population (worked example)

The first population the fleet ever had, still sitting in the DLQs today —
20 messages across 5 topics, all dead-lettered on 2026-10-14:

| DLQ topic | Count | `x-dlq-error` |
|---|---|---|
| `warehouse.slotting-optimization.events.dlq` | 7 | `pathcatalog: unknown process path id` |
| `warehouse.order-management.events.dlq` | 4 | `pathcatalog: unknown process path id` |
| `warehouse.workforce.events.dlq` | 4 | `pathcatalog: unknown process path id` |
| `warehouse.network-inventory-planning.events.dlq` | 3 | `pathcatalog: unknown process path id` |
| `warehouse.fulfillment.events.dlq` | 2 | `work unit is already completed` |

Triage of the two error classes:

- `pathcatalog: unknown process path id` (18 messages): the receiving
  consumers rejected these events because the process-path catalogue had no
  entry for the referenced path id. That is an environment/configuration
  failure, not message corruption — once the missing catalogue entries exist
  (seeded via `scripts/seed-process-paths.py`), these are exactly the
  messages a redrive recovers. Real dry-run excerpt from the slotting DLQ:

  ```
  p=5  o=0  2026-10-14T15:25:30.983Z
      err="pathcatalog: unknown process path id"
      type=com.warehouse.wms.slotting-optimization.slotplan.SlotPlanApproved
      id=cdf68e4f-3ef9-4b82-9ada-c51e6c6be584
      target=warehouse.slotting-optimization.events
  ==> selected 7 of 7 message(s) from warehouse.slotting-optimization.events.dlq
  ```

- `work unit is already completed` (2 messages in the fulfillment DLQ): the
  work unit each event targeted was already in a terminal state when the
  consumer processed it. Redrive is pointless-to-harmless here: the consumer
  will either dedupe on the CloudEvents `id` (no-op) or dead-letter again for
  the same reason. Leave these unless the business explicitly re-opens the
  work units.

## When to redrive vs leave

Redrive only messages whose underlying cause is FIXED. A redrive does not
repair anything — it replays the same bytes to the same topic, so:

- Cause fixed (missing catalogue entry seeded, bug patched and deployed,
  downstream restored) → redrive the affected slice, filtered as tightly as
  the dry-run allows.
- Cause not fixed → the message dead-letters again, doubling DLQ traffic and
  consumer load for zero effect. Leave it and revisit after the fix.
- Poison message (genuinely malformed event that will never pass) → do not
  redrive; that is a producer bug to fix at the source.

Redrive is cheap to re-run but not free: each pass re-consumes the whole DLQ
topic and re-produces each selected message.

## The headers-dropped caveat (read before any --execute)

`kafka-console-producer.sh` cannot write Kafka record headers. A redriven
message arrives on the source topic WITHOUT `x-dlq-*`, `traceparent`, and
`content-type: application/cloudevents+json`. This is accepted and safe
because every fleet message is structured-mode CloudEvents: the `id`
attribute lives inside the JSON value, is stable across redelivery, and
every fleet consumer dedupes on it. A consumer that already processed the
event treats the redelivery as a no-op — that idempotency, not headers, is
what makes redrive re-runnable. Values are single-line JSON (control
characters escaped), which is what makes the consumer→producer line piping
safe.

## Executing a redrive (two-person operation)

Redrive in production is a two-person operation:

1. Operator runs the DRY-RUN with the exact filters intended for execution.
2. A second person reviews the dry-run output: right messages, right count,
   right target source topic, and the root cause actually fixed.
3. Only then does the operator add the execute flags:

```
scripts/dlq-redrive.sh --topic warehouse.slotting-optimization.events.dlq \
  --error "unknown process path" --execute --yes
```

`--execute` without `--yes` refuses and exits 2 — the tool will not let a
bare flag slip through. Before the first write it prints the target source
topic and total count (validating every target first: it must be a
`warehouse.*` topic and must not end in `.dlq`), prints per-message progress,
and repeats the target+count summary at the end.

After a redrive, re-run `--list`: the redriven messages still sit in the DLQ
(the tool never deletes anything — log retention handles that eventually);
what should change is that a follow-up dry-run of the source topic's
consumers shows the events processed. If messages re-appear in the DLQ with
fresh `x-dlq-failed-at`, the cause was not fixed — stop and re-triage.
