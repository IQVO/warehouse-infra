---
paths:
  - "terraform/**/*.tf"
  - "helm-values/**"
  - "scripts/**"
  - "docs/cloudevents-cutover.md"
  - "docs/analytics/**"
---

# Events: CloudEvents 1.0 is mandatory (loaded when you touch terraform/, helm-values/, scripts/ or event docs)

Every Kafka message on every topic this cluster hosts, integration `warehouse.<ctx>.events` and analytics `warehouse.<ctx>.analytics`, is a CloudEvents 1.0 event in structured content mode. This is a hard fleet rule.

- Never configure an envelope toggle: no `EVENT_ENVELOPE_MODE` or any flat/dual/cloudevents switch in `terraform/` (`local.sync_edge_env`, `services.tf`, `argocd-apps.tf`), `helm-values/` or `scripts/`. The services have no such variable; adding one is a defect.
- No flat envelope (`event_id`/`event_type`/`occurred_at`), no dual-write, no dual-read. `docs/analytics/envelope-v1.md` is SUPERSEDED.
- Wire format (useful with `kafka-console-consumer.sh --property print.headers=true`): Kafka header `content-type: application/cloudevents+json; charset=UTF-8`; attributes `specversion=1.0`, `id` (UUID, stable across outbox redelivery), `source=/warehouse/<repo>`, `type`, `subject` (aggregate id), `time` (UTC occurred-at), `datacontenttype=application/json`, `dataschema=urn:warehouse:<repo>:<events|analytics>:<EventName>:v<N>`.
- `type` is `com.warehouse.<subdomain>.<bounded-context>.<entity>.<EventName>`: `wms` for facility-layout and inventory-storage, `wes` for everything else; wes-work-planning's context segment is `work-planning`.
- Recreating a topic (8 partitions, RF 1) or replaying one needs no envelope migration step; a flat message on any topic is a defect (consumers DLQ or skip it).
- Topic wipes, outbox drains and projector resets follow `docs/cloudevents-cutover.md`.
- Inside `kafka-controller-0`, prefix Kafka CLI tools with `env KAFKA_HEAP_OPTS=-Xmx128m`; they share the broker's memory limit and `--describe --all-groups` has OOMKilled the broker.
- `scripts/seed-process-paths.py` drives process-path-management's REST API and never produces Kafka messages, so it needs no envelope logic.
- The full standard and type catalogue live in the warehouse-docs repo (page event-standard-cloudevents); each service repo carries the CloudEvents ADR in its own adr directory. Neither is in this repo.
