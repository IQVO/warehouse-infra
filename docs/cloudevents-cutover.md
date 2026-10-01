# CloudEvents 1.0 cutover runbook (flat envelope -> CloudEvents, no coexistence)

Status: **Ready to execute once all 9 service PRs are approved** (2026-09-30)

Fleet standard: CloudEvents 1.0 (structured content mode, Kafka protocol
binding) is the ONLY event envelope on every `warehouse.<ctx>.events` and
`warehouse.<ctx>.analytics` topic. There is no flat envelope, no dual-write,
no dual-read and no envelope toggle env var (`EVENT_ENVELOPE_MODE` is gone
and must never be configured here). The full standard, including the
subdomain table and the cross-service `type` catalogue, lives in
warehouse-docs (`docs/strategic-design/event-standard-cloudevents.md`) and
in each service's own "CloudEvents 1.0 as the mandatory event envelope" ADR.

Because consumers accept ONLY CloudEvents after the cutover and every
consumer that replays from `FirstOffset` (process-path catalogue caches,
facility location cache, CPT-schedule / path-capacity / labor-performance
caches, every analytics projector) would otherwise read the old flat
messages back, the cutover is a **stop-the-world** change for the event
plane:

1. merge everything,
2. stop every producer/consumer after its outbox has drained,
3. wipe the business topics,
4. reset the analytics read models,
5. start the new images,
6. re-seed the catalogue so the topics hold CloudEvents only.

Every command below targets the local `kind` cluster
(`--context kind-warehouse`), namespace `warehouse-systems` for workloads
and `warehouse-data` for Postgres. The Kafka commands run against the real
in-cluster broker (`kafka-controller-0`, container `kafka`), not a
docker-compose broker.

```bash
export KCTX=kind-warehouse
export NS=warehouse-systems
export DATA_NS=warehouse-data
# The Kafka CLI tools are JVMs that run INSIDE the broker container and share
# its 1Gi memory limit. Without a small heap, a heavy call (e.g.
# `kafka-consumer-groups.sh --describe --all-groups` against the hundreds of
# per-process catalogue groups) can get the broker itself OOMKilled — this
# happened while this runbook was being written. Always cap the CLI heap.
K() { kubectl --context "$KCTX" -n "$NS" exec kafka-controller-0 -c kafka -- env KAFKA_HEAP_OPTS="-Xmx128m" "$@"; }
PSQL() {  # PSQL <db> <sql>
  kubectl --context "$KCTX" -n "$DATA_NS" exec postgres-postgresql-0 -- \
    bash -c 'PGPASSWORD="$(cat "$POSTGRES_PASSWORD_FILE")" psql -U postgres -d "$0" -Atc "$1"' "$1" "$2"
}
```

---

## 0. Inventory (what this runbook covers)

| Repo (ArgoCD Application) | OLTP DB | Deployments that touch Kafka | Topics it produces |
|---|---|---|---|
| facility-layout | `facility_layout` | `facility-layout`, `facility-layout-projector` | `warehouse.facility.events`, `warehouse.facility.analytics` |
| inventory-storage | `inventory_storage` | `inventory-storage`, `inventory-storage-projector` | `warehouse.inventory.events`, `warehouse.inventory.analytics` |
| order-management | `order_management` | `order-management`, `order-management-projector` | `warehouse.order-management.events`, `warehouse.order-management.analytics` |
| process-path-management | `process_path_management` | `process-path-management`, `process-path-management-projector` | `warehouse.process-path-management.events`, `warehouse.process-path-management.analytics` |
| network-fulfillment | `network_fulfillment` | `network-fulfillment`, `network-fulfillment-projector` | `warehouse.network-fulfillment.events`, `warehouse.network-fulfillment.analytics` |
| labor-performance | `labor_performance` | `labor-performance`, `labor-performance-projector` | `warehouse.labor-performance.events`, `warehouse.labor-performance.analytics` |
| workforce-management | `workforce_management` | `workforce-management`, `workforce-management-projector` | `warehouse.workforce.events`, `warehouse.workforce.analytics` |
| fulfillment-execution | `fulfillment_execution` | `fulfillment-execution`, `fulfillment-execution-projector` | `warehouse.fulfillment.events` (+ `warehouse.fulfillment.events.dlq`), `warehouse.fulfillment.analytics` |
| wes-work-planning | `wes_work_planning` | `wes-work-planning`, `wes-work-planning-projector` | `warehouse.work-planning.events`, `warehouse.wes.analytics` |

The `*-mcp`, `*-reports` and `*-frontend` Deployments have no Kafka I/O
(verified: no `cmd/mcp` / `cmd/*-reports` binary imports a Kafka client)
and can stay up. warehouse-ops-agent has no Kafka I/O either.

Every OLTP repo's outbox table is **`outbox_events`** with a nullable
`published_at` column (`published_at IS NULL` = not yet relayed; there is a
partial index `idx_outbox_events_unpublished` on exactly that predicate).
Source migrations: facility-layout `0005_outbox`, inventory-storage
`0005_transactional_outbox`, order-management `0007_outbox`,
process-path-management `0002_outbox` (+`0003_outbox_topic`),
network-fulfillment `0002_outbox`, labor-performance `0002_outbox`,
workforce-management `000002_outbox`, fulfillment-execution `0009_outbox`,
wes-work-planning `0005_outbox`.

Partition counts to recreate with: **8 partitions, replication factor 1**
for every business topic (`docs/kafka-partition-scaleup.md`;
`terraform/kafka.tf` sets the broker default `num.partitions = 8`).
`__consumer_offsets` is never touched.

---

## 1. Merge all 9 service PRs (and this infra PR)

All 9 `feat(events)!: CloudEvents 1.0 mandatory envelope` PRs must be
green and merged into `develop` **together** (the local cluster is built from
`develop`, see step 7; a `main` release only matters for published GHCR
images). A partial merge leaves a CloudEvents producer
talking to a flat-only consumer (or vice versa): messages get DLQ'd/skipped
and cross-context flows silently stop.

Checklist before going further:

```bash
for r in facility-layout inventory-storage order-management process-path-management \
         network-fulfillment labor-performance workforce-management \
         fulfillment-execution wes-work-planning; do
  printf '%-26s ' "$r"
  gh pr list -R "claudioed/$r" --head feature/cloudevents-mandatory --state merged \
     --json number,mergedAt --jq '.[0] | "#\(.number) merged \(.mergedAt)"'
done
```

Every line must show a merged PR. Do NOT proceed with any line empty.
(No `main` release is needed for the local cluster: step 7 builds from the
local checkouts, not from published GHCR images.)

Also confirm no repo still references the toggle:

```bash
for r in facility-layout inventory-storage order-management process-path-management \
         network-fulfillment labor-performance workforce-management \
         fulfillment-execution wes-work-planning warehouse-infra; do
  git -C ~/warehouse-systems/$r fetch -q origin
  git -C ~/warehouse-systems/$r grep -n EVENT_ENVELOPE_MODE origin/develop && echo "!! $r still has it"
done
```

## 2. Freeze ArgoCD auto-sync

Every service Application has `syncPolicy.automated.selfHeal = true`
(`terraform/argocd-apps.tf`), so a manual `kubectl scale` is reverted
within seconds. Suspend auto-sync for the cutover window:

```bash
for app in facility-layout inventory-storage order-management process-path-management \
           network-fulfillment labor-performance workforce-management \
           fulfillment-execution wes-work-planning; do
  kubectl --context "$KCTX" -n argocd patch application "$app" --type merge \
    -p '{"spec":{"syncPolicy":{"automated":null}}}'
done
kubectl --context "$KCTX" -n argocd get applications
```

(Re-enabled by the next `terraform apply` in step 7, which re-renders the
Application CRs with `automated: {prune: true, selfHeal: true}`.)

## 3. Stop write traffic and drain every outbox

Outbox rows were encoded in the **flat** shape at insert time. A new image
relaying an old row would publish a flat message onto a CloudEvents-only
topic, so every outbox must be fully drained by the OLD image first.

3a. Stop inbound write traffic (stop load generators, e2e runs, the
console). Then wait for the old relays to drain:

```bash
for db in facility_layout inventory_storage order_management process_path_management \
          network_fulfillment labor_performance workforce_management \
          fulfillment_execution wes_work_planning; do
  printf '%-26s unpublished=' "$db"
  PSQL "$db" "SELECT count(*) FROM outbox_events WHERE published_at IS NULL"
done
```

Repeat until **every** line prints `unpublished=0`. If a count is not
falling, look at the relay errors:

```bash
PSQL order_management "SELECT topic, event_type, count(*), max(attempts), left(max(last_error),200)
  FROM outbox_events WHERE published_at IS NULL GROUP BY 1,2 ORDER BY 3 DESC"
```

> Snapshot taken 2026-09-30 while writing this runbook: `inventory_storage`
> had 76 972 and `order_management` 604 677 unpublished rows (all from a
> 2026-09-28 load test, `attempts = 0`, i.e. the relay never picked them
> up — order-management's pod was CrashLooping), `wes_work_planning` 2.
> These are load-test leftovers. If they will not drain, the operator may
> decide to discard them instead (step 3b) — the topics are wiped in step 5
> anyway, so draining them only matters for consumers' read models, which
> are also reset.

3b. **Only if** a backlog cannot be drained and the operator accepts losing
those not-yet-published events (local study cluster, data is rebuilt), mark
them published so the NEW relay never re-sends the flat bytes:

```bash
PSQL <db> "UPDATE outbox_events SET published_at = now(), last_error = 'discarded at CloudEvents cutover'
           WHERE published_at IS NULL"
```

Never leave a row with `published_at IS NULL` and a flat `value` in place
when the new image starts.

3c. Scale every OLTP service and projector to 0 (keep the `-mcp`,
`-reports`, `-frontend` Deployments up):

```bash
SVCS="facility-layout inventory-storage order-management process-path-management \
      network-fulfillment labor-performance workforce-management \
      fulfillment-execution wes-work-planning"
for s in $SVCS; do
  kubectl --context "$KCTX" -n "$NS" scale deploy "$s" "$s-projector" --replicas=0
done
kubectl --context "$KCTX" -n "$NS" get deploy | grep -vE 'frontend|mcp|reports|console|gateway|ops-agent'
```

Re-run the step 3a query once everything is at 0/0: all must still be 0
(the scale-down itself can flush a last batch).

## 4. Confirm no consumer group is active

```bash
K kafka-consumer-groups.sh --bootstrap-server localhost:9092 --list \
  | grep -vE -- '-[0-9]{15,}$'          # long-lived groups only
for g in $(K kafka-consumer-groups.sh --bootstrap-server localhost:9092 --list | grep -vE -- '-[0-9]{15,}$'); do
  K kafka-consumer-groups.sh --bootstrap-server localhost:9092 --describe --state --group "$g" \
    | awk -v g="$g" 'NR>1 && NF {print g, $0}'
done | grep -E 'Stable|Rebalance' || echo "no active long-lived group"
```

The loop must print `no active long-lived group`. (Describe groups one at
a time, not with `--all-groups` — see the heap note at the top.)
Topic deletion with live members is allowed by Kafka but the members
immediately auto-recreate the topic (every writer runs
`AllowAutoTopicCreation: true`), possibly with flat messages from an old pod.

## 5. Delete and recreate every business topic

The topic set (verified live with `kafka-topics.sh --list`, plus
network-fulfillment's integration topic, which its outbox addresses but
which is only auto-created on first publish):

```bash
TOPICS="
warehouse.facility.events                  warehouse.facility.analytics
warehouse.inventory.events                 warehouse.inventory.analytics
warehouse.order-management.events          warehouse.order-management.analytics
warehouse.process-path-management.events   warehouse.process-path-management.analytics
warehouse.network-fulfillment.events       warehouse.network-fulfillment.analytics
warehouse.labor-performance.events         warehouse.labor-performance.analytics
warehouse.workforce.events                 warehouse.workforce.analytics
warehouse.fulfillment.events               warehouse.fulfillment.analytics
warehouse.fulfillment.events.dlq
warehouse.work-planning.events             warehouse.wes.analytics
"
# Anything else matching the patterns that this list missed? (must print nothing)
K kafka-topics.sh --bootstrap-server localhost:9092 --list \
  | grep -E '^warehouse\..*\.(events|analytics)(\.dlq)?$' \
  | grep -vxF -f <(printf '%s\n' $TOPICS)
```

Delete:

```bash
for t in $TOPICS; do
  K kafka-topics.sh --bootstrap-server localhost:9092 --delete --if-exists --topic "$t"
done
# deletion is async — wait until none of them is listed any more
K kafka-topics.sh --bootstrap-server localhost:9092 --list | grep -E '^warehouse\.' || echo "all deleted"
```

Recreate with the documented partition count (8) and replication factor (1):

```bash
for t in $TOPICS; do
  K kafka-topics.sh --bootstrap-server localhost:9092 --create --if-not-exists \
    --topic "$t" --partitions 8 --replication-factor 1
done
K kafka-topics.sh --bootstrap-server localhost:9092 --describe \
  | grep -E '^Topic: warehouse\.' | awk '{print $2, $6, $8}'
```

Every line must read `<topic> 8 1` (PartitionCount 8, ReplicationFactor 1),
and every topic must be empty:

```bash
for t in $TOPICS; do
  printf '%-46s ' "$t"
  K kafka-get-offsets.sh --bootstrap-server localhost:9092 --topic "$t" \
    | awk -F: '{s+=$3} END {print "messages=" s+0}'
done
```

## 6. Reset consumer state (analytics read models + consumer groups)

Deleting a topic does **not** delete committed offsets of the fixed-name
consumer groups. On the recreated topics those offsets are past the new
log end, so kafka-go falls back to its `StartOffset` — but rely on a clean
reset rather than on that fallback.

6a. Delete the fixed-name consumer groups (names verified live and against
each repo's `GroupID` constants):

```bash
for g in facility-analytics inventory-analytics order-management-analytics \
         process-path-management-analytics labor-performance-analytics \
         workforce-analytics fulfillment-analytics wes-analytics \
         fulfillment-execution wes-work-planning labor-performance \
         order-management-repromise; do
  K kafka-consumer-groups.sh --bootstrap-server localhost:9092 --delete --group "$g" || true
done
# network-fulfillment's projector uses a prefixed group (network-fulfillment-analytics*):
K kafka-consumer-groups.sh --bootstrap-server localhost:9092 --list \
  | grep '^network-fulfillment-analytics' \
  | while read -r g; do K kafka-consumer-groups.sh --bootstrap-server localhost:9092 --delete --group "$g"; done
```

The per-process `uniqueConsumerGroup()` groups (catalogue / CPT-schedule /
path-capacity / facility-cache / labor-performance-cache consumers, names
ending in a 19-digit nanosecond suffix) always start from `FirstOffset`
and need no reset; delete them only to tidy up:

```bash
K kafka-consumer-groups.sh --bootstrap-server localhost:9092 --list \
  | grep -E -- '-[0-9]{15,}$' \
  | while read -r g; do K kafka-consumer-groups.sh --bootstrap-server localhost:9092 --delete --group "$g"; done
```

6b. Truncate the analytics read models. They were projected from the
flat-envelope analytics topics, which no longer exist; the dedupe tables
(`analytics_processed_events`, `analytics_consumed_events`) are keyed on
the old flat `event_id`s. Truncate every non-migration table in each
`*_analytics` database (table lists verified live 2026-09-30):

```bash
PSQL facility_layout_analytics         "TRUNCATE analytics_consumed_events, analytics_processed_events, catalog_growth_rollup"
PSQL fulfillment_execution_analytics   "TRUNCATE analytics_consumed_events, analytics_pending_claims, analytics_processed_events, throughput_rollup"
PSQL inventory_storage_analytics       "TRUNCATE analytics_consumed_events, analytics_processed_events, flow_accuracy_rollup"
PSQL labor_performance_analytics       "TRUNCATE analytics_consumed_events, analytics_processed_events, labor_performance_rollup"
PSQL network_fulfillment_analytics     "TRUNCATE acknowledgement_rollup, analytics_consumed_events, analytics_processed_events"
PSQL order_management_analytics        "TRUNCATE analytics_consumed_events, analytics_processed_events, funnel_rollup, repromise_rollup"
PSQL process_path_management_analytics "TRUNCATE analytics_consumed_events, analytics_processed_events, catalogue_growth_rollup"
PSQL wes_work_planning_analytics       "TRUNCATE analytics_consumed_events, analytics_processed_events, throughput_rollup"
PSQL workforce_management_analytics    "TRUNCATE analytics_consumed_events, analytics_pending_breaks, analytics_processed_events, labor_rollup"
```

If a service PR added an analytics migration, re-list first and include
any new non-`schema_migrations*` table:

```bash
PSQL <db>_analytics "SELECT tablename FROM pg_tables WHERE schemaname='public' AND tablename NOT LIKE 'schema_migrations%'"
```

6c. Integration-side processed-event / inbox tables in the OLTP databases
(if a consumer keeps one) hold old flat `event_id`s; they cannot collide
with new CloudEvents UUIDs and can be left as is.

## 7. Deploy the new images

Images are NOT pulled from a registry. `terraform/services.tf` (and
`network-fulfillment.tf`) run `scripts/build-and-load.sh`, which
`docker build`s each service from its LOCAL checkout at
`~/warehouse-systems/<repo>` (`${path.module}/../../<repo>`) and
`kind load`s it; the image tag is a hash of that checkout's `*.go` +
`migrations/**`. Whatever is checked out locally is what ships, including
another branch or uncommitted work.

7a. Put every service checkout on the merged `develop` HEAD, clean:

```bash
for s in $SVCS; do
  d=~/warehouse-systems/$s
  git -C "$d" fetch -q origin
  if [ -n "$(git -C "$d" status --porcelain --untracked-files=no)" ]; then
    echo "!! $s has uncommitted tracked changes -- stash/commit them first"; continue
  fi
  git -C "$d" checkout -q develop && git -C "$d" merge -q --ff-only origin/develop
  printf '%-26s %s %s\n' "$s" "$(git -C "$d" branch --show-current)" \
    "$(git -C "$d" rev-parse --short HEAD)"
done
```

Every line must show `develop` at `origin/develop`'s sha and none may
print `!!`. Untracked files (`.schemathesis/`, `node_modules/`) do not
change the hash and are not copied into the image (`.dockerignore`), so they
can stay. Sanity-check the CloudEvents code is really what will be built:

```bash
for s in $SVCS; do
  printf '%-26s sdk=%s flat=%s\n' "$s" \
    "$(grep -c cloudevents/sdk-go ~/warehouse-systems/$s/go.mod)" \
    "$(grep -rlE 'json:"event_type"|EVENT_ENVELOPE_MODE' ~/warehouse-systems/$s/internal ~/warehouse-systems/$s/cmd 2>/dev/null | grep -v _test | wc -l | tr -d ' ')"
done   # every line: sdk=1 flat=0
```

7b. Build, side-load and roll out:

```bash
cd ~/warehouse-systems/warehouse-infra
git checkout -q develop && git pull -q --ff-only origin develop
terraform -chdir=terraform plan  -out=cutover.plan
terraform -chdir=terraform apply cutover.plan
```

The apply rebuilds every service whose source hash changed (all nine do),
side-loads the images, re-renders the ArgoCD Applications with the new
content-hash tags (re-enabling auto-sync from step 2), and Argo rolls the
Deployments and restores replica counts. Confirm every Deployment runs the
new tag and rolled:

```bash
kubectl --context "$KCTX" -n "$NS" get deploy -o custom-columns=NAME:.metadata.name,IMAGE:.spec.template.spec.containers[0].image \
  | grep -vE 'frontend|console|gateway'
for s in $SVCS; do
  kubectl --context "$KCTX" -n "$NS" rollout status deploy "$s" --timeout=300s
  kubectl --context "$KCTX" -n "$NS" rollout status deploy "$s-projector" --timeout=300s
done
kubectl --context "$KCTX" -n argocd get applications
```

Every Application must be `Synced`/`Healthy`. Confirm no pod got an
envelope toggle:

```bash
kubectl --context "$KCTX" -n "$NS" get deploy -o json \
  | grep -c EVENT_ENVELOPE_MODE   # must print 0
```

## 8. Re-seed the process-path catalogue

The process-path topic is now empty, so every catalogue consumer
(fulfillment-execution, wes-work-planning, workforce-management,
order-management) would replay an empty catalogue. `scripts/seed-process-paths.py`
drives process-path-management's **REST API** (it does not produce Kafka
messages itself), so the service's new image emits the CloudEvents. The
paths already exist in its store, so `--republish` is required to put them
back on the topic:

```bash
kubectl --context "$KCTX" -n "$NS" port-forward svc/process-path-management 18080:80 &
PF=$!
./scripts/seed-process-paths.py --base-url http://localhost:18080 --republish
kill $PF
```

Also re-publish anything else a consumer replays from `FirstOffset` and
that exists in a store today:

- CPT schedules (`CPTScheduleChanged`, consumed by order-management):
  re-`PUT /sites/{siteId}/cpt-schedule` for each defined site (a no-op PUT
  does NOT republish — change and restore, as the seed script does for
  paths). 0 schedules defined at time of writing.
- facility-layout slots/zones (`LocationSlotRegistered`, `ZoneRegistered`,
  consumed by inventory-storage): 0 rows at time of writing.

Then restart the catalogue consumers so their readiness gates replay the
new topic (they gate readiness on reaching the high-water mark):

```bash
for s in fulfillment-execution wes-work-planning workforce-management order-management; do
  kubectl --context "$KCTX" -n "$NS" rollout restart deploy "$s"
  kubectl --context "$KCTX" -n "$NS" rollout status  deploy "$s" --timeout=300s
done
```

## 9. Verify

9a. The catalogue topic carries CloudEvents in structured mode, with the
`content-type` header:

```bash
K kafka-console-consumer.sh --bootstrap-server localhost:9092 \
  --topic warehouse.process-path-management.events --from-beginning \
  --max-messages 3 --timeout-ms 15000 \
  --property print.key=true --property print.headers=true
```

Each line is `<headers>\t<key>\t<value>`. Before the cutover it reads
`NO_HEADERS\tPICK\t{"data":…,"source":"process-path-management","event_id":…,"event_type":"ProcessPathCreated",…}`
(the flat envelope — verified live 2026-09-30). After the cutover the
headers column must contain
`content-type:application/cloudevents+json; charset=UTF-8` (plus
`traceparent`), and the value must be shaped like:

```json
{"specversion":"1.0","id":"<uuid>","source":"/warehouse/process-path-management",
 "type":"com.warehouse.wes.process-path-management.processpath.ProcessPathUpdated",
 "subject":"<pathId>","time":"2026-…Z","datacontenttype":"application/json",
 "dataschema":"urn:warehouse:process-path-management:events:ProcessPathUpdated:v1",
 "data":{…}}
```

9b. Fleet-wide sweep — no flat message anywhere. After driving a little
traffic (an e2e run, or an order through the console), sample every topic
and fail on any message that is not CloudEvents 1.0:

```bash
for t in $TOPICS; do
  out=$(K kafka-console-consumer.sh --bootstrap-server localhost:9092 --topic "$t" \
          --from-beginning --max-messages 20 --timeout-ms 8000 \
          --property print.headers=true 2>/dev/null)
  n=$(printf '%s\n' "$out" | grep -c '"specversion":"1.0"')
  bad=$(printf '%s\n' "$out" | grep -c '"event_type"')
  hdr=$(printf '%s\n' "$out" | grep -c 'content-type:application/cloudevents+json')
  printf '%-46s cloudevents=%s with-content-type=%s flat=%s\n' "$t" "$n" "$hdr" "$bad"
done
```

Every topic with traffic must show `cloudevents == with-content-type` and
`flat=0`. (`warehouse.fulfillment.events.dlq` should stay empty; anything
landing there post-cutover is a real defect — inspect it.)

9c. No consumer is rejecting messages:

```bash
kubectl --context "$KCTX" -n "$NS" logs -l app.kubernetes.io/component --since=15m --prefix --all-containers \
  | grep -iE 'cloudevent|invalid event|poison|dlq' | head
for g in $(K kafka-consumer-groups.sh --bootstrap-server localhost:9092 --list | grep -vE -- '-[0-9]{15,}$'); do
  K kafka-consumer-groups.sh --bootstrap-server localhost:9092 --describe --group "$g" \
    | awk -v g="$g" 'NR>1 && $6 ~ /^[0-9]+$/ && $6 > 0 {print g, $2, $3, "lag=" $6}'
done                           # must drain to no output
```

9d. Run the e2e suite (`e2e-tests`) and the smoke/exposure gates:

```bash
bash scripts/smoke-test.sh
bash scripts/test-exposure-policy.sh
```

## Rollback

There is no in-place rollback to the flat envelope: the new consumers
reject it by design. Rolling back means the reverse of this runbook —
revert all 9 service PRs together, drain outboxes, wipe + recreate topics,
truncate analytics, redeploy, re-seed. Prefer fixing forward.
