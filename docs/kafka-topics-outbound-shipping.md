# Kafka topics of outbound-shipping: pre-create before the first sync

The fleet norm is that a topic is auto-created by the first writer (`terraform/10-platform/kafka.tf` has no topic
resources; the broker's `num.partitions=8` / replication factor 1 apply), and the service never creates topics itself.
One exception matters here: a kafka-go **group consumer started before its topic exists is never handed the
partition**, so it sits idle even after the topic appears (same rule as `docs/kafka-topics-yard-dock.md` and
`helm-values/seller-inbound.yaml`). outbound-shipping's api runs six consumers, one of them on its own
`.analytics` topic, which its own relay only creates after the first event. So the topics below are created,
idempotently, **before** the first `scripts/tf.sh app outbound-shipping apply` (which is when ArgoCD syncs the pod).

## What the service reads and writes

| Topic | Written by | Read by (group) |
|---|---|---|
| `warehouse.outbound-shipping.events` | outbound-shipping (relay, inline in the api) | exception-management (`exception-management-outbound-shipping`) |
| `warehouse.outbound-shipping.analytics` | outbound-shipping (relay) | outbound-shipping itself, LoadBoardView projector (`outbound-shipping-analytics`) |
| `warehouse.fulfillment.events` | fulfillment-execution | outbound-shipping (`outbound-shipping-fulfillment`) |
| `warehouse.dock-scheduling.events` | dock-scheduling | outbound-shipping (`outbound-shipping-dock`) |
| `warehouse.yard-management.events` | yard-management | outbound-shipping (`outbound-shipping-yard`) |
| `warehouse.process-path-management.events` | process-path-management | outbound-shipping (`outbound-shipping-cpt`) |
| `warehouse.facility.events` | facility-layout | outbound-shipping (`outbound-shipping-layout`) |

The `.dlq` topics are created on the first dead letter and need nothing. The last five rows are written by contexts
that are (or will be) deployed on their own schedule, so they may not exist yet; creating them is `--if-not-exists` and
costs nothing, and it covers a broker that was rebuilt since.

## Pre-create (run once, safe to repeat; NOT run by this change)

```bash
KCTX=k3s-multipass; NS=warehouse-systems
K() { kubectl --context "$KCTX" -n "$NS" exec kafka-controller-0 -c kafka -- env KAFKA_HEAP_OPTS="-Xmx128m" "$@"; }

for t in \
  warehouse.outbound-shipping.events warehouse.outbound-shipping.analytics \
  warehouse.fulfillment.events warehouse.dock-scheduling.events \
  warehouse.yard-management.events warehouse.process-path-management.events \
  warehouse.facility.events; do
  K kafka-topics.sh --bootstrap-server localhost:9092 --create --if-not-exists \
    --topic "$t" --partitions 8 --replication-factor 1
done

# Every line must read "<topic> 8 1" (PartitionCount 8, ReplicationFactor 1).
K kafka-topics.sh --bootstrap-server localhost:9092 --describe \
  | grep -E '^Topic: warehouse\.(outbound-shipping|fulfillment|dock-scheduling|yard-management|process-path-management|facility)\.' \
  | awk '{print $2, $6, $8}'
```

8 partitions and replication factor 1 are the platform values (`kafka.tf`, `docs/kafka-partition-scaleup.md`). An
existing topic is left untouched, whatever its partition count.
