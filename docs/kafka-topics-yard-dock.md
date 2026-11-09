# Kafka topics of dock-scheduling and yard-management: pre-create before the first sync

The fleet norm is that a topic is auto-created by the first writer (`terraform/10-platform/kafka.tf` has no topic
resources; the broker's `num.partitions=8` / replication factor 1 apply). One exception matters here: a kafka-go
**group consumer started before its topic exists is never handed the partition**, so it sits idle even after the topic
appears. `seller-inbound` already follows the same rule (`helm-values/seller-inbound.yaml`). The two yard-domain
contexts consume each other's integration topics, and each projector consumes its own `.analytics` topic, which its
own relay only creates after the first event. So the topics below are created, idempotently, **before** the first
`scripts/tf.sh app dock-scheduling apply` / `app yard-management apply` (which is when ArgoCD syncs the pods).

## What each service reads and writes

| Topic | Written by | Read by (group) |
|---|---|---|
| `warehouse.dock-scheduling.events` | dock-scheduling (relay) | yard-management (`yard-management-dock-scheduling`) |
| `warehouse.dock-scheduling.analytics` | dock-scheduling (relay) | dock-scheduling projector (`dock-scheduling-analytics`) |
| `warehouse.yard-management.events` | yard-management (relay) | dock-scheduling (`dock-scheduling-yard`) |
| `warehouse.yard-management.analytics` | yard-management (relay) | yard-management projector (`yard-management-analytics`) |
| `warehouse.facility.events` | facility-layout | dock-scheduling (`dock-scheduling-facility`), yard-management (`yard-management-facility`) |
| `warehouse.inbound-receiving.events` | inbound-receiving | dock-scheduling (`dock-scheduling-asn`), yard-management (`yard-management-inbound-receiving`) |
| `warehouse.process-path-management.events` | process-path-management | dock-scheduling (`dock-scheduling-cpt`) |

The `.dlq` topics are created on the first dead letter and need nothing. The last three rows are written by contexts
that are already deployed, so they normally exist; creating them is `--if-not-exists` and costs nothing, and it
covers a broker that was rebuilt since.

## Pre-create (run once, safe to repeat)

```bash
KCTX=k3s-multipass; NS=warehouse-systems
K() { kubectl --context "$KCTX" -n "$NS" exec kafka-controller-0 -c kafka -- env KAFKA_HEAP_OPTS="-Xmx128m" "$@"; }

for t in \
  warehouse.dock-scheduling.events warehouse.dock-scheduling.analytics \
  warehouse.yard-management.events warehouse.yard-management.analytics \
  warehouse.facility.events warehouse.inbound-receiving.events \
  warehouse.process-path-management.events; do
  K kafka-topics.sh --bootstrap-server localhost:9092 --create --if-not-exists \
    --topic "$t" --partitions 8 --replication-factor 1
done

# Every line must read "<topic> 8 1" (PartitionCount 8, ReplicationFactor 1).
K kafka-topics.sh --bootstrap-server localhost:9092 --describe \
  | grep -E '^Topic: warehouse\.(dock-scheduling|yard-management|facility|inbound-receiving|process-path-management)\.' \
  | awk '{print $2, $6, $8}'
```

8 partitions and replication factor 1 are the platform values (`kafka.tf`, `docs/kafka-partition-scaleup.md`). An
existing topic is left untouched, whatever its partition count.
