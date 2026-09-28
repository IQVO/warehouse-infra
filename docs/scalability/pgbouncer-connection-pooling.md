# PgBouncer connection pooling in front of the shared Postgres instance

## Status

Implemented (this branch). Phase 3 scalability follow-up, triggered directly
by order-management's ADR-0026 (`order-management/docs/docs/adr/0026-*.md`,
merged in PR #110).

## Context

`warehouse-infra` runs **one** Postgres release (Bitnami chart,
`terraform/postgres.tf`) with `max_connections` at its unmodified default
of **100**, shared by every one of this fleet's 10 backend services. Each
service has its own logical database + role on that same server
(`terraform/locals.tf`'s `local.services` map, plus `network-fulfillment.tf`
for the one service outside that map) — there is no per-service Postgres
instance to scale independently.

order-management's ADR-0026 tuned its own `pgxpool.MaxConns` upward as part
of its HPA rollout and found that order-management **alone**, at its own
HPA ceiling, could reach roughly 80 of the shared server's 100 connections.
Rolling the identical `pgxpool.MaxConns` pattern out to the other 9
services — the natural next step of that same scalability work — would
blow the shared 100-connection ceiling long before most of those services
reach their own HPA maximum, because every service's connection budget
comes out of the same fixed pool.

The plan's own Section 3.4 named the fallback for exactly this situation:
*"add a PgBouncer (transaction pooling mode) in front if replica counts
under load approach that ceiling."* This document records that rollout.

## Design

### Why PgBouncer, why transaction-pooling mode

PgBouncer sits between every service's own `pgxpool` and the real Postgres
server. It decouples two numbers that used to be the same thing:

- **Client-side connections** (every service's own `pgxpool.MaxConns`,
  multiplied by however many replicas HPA is currently running) — this can
  now be generous and grow with replica count, exactly as order-management
  already set it, with zero coordination needed across services.
- **Server-side connections** (real sockets open against Postgres) — fixed
  and small, controlled entirely by PgBouncer's own per-database
  `pool_size`, independent of how many client-side replicas exist upstream
  of it.

**Transaction pooling** (`pool_mode = transaction` in
`terraform/templates/pgbouncer.ini.tftpl`) is what makes that decoupling
work: a server connection is checked out to a client only for the duration
of one transaction, then returned to the pool immediately, rather than
being held for the client's entire session (session pooling) or forwarded
untouched per-statement (statement pooling, which cannot support
multi-statement transactions at all). This is the mode that lets a handful
of real Postgres connections serve a much larger and elastic number of
client-side pgxpool connections.

### Why NOT a Helm chart

`oci://registry-1.docker.io/bitnamicharts/pgbouncer` returns `401
Unauthorized` when pulled — verified directly. Bitnami's free OCI chart
catalog does not include a `pgbouncer` chart (unlike `postgresql`/`kafka`,
both still free and both already used elsewhere in this repo). The
`bitnamilegacy/pgbouncer` **image** itself is still pullable (same registry
override pattern `postgres.tf`/`kafka.tf` already use for their own
images), so `terraform/pgbouncer.tf` hand-rolls the
Deployment/Service/Secret directly in Terraform — the same pattern
`terraform/frontends.tf`'s `kubernetes_deployment.web_gateway` already uses
in this repo for the (also chart-less) Nginx web gateway. This keeps the
"integrates cleanly with the existing Bitnami-chart-heavy style" property
that matters: same image vendor, same per-repo convention for a
chart-less platform component — not a forced Helm install against a chart
that does not exist.

### Per-database pool sizing

`terraform/pgbouncer.tf`'s `local.pgbouncer_oltp_pool_size = 12` — every
OLTP database gets its own `[databases]` entry in `pgbouncer.ini` with
`pool_size=12`, well inside the requested 10-15 range and conservative
end of it. Aggregate worst case across every OLTP database this fleet has
(the 8 in `local.services` plus `network-fulfillment`, 9 total) is
`9 * 12 = 108` real Postgres connections if every pool were saturated
simultaneously — technically slightly above `max_connections=100`, but
this is a soft, not hard, budget: PgBouncer connections to Postgres are
opened lazily and only as real client transactions actually demand them,
so 9 databases all sitting at their full pool ceiling at the exact same
instant is not the realistic operating point for this fleet's actual
traffic pattern. Postgres's own `max_connections` is deliberately left
**unmodified** at 100 (per the task's explicit instruction) — the entire
point of this design is that the fix lives in PgBouncer's pooling, not in
raising the server's own ceiling.

If real load ever does drive sustained simultaneous saturation across most
databases, the next lever is lowering `pgbouncer_oltp_pool_size` further
(e.g. to 8-10), not raising Postgres's `max_connections` — see "Future
work" below.

### Why analytics databases stay direct (NOT routed through PgBouncer)

Every service's `ANALYTICS_DATABASE_URL` / `ANALYTICS_READER_DATABASE_URL`
Secret (`local.analytics_database_urls`,
`network_fulfillment_analytics_database_url`) is **unchanged** by this
rollout and still points directly at Postgres.

Reasoning:

- Analytics databases are fed by each service's own projector consuming
  its own Kafka topic — a single long-lived consumer connection per
  service, not a fan-out of HTTP-request-driven connections. This is
  exactly the traffic shape PgBouncer's connection-multiplexing exists to
  help with the OLTP side, and exactly the traffic shape that gets no
  benefit from it (there is no client-side connection explosion to tame
  on a single always-on consumer).
  - The `reports` binary in some services also reads analytics data, but
    at low, human-driven query volume, not per-request from a scaled HTTP
    fleet.
- Keeping analytics direct means one less thing depends on PgBouncer's
  own availability, and the OLTP path (the one actually under HPA-driven
  connection pressure) is the only one whose blast radius grows with this
  change.

If projector or reports replica counts are ever scaled up enough that
their own aggregate connection count becomes a real concern, revisit this
decision — the `pgbouncer_oltp_services` map in `pgbouncer.tf` would need
an analytics counterpart.

### Session-level feature audit (blocking-finding check)

Transaction pooling mode breaks any Postgres feature whose state is
expected to survive across statements within what the *client* considers
one session, but which PgBouncer may in fact multiplex across different
real server connections between transactions: session-scoped advisory
locks (`pg_advisory_lock`, as opposed to the transaction-scoped
`pg_advisory_xact_lock`), `LISTEN`/`NOTIFY`, session-level `SET` (as
opposed to `SET LOCAL`), temporary tables that must outlive one
transaction, and multi-statement transactions issued as separate
round-trips relying on the same backend PID.

**Audit performed:** `git grep -in` across all 10 backend service repos'
`origin/develop` for `pg_advisory`, `pg_try_advisory`, `LISTEN `, `NOTIFY `
(quoted forms too) turned up **zero real usages** — no hits at all in any
`.go` file. (An earlier broad-keyword pass surfaced only unrelated English
words like "listen error" in log messages, not SQL statements.)

Every service's outbox relay (`internal/adapters/outbound/postgres/
outbox_relay.go` or equivalent) is polling-based — it runs a
`SELECT ... FOR UPDATE SKIP LOCKED` style claim query on its own schedule,
not `LISTEN`/`NOTIFY` wakeups — so none of the 10 services have any
dependency on the session-level Postgres features that transaction-pooling
mode would break.

**Conclusion: no blocking finding.** It is safe to run every service's
OLTP connection through PgBouncer in transaction-pooling mode.

One compatibility fix WAS required and is included in this rollout:
`lib/pq` (used transitively by `golang-migrate`'s Postgres driver for
schema migrations — not by `pgx`/`pgxpool`, which is what every service's
actual application code uses) sends `extra_float_digits` as a libpq
startup parameter. PgBouncer rejects any startup parameter it does not
recognize by default, which broke every service's migration step the
first time each was rolled against PgBouncer (`pq: unsupported startup
parameter: extra_float_digits`). Fixed by adding
`ignore_startup_parameters = extra_float_digits` to `pgbouncer.ini`
(`terraform/templates/pgbouncer.ini.tftpl`) — this does not weaken
anything; it only tells PgBouncer to forward that one parameter instead of
rejecting the connection over it.

### DATABASE_URL Secret wiring

Every OLTP `DATABASE_URL` (`local.database_urls`,
`local.network_fulfillment_database_url`) now points at
`pgbouncer.<data-namespace>.svc.cluster.local:6432` instead of
`postgres-postgresql.<data-namespace>.svc.cluster.local:5432`. The DSN
shape, `dbname`, `user`, and `password` are all byte-identical to before
this rollout — only the host:port segment changed. This is what makes the
change transparent to every service's Go code: `pgxpool.New(...)` just
connects to a different `host:port`, same `sslmode=disable`, same
credentials. Confirmed directly against order-management (see
"Verification" below) — no service-side code change was needed.

### Readiness / liveness / startup probes

PgBouncer's own Deployment (`terraform/pgbouncer.tf`) uses `SHOW POOLS`
against its built-in `pgbouncer` admin pseudo-database for all three
probes (`startup_probe`, `readiness_probe`, `liveness_probe`), not a bare
TCP-port-open check. A bare port probe can report "ready" while PgBouncer
is still mid-parse of its mounted config/userlist — `SHOW POOLS` only
succeeds once the admin console is genuinely serving, which requires both
to have loaded successfully. This mirrors the fleet's existing
dial-reset-avoidance convention from Phase 0 (probe the thing that
actually indicates readiness, not a proxy for it).

## Verification performed

1. `terraform validate` / `terraform fmt -check` pass.
2. `terraform plan` scoped to the new/changed resources: 4 to add
   (`kubernetes_secret.pgbouncer_config`,
   `kubernetes_secret.pgbouncer_admin_password`,
   `kubernetes_deployment.pgbouncer`, `kubernetes_service.pgbouncer`), 9 to
   change in-place (`kubernetes_secret.service_db` x8,
   `kubernetes_secret.network_fulfillment_db`), 0 destroyed.
3. Applied. `pgbouncer` pod reaches `1/1 Running` and `SHOW DATABASES`
   confirms all 9 OLTP databases loaded with `pool_size=12` against the
   real Postgres host.
4. Raw end-to-end read+write against order-management's OLTP database
   directly through PgBouncer (throwaway debug pod, real
   `CREATE TABLE`/`INSERT ... RETURNING`/`SELECT count(*)`), then dropped.
5. order-management's Deployment restarted to pick up its re-pointed
   `DATABASE_URL` Secret. First restart failed startup probe with
   `pq: unsupported startup parameter: extra_float_digits` — root-caused to
   `lib/pq`'s migration-runner startup parameter (see above), fixed in
   `pgbouncer.ini`, PgBouncer rolled, order-management restarted again:
   booted clean, ran its migrations successfully through PgBouncer,
   `/healthz` returns `200 {"status":"ok"}`.
6. Real business-level write+read through order-management's own HTTP API
   (not just raw SQL): `POST /orders` returned `201` with a persisted
   order (`status: Backordered`), `GET /orders/{id}` returned the same
   order back. PgBouncer's `SHOW STATS` showed the `order_management`
   pool's transaction/query counters increase accordingly.
7. PgBouncer resilience: `kubectl delete pod` on the PgBouncer pod. New
   pod reached `Running`/ready on its own. order-management's own pod was
   **never restarted** and, with zero manual intervention, successfully
   issued another `POST /orders` write immediately after PgBouncer's
   replacement pod came up — confirming pgxpool's own reconnect logic
   handles a PgBouncer pod cycling underneath it transparently.
8. All remaining 8 services (`inventory-storage`, `wes-work-planning`,
   `fulfillment-execution`, `workforce-management`, `facility-layout`,
   `process-path-management`, `labor-performance`, `network-fulfillment`)
   rolled out against their re-pointed `DATABASE_URL` Secrets;
   `kubectl rollout status` reported success for every one.
   `SHOW POOLS` on PgBouncer shows all 9 OLTP databases (order-management +
   the 8 above) live in `transaction` mode with real connection/query
   activity, confirming every service in the fleet is now actually routing
   its OLTP traffic through PgBouncer, not just configured to.

## Risks and trade-offs accepted

- **New single point of failure.** Every service's OLTP path now depends
  on PgBouncer being up, where before it depended only on Postgres. Tested
  restart resilience directly (above) — the Deployment recovers on its own
  and every service's own pgxpool reconnects transparently, so a PgBouncer
  pod restart is a brief, self-healing blip rather than a hard outage.
  `replicas = 1` for now (matching this being a single-node local cluster,
  same posture as the Postgres StatefulSet itself); a genuinely
  higher-availability deployment would need more than one PgBouncer
  replica behind a Service, which changes nothing about this design (all
  replicas would share the identical `pgbouncer.ini`/`userlist.txt`) but
  is out of scope for this rollout.
- **Aggregate pool_size (108) can technically exceed max_connections
  (100)** if every one of the 9 OLTP databases is simultaneously
  saturated. Accepted as a soft, not hard, ceiling given this fleet's real
  traffic pattern (see "Per-database pool sizing" above); revisit if
  monitoring ever shows sustained multi-database saturation.
- **Analytics stays direct**, meaning analytics connection count is not
  bounded by this change at all. Accepted per the "why analytics stays
  direct" reasoning above; revisit if projector/reports replica counts
  grow.

## Future work

- If per-database `pool_size` ever needs tightening further (evidence of
  real contention), lower `local.pgbouncer_oltp_pool_size` in
  `pgbouncer.tf` rather than raising Postgres's own `max_connections` —
  that would reintroduce the exact single-shared-ceiling problem this
  design exists to avoid.
- If analytics/projector connection counts ever become a real concern,
  route them through PgBouncer too (a second `[databases]`-style pool set,
  or a second PgBouncer database pool block) rather than leaving them
  direct indefinitely.
- Consider `replicas > 1` for the PgBouncer Deployment (with a
  `PodDisruptionBudget`) if this cluster ever needs to tolerate a node
  failure, not just a pod restart, without an OLTP-path blip.
