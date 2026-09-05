# Log Aggregation: Loki + Alloy

Status: **Accepted**

## Context

`terraform/observability.tf`'s OTel Collector config declares its `logs`
pipeline as `null`, with the comment: *"No logs backend in this stack.
Declaring an empty logs pipeline would fail validation; dropping it is the
honest thing."* That was accurate: the stack shipped traces (Jaeger) and
metrics (Prometheus/Grafana) but no log aggregation at all.

Every service already writes structured logs correctly on its own side —
`log/slog`, JSON to stdout, one object per line with `time`/`level`/`msg`
plus context fields (see e.g. `inventory-storage/LOGGING.md`) — and every
log line already carries the active trace/span ID
(`telemetry.WithTraceContext` wraps each service's `slog.Handler`). What was
missing was purely the collection side: the only way to read any of it was
`kubectl logs <pod>`, which does not search across services, does not
survive a pod restart, and requires already knowing which pod to look at.

## Decision

Add Loki (storage/query) + Alloy (collection) to the `observability`
namespace, gated behind a new `deploy_logging` variable (default `true`,
independent of the other observability components so it can be turned off
without touching traces/metrics).

**Collection path chosen: tail stdout, not OTLP.** Two ways existed to get
logs into Loki:
1. Point each service's `slog` handler at an OTLP log exporter, add a
   `logs` pipeline to the existing OTel Collector, and let Loki receive it
   over OTLP.
2. Run a node-level agent (Alloy) that tails container stdout directly and
   pushes to Loki's native push API.

(2) is what ships here. Every service already writes JSON to stdout — that
is exactly what a log-tailing agent wants, and it means **zero application
code changes** across all eight repos. (1) would have required every
service to add and wire a new exporter dependency for a benefit ((2))
already delivers: trace correlation survives regardless, because the trace
ID is already a field inside the JSON body Alloy tails, not something OTLP
transport would need to add. (1) remains available later if a service ever
needs to emit a log OTLP can see that never touches stdout — rare, and not
worth blocking this on.

**Loki runs SingleBinary mode**: one StatefulSet, `filesystem` chunk
storage, replication factor 1, no S3/GCS/Azure, no Memcached result/chunk
caches, no Loki Canary, no bundled Minio. This is the same "real but
proportionate" call this module already makes elsewhere — one Postgres
instance with several logical databases instead of per-service clusters,
Jaeger's in-memory storage instead of Elasticsearch/Cassandra.
SimpleScalable or microservices mode would buy horizontal scale nobody
needs on a laptop kind cluster at the cost of several more Deployments.

**Alloy, not Promtail.** Promtail is Grafana Labs' older log-only agent and
is now in long-term support without new features; Alloy is the current
agent and its chart already lives in the same `grafana/*` Helm repo Loki
uses, so this adds no new Helm repository to the module. Alloy runs as a
DaemonSet (one pod per node), discovering pods via
`discovery.kubernetes` and relabeling `namespace`/`pod`/`container`/`app`
(`app` reads `app.kubernetes.io/name`, the same label every chart in this
fleet already sets — Grafana's Loki queries and `kubectl get pods -l
app.kubernetes.io/name=...` agree on the same vocabulary rather than
inventing a second one).

**Retention: 24h**, matching Prometheus's own retention in this module —
not a compliance decision, just "this is a laptop and the disk is the
actual constraint."

**Grafana datasource** gets a third entry (`Loki`, alongside the existing
`Prometheus`/`Jaeger`) with a `derivedFields` regex that extracts
`trace_id` out of the raw JSON log line and turns it into a click-through
to the matching Jaeger trace — the reverse direction of the existing
Prometheus-exemplar-to-Jaeger link, so a suspicious log line and a slow
trace both land in the same two-way navigation.

## Consequences

- Any log line from any service pod is now queryable in Grafana by
  namespace/pod/container/app/level, and a log line can jump straight to
  its trace. Cross-service correlation ("show me every ERROR across the
  fleet in the last hour") becomes a LogQL query instead of eight separate
  `kubectl logs` sessions.
- No application code changed in any of the eight service repos — this is
  entirely additive infrastructure.
- `terraform destroy` cleanly removes Loki + Alloy along with everything
  else (both are ordinary `helm_release` resources with no external state);
  `terraform apply` recreates them with an empty log history each time,
  which is correct for a disposable dev cluster.
- Logs do not survive a pod restart of Loki itself (`persistence.enabled =
  false`, same as Prometheus/Jaeger) — acceptable for local dev, would need
  a PVC or object storage backend before this pattern could be reused for
  a real environment.
- One more DaemonSet pod per kind node and one more StatefulSet pod in
  `observability` — modest, bounded resource cost consistent with
  everything else already running there.
