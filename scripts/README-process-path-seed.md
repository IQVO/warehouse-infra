# Seeding process-path-management from the retired YAML catalogue

`scripts/seed-process-paths.py` performs the one-way migration of
`config/process-paths/sortable-fc.yaml` into **process-path-management**
via that service's public REST API.

## Why this exists

Before process-path-management existed, `sortable-fc.yaml` was a
boot-time hard invariant read identically by fulfillment-execution,
wes-work-planning and workforce-management (see the long header comment
in the YAML itself for the full "published language" rationale).

Those three services now source the catalogue from
process-path-management's Kafka topic
(`warehouse.process-path-management.events`) whenever
`var.deploy_process_path_kafka_source` is `true` — each one replays the
topic from its earliest offset into an in-memory cache and gates its own
readiness on that replay completing.

That switch only produces a correct catalogue if the paths the building
actually runs **exist in process-path-management and were published onto
the topic**. This script is what guarantees that.

## The failure mode it was written to fix

process-path-management (like every write-side use case in this fleet)
does `Repo.Save` **then** `Publisher.Publish`, with no outbox. A path
defined while the service ran with `EVENT_PUBLISHER=log` therefore lands
in Postgres but is **never published to Kafka**.

The consumers only ever see the topic. So the store and the topic can
diverge silently, and a consumer's catalogue will be missing paths that
`GET /process-paths` cheerfully reports as `ACTIVE`.

Always verify both sides after seeding, never just the REST list:

```bash
# what the store thinks
curl -s http://localhost:8080/process-paths | jq -r '.[].pathId'

# what the consumers will actually replay
kubectl exec kafka-controller-0 -n warehouse-systems -c kafka -- \
  kafka-get-offsets.sh --bootstrap-server localhost:9092 \
  --topic warehouse.process-path-management.events
```

If the store is ahead of the topic, re-run with `--republish` (see
below).

## Usage

```bash
kubectl port-forward -n warehouse-systems svc/process-path-management 8080:80

# preview — writes nothing
./scripts/seed-process-paths.py --base-url http://localhost:8080 --dry-run

# reconcile
./scripts/seed-process-paths.py --base-url http://localhost:8080
```

It is idempotent by design and safe to re-run:

| Store state vs YAML          | Action                                        |
|------------------------------|-----------------------------------------------|
| absent                       | `POST` → publishes `ProcessPathCreated`       |
| present, identical           | nothing (no spurious `ProcessPathUpdated`)    |
| present, diverging           | `PUT` → publishes `ProcessPathUpdated`        |
| present, `DEACTIVATED`       | reported and skipped, never resurrected       |

### `--republish`

Forces a republish of paths whose stored state already matches the YAML,
for the store-ahead-of-topic case above. It works by writing a
deliberately-different `matchPrefix` and then immediately restoring the
intended one, so two `ProcessPathUpdated` events are published and the
final stored state equals the YAML.

Only use it when you know the topic is missing events — the default path
never republishes anything.

> If the restore write fails, the path is **left with a
> `-republish-nudge` matchPrefix** and the script says so loudly. Fix it
> by re-running the script normally (the nudge counts as a divergence,
> so it will be revised back).

### Deactivated paths

process-path-management treats a deactivated path as a closed historical
record — its own API has no reactivate operation and returns 422 on a
revise. A deactivated id is permanent; define a new `pathId` instead.
`--allow-reactivate` exists only to make that answer explicit rather than
silently skipping.

## Verifying the consumers actually picked it up

Seeding is not done until the three consumers reflect it. They apply
events live, so a **restart is not required and its absence is the
point**:

```bash
# 1. a path the running pods have never seen
curl -X POST http://localhost:8080/process-paths \
  -H 'Content-Type: application/json' \
  -d '{"pathId":"TEST-CUTOVER","matchPrefix":"test-cutover","direct":true,"requiredCapabilities":["test-cutover"]}'

# 2. wes-work-planning validates caller path_ids against its catalogue.
#    A suffixed form of the new path must now be ACCEPTED (not 400),
#    while a genuinely unknown id must still be rejected.
kubectl port-forward -n warehouse-systems pod/<wes-pod> 8081:8080

curl -s -o /dev/null -w '%{http_code}\n' -X POST \
  localhost:8081/paths/test-cutover-zone-1/charge \
  -H 'Content-Type: application/json' \
  -d '{"buckets":[{"cpt":"2026-09-07T12:00:00Z","quantity":10}]}'
  # expect: NOT 400 (a 500 from a later layer still proves validation passed)

curl -s -o /dev/null -w '%{http_code}\n' -X POST \
  localhost:8081/paths/never-defined-xyz/charge \
  -H 'Content-Type: application/json' \
  -d '{"buckets":[{"cpt":"2026-09-07T12:00:00Z","quantity":10}]}'
  # expect: 400 unknown-path-id

# 3. deactivate it and confirm the rejection comes back
curl -X DELETE http://localhost:8080/process-paths/TEST-CUTOVER

# 4. the pods must NOT have restarted
kubectl get pods -n warehouse-systems   # AGE unchanged, RESTARTS 0
```

Use `pick-zone-a` as a sanity control: it exercises the `matchPrefix`
rule (`id == prefix` OR `id` starts with `prefix + "-"`) against a real
fleet-shaped id rather than the bare canonical `PICK`.

## Rollback

Set `var.deploy_process_path_kafka_source = false` and re-apply. Each
consumer's `pathCatalogue` ConfigMap volume returns and
`PATH_CATALOGUE_SOURCE` goes back to `file`, reading this YAML exactly as
before. Nothing this script did needs undoing — the YAML remains the
rollback source of truth, which is why it is kept frozen rather than
deleted.
