# warehouse-infra

A fully local Kubernetes environment for the `warehouse-systems` bounded
contexts: a **kind** cluster running **PostgreSQL**, **Kafka**, **Istio**
(sidecar mesh), the observability stack, **Kong** (north-south API gateway) and
an **Nginx web gateway** (the product UI), all provisioned by a single
`terraform apply`.

Nothing here talks to a cloud. There is no cloud load balancer, no registry
push, no remote state — images are built locally and side-loaded into kind, and
both gateways are reached through kind's `extraPortMappings`.

The product has **two independent host-facing edges**, and neither proxies to
the other:

```
http://localhost        ->  Nginx web gateway  ->  console shell + /mfes/<context>/ remotes + /catalog/ (EventCatalog)
http://localhost:8000   ->  Kong               ->  /api/<context> REST APIs
```

Kong never serves HTML/CSS/JavaScript; the web gateway never proxies an API.
Both bind to `127.0.0.1` only, because every REST and MCP endpoint here is
currently unauthenticated. The rationale, the rejected alternatives and the
consequences (CORS becomes load-bearing) are in
[docs/exposure/localhost-edge-topology.md](docs/exposure/localhost-edge-topology.md).
`scripts/test-exposure-policy.sh` asserts the separation against the live
cluster.

---

## Architecture

```
                    HOST (macOS / Linux)
   open http://localhost            (UI, via the Nginx web gateway)
   curl http://localhost:8000/api/inventory-storage/healthz
                          │
                          │  kind extraPortMappings
                          │  host :80  -> node :30080
                          │  host :443 -> node :30443
                          ▼
  ┌───────────────────────────────────────────────────────────────────────┐
  │  kind cluster "warehouse"   (1 control-plane + 1 worker, v1.36.1)      │
  │                                                                       │
  │   ns: kong                                                            │
  │   ┌─────────────────────────────────────────────┐                     │
  │   │  Kong Gateway (DB-less)  +  Kong Ingress     │                     │
  │   │  Controller, one pod, two containers         │                     │
  │   │  Service type NodePort  30080 / 30443        │                     │
  │   └───────────────────┬─────────────────────────┘                     │
  │                       │  routes by path prefix, strip-path=true        │
  │                       │  ( /inventory-storage/healthz -> /healthz )    │
  │                       ▼                                               │
  │   ns: warehouse-systems     [ istio-injection=enabled ]                │
  │   ┌───────────────────────────────────────────────────────────────┐   │
  │   │  inventory-storage      wes-work-planning                     │   │
  │   │  ┌──────┬──────────┐    ┌──────┬──────────┐                   │   │
  │   │  │ app  │istio-proxy│    │ app  │istio-proxy│   ... 4 pods,    │   │
  │   │  │ :8080│  sidecar  │    │ :8080│  sidecar  │   all 2/2        │   │
  │   │  └──────┴──────────┘    └──────┴──────────┘                   │   │
  │   │  workforce-management   fulfillment-execution                 │   │
  │   └───────────────────────────────┬───────────────────────────────┘   │
  │                                   │  DATABASE_URL                     │
  │                                   ▼                                   │
  │   ns: warehouse-data                                                  │
  │   ┌───────────────────────────────────────────────────────────────┐   │
  │   │  postgres-postgresql-0   (one release, four logical databases) │   │
  │   │    inventory_storage   wes_work_planning                      │   │
  │   │    workforce_management  fulfillment_execution                │   │
  │   │    ...each owned by its own least-privilege role              │   │
  │   └───────────────────────────────────────────────────────────────┘   │
  │                                                                       │
  │   ns: istio-system                                                    │
  │   ┌───────────────────────────────────────────────────────────────┐   │
  │   │  istiod  — injects the sidecars above via its mutating webhook │   │
  │   └───────────────────────────────────────────────────────────────┘   │
  └───────────────────────────────────────────────────────────────────────┘
```

Kong sits **outside** the mesh (the `kong` namespace is not labelled for
injection) and proxies into it. Istio's default mTLS mode is `PERMISSIVE`, so
the sidecars accept Kong's plaintext traffic without extra configuration.

---

## Ports & hosts reference

Every host port this cluster ever binds is an explicit `extra_port_mappings`
entry on the kind control-plane node in `terraform/main.tf` — nothing here is
discovered or auto-forwarded. kind port mappings are **immutable**: changing
any host port below means destroying and recreating the cluster, not a
rolling apply.

This section is the port-level map (which host port reaches which Service,
and which container port that Service targets). For the path-level API
route table (Kong's `/api/<context>` prefixes) see "Route table" below.

### Host-reachable ports (kind `extraPortMappings`, `main.tf`)

| Host URL / port                  | `listen_address` | Container (NodePort) | Backing Service                         | What it is |
|-----------------------------------|-------------------|-----------------------|------------------------------------------|------------|
| `http://localhost` (`:80`)        | `127.0.0.1`       | `30081`               | `web-gateway` (`warehouse-systems`)       | **Product UI** — Nginx web gateway: console shell + `/mfes/<context>/` remotes |
| `http://localhost/catalog/` (`:80`) | `127.0.0.1` | `30081` | `web-gateway` -> `ecosystem` (`warehouse-systems`) | **EventCatalog** — architecture catalog at `/catalog/` (base-prefixed SSG, bytes only) |
| `http://localhost:8000`           | `127.0.0.1`       | `30080`               | `kong-kong-proxy` (`kong`)                | **Product API** — Kong HTTP proxy, `/api/<context>/*` |
| `https://localhost:443`           | `0.0.0.0`         | `30443`               | `kong-kong-proxy` (`kong`)                | Kong HTTPS proxy (unused by the product today; no chart routes TLS) |
| `http://localhost:3000`           | `0.0.0.0`         | `30300`               | `grafana-nodeport` (`observability`)      | Grafana (`admin` / `var.grafana_admin_password`, default `admin`) |
| `http://localhost:16686`          | `0.0.0.0`         | `30686`               | `jaeger-nodeport` (`observability`)       | Jaeger query UI |
| `http://localhost:9090`           | `0.0.0.0`         | `30909`               | `prometheus-nodeport` (`observability`)   | Prometheus UI |
| `http://localhost:20001`          | `0.0.0.0`         | `30200`               | `kiali-nodeport` (`istio-system`)         | Kiali service-mesh UI |
| `localhost:9092` (Kafka protocol) | `0.0.0.0`         | `9092` *(below the default NodePort range — see `service_node_port_range`)* | `kafka-controller-0-external` (`warehouse-systems`) | Kafka's EXTERNAL listener, for host-side clients (e2e-tests, local `go run`) |

The two **product edges** (`:80` and `:8000`) bind to `127.0.0.1` only —
every REST/MCP endpoint in this fleet is currently unauthenticated (fleet
auth was rolled out then fully reverted 2026-09-11), so they must not be
reachable from the local network. Every other row above keeps its historical
`0.0.0.0` binding (platform/observability tooling, not product surface).

**ArgoCD has no host port mapping at all**, by deliberate design — it sits
outside both product edges and is reached only via
`kubectl port-forward svc/argocd-server -n argocd 8080:443`. See "ArgoCD"
below.

**Kong Manager** (`kong-kong-manager`, NodePort `8002`/`8445` inside the
`kong` namespace) is also not mapped to a host port — nothing in `main.tf`
publishes it. It exists only because the `kong/kong` chart always creates
it; reach it with `kubectl port-forward` if you ever need Kong's admin UI.

### In-cluster-only ports (ClusterIP — no host mapping, reached via `kubectl port-forward` or from inside the mesh)

Every bounded-context service's OLTP pod listens on container port `8080`
(`cmd/*/main.go` defaults `HTTP_ADDR` to `":8080"`; every Dockerfile
`EXPOSE`s 8080), fronted by a `ClusterIP` Service on port `80`:

| Service (`warehouse-systems` ns)         | Service port → target | What it is |
|--------------------------------------------|------------------------|------------|
| `<service>` (12 of: order-management, inventory-storage, wes-work-planning, fulfillment-execution, workforce-management, facility-layout, labor-performance, process-path-management, warehouse-planning, product-master, inbound-receiving, slotting-optimization) | `80 → 8080` | OLTP REST API, routed by Kong |
| `<service>-mcp`                            | `8090 → 8090`          | MCP server (Streamable HTTP at `/` and `/mcp`) — the 13 contexts in `mcp.tf`'s `local.mcp_services` (the 11 above plus network-fulfillment and network-inventory-planning) |
| `<service>-reports`                        | `80 → 8092`             | Analytics read-only REST API (only where `analytics.enabled`, see `locals.tf`'s `analytics_services`) |
| `<service>-frontend`                       | `80 → 8080`             | Module Federation remote, proxied by the web gateway at `/mfes/<context>/` |
| `warehouse-console`                        | `80 → 8080`             | Console shell SPA, proxied by the web gateway at `/` |
| `warehouse-ops-agent`                      | `80 → 8095`             | Console-bff / MCP-client aggregator, routed by Kong at `/api/warehouse-ops-agent` |
| `postgres-postgresql` (`warehouse-data` ns)| `5432 → 5432`           | Shared Postgres release, one logical database per service |
| `kafka` (`warehouse-systems` ns)           | `9092 → 9092`, `9095`   | Kafka's CLIENT listener (in-cluster only — see `kafka-controller-0-external` above for the host-reachable EXTERNAL listener) |
| `otel-collector` (`observability` ns)      | `4317` (gRPC), `4318` (HTTP) | OTLP ingest — every service's exporter points here |
| `prometheus-alertmanager` (`observability` ns) | `9093 → 9093`        | Alertmanager (one replica, null receiver: nothing is delivered). `kubectl -n observability port-forward svc/prometheus-alertmanager 9093:9093`, then `http://localhost:9093` or `/api/v2/alerts` |
| `istiod` (`istio-system` ns)               | `15010`/`15012`/`443`/`15014` | Istio control plane (sidecar injection webhook, xDS) |

The analytics **projector** (`cmd/<svc>-projector`, admin port `8091`) has NO
Service at all — it is a Kafka consumer with nothing to route HTTP traffic
to, on purpose.

`warehouse-planning` follows the same shape with its own binary names: the
projector is `/app/planning-projector` and the reports binary
`/app/planning-reports` (Service `warehouse-planning-reports`, Kong route
`/api/warehouse-planning/reports/*` → `/reports/*`), both in the SAME image as the
api, backed by the separate `warehouse_planning_analytics` database (role
`warehouse_planning_analytics`; password generated by
`random_password.service_analytics_db["warehouse-planning"]`, DSN direct to
Postgres, never through PgBouncer). Its projector consumer group is the fixed
`warehouse-planning-analytics`; its report endpoints are
`GET /reports/{bottleneck-frequency,shortage-trend,plan-throughput}`.

`product-master` likewise: projector `/app/product-projector` (admin `8091`,
consumer group `product-master-analytics`, topic
`warehouse.product-master.analytics`) and reports `/app/product-reports`
(Service `product-master-reports`, Kong route `/api/product-master/reports/*` →
`/reports/*`, endpoints `GET /reports/{master-data-quality,freshness}`), backed
by the separate `product_master_analytics` database (role
`product_master_analytics`, DSN direct to Postgres).

Known issue (product-master reports through Kong): the
`product-master-reports` HTTPRoute (`/api/product-master/reports` →
`/reports`) is declared, but requests to it are answered by the
`/api/product-master` route instead, so
`http://localhost:8000/api/product-master/reports/*` returns `404` from the
OLTP API (which has no `/reports/*` path). The reports service itself works
in-cluster: `kubectl -n warehouse-systems port-forward svc/product-master-reports 8092:80`.

The rest of product-master's deployment: the OLTP API (`EVENT_PUBLISHER=kafka`,
legacy importer group `product-master-legacy-import`), the read-only MCP server
`product-master-mcp` (read by `warehouse-ops-agent` through
`PRODUCT_MASTER_MCP_ENDPOINT`, `ops-agent.tf`) and the console remote
`product-master-frontend` (`productmaster_mfe`, `/mfes/product-master/`,
`frontends.tf`). Its `ProductClassified` events on
`warehouse.product-master.events` feed local copies in inventory-storage
(`productMasterConsumerGroup`, `helm-values/inventory-storage.yaml`) and in
order-management, wes-work-planning and fulfillment-execution
(`PRODUCT_CLASSIFICATION_MODE=kafka`, `helm-values/order-management.yaml` and
`locals.tf`); no service reads classification from inventory-storage over REST
any more.

`inbound-receiving` (ASN, dock appointment, receipt) follows the same shape:
projector `/app/inbound-projector` (admin `8091`, consumer group
`inbound-receiving-analytics`, topic `warehouse.inbound-receiving.analytics`)
and reports `/app/inbound-reports` (Service `inbound-receiving-reports`, Kong
route `/api/inbound-receiving/reports/*` → `/reports/*`, endpoints
`GET /reports/{receiving-performance,freshness}`), backed by the separate
`inbound_receiving_analytics` database (role `inbound_receiving_analytics`, DSN
direct to Postgres). The same Kong reports-route caveat as product-master
above applies until that route issue is fixed. The OLTP API runs with
`EVENT_PUBLISHER=kafka`, `PRODUCT_MODE=kafka` (group `inbound-receiving-product`,
SKU copy from `warehouse.product-master.events`) and `DOCK_DOOR_MODE=kafka`
(group `inbound-receiving-dock-doors`, inbound-door copy from
`warehouse.facility.events`; `helm-values/inbound-receiving.yaml`). The
read-only MCP server `inbound-receiving-mcp` is read by `warehouse-ops-agent`
through `upstreams.inboundReceiving` (`ops-agent.tf`), and the console remote
`inbound-receiving-frontend` is `inbound_mfe` at `/mfes/inbound-receiving/`
(`frontends.tf`). The handover: inventory-storage consumes
`ReceiptLineReceived` from `warehouse.inbound-receiving.events`
(`config.inboundReceiptConsumerGroup=inventory-storage-inbound-receipts`,
`helm-values/inventory-storage.yaml`, inventory-storage ADR 0037) and books
`StockReceived`, which leaves the service because inventory-storage runs
`EVENT_PUBLISHER=kafka`.

`slotting-optimization` (forward pick-slot plans by ABC velocity, human
approval; gap fix D10) is a plain `local.services` member: OLTP API only, no
analytics read side, no web remote, and its read-only MCP server stays off
(no consumer is wired). Its role/database `slotting_optimization` and the
`slotting-optimization-db` Secret derive from `local.services`; the Kong route
`/api/slotting-optimization` is the chart's own `gatewayApi` HTTPRoute. The API
runs with `EVENT_PUBLISHER=kafka` (topic `warehouse.slotting-optimization.events`)
and four consumers, each with a stable group
(`helm-values/slotting-optimization.yaml`): `DEMAND_MODE=kafka`
(`slotting-optimization-demand`, from `warehouse.order-management.events`),
`PRODUCT_MODE=kafka` (`slotting-optimization-product`, from
`warehouse.product-master.events`), `LAYOUT_MODE=kafka`
(`slotting-optimization-layout`, from `warehouse.facility.events`) and
`RELOCATION_MODE=kafka` (`slotting-optimization-relocation`, inventory-storage's
`StockRelocated` from `warehouse.inventory.events`: per-plan execution progress,
slotting ADR 0010). Approved plans are executed as WES relocation work: the chain
is `SlotPlanApproved` → wes-work-planning (its inbound consumer, on whenever its
`kafka.enabled`, plans one `RELOCATE` work unit per move) → fulfillment-execution
`RELOCATE` task → `TaskCompleted` → inventory-storage's TaskCompleted consumer
(`config.taskCompletedConsumerMode=kafka`) relocates the stock and raises
`StockRelocated` → slotting-optimization. It needs the `RELOCATE` process path
(post-deploy seed step 1). Two things a first `terraform apply` will
not do on its own: (1) initdb never re-runs on a populated Postgres, so create
the role/database once by hand, mirroring `templates/init-databases.sql.tftpl`
with the password from `module.application["slotting-optimization"]`'s
generated `db_password` (`terraform console`, never printed in a log);
(2) its chart does not render the Kong plugins yet (no `kong-plugins.yaml`), so
`scripts/test-exposure-policy.sh` section 11 flags its HTTPRoute and Kong
exports no `kong_http_requests_total` series for it until that chart change
lands in slotting-optimization.

**A structural gotcha worth knowing before you `kubectl port-forward pod/…`:**
every chart's `selectorLabels` helper emits only
`app.kubernetes.io/name`+`app.kubernetes.io/instance`, identical across the
OLTP, MCP, projector, and reports pods of the same service — so the OLTP
`Service` actually selects ALL of them, and which pod answers a given
request is undefined. Port-forward `pod/<exact-name>`, never `deploy/` or
`svc/`, when you need a specific one. product-master's chart is the exception:
each of its Services also selects `app.kubernetes.io/component`, so exactly
one Deployment answers (its `charts/product-master/tests/test_service_selectors.py`).

### ArgoCD

Installed by `terraform/argocd.tf` (`helm-values/argocd.yaml`) in its own
`argocd` namespace. **Deliberately not on any host port** — neither product
edge (`:80` Nginx, `:8000` Kong) is meant to carry deployment-control-plane
traffic, and nothing in `main.tf`'s `extraPortMappings` publishes it.

```bash
kubectl -n argocd port-forward svc/argocd-server 8080:443
```

Then open `https://localhost:8080` (self-signed cert; click through the
browser warning). Auth is **disabled**
(`configs.params."server.disable.auth"` in `helm-values/argocd.yaml`) to
match this fleet's fully-unauthenticated posture, so no login is needed.

`argocd-server`'s in-cluster Service (`argocd` namespace) listens on `80`
(HTTP, redirects) and `443` (HTTPS, the one used above); `argocd-repo-server`
on `8081`; `argocd-applicationset-controller` on `7000`; `argocd-dex-server`
on `5556`/`5557` (SSO, unused here since auth is off); `argocd-redis` on
`6379`. None of these need a host port — only `argocd-server` is ever
reached directly, and only via port-forward.

**Probe budgets and render parallelism** (`helm-values/argocd.yaml`). The
chart's 1 s timeout on `/healthz?full=true` fails chronically on the single kind
worker: on 2026-10-14 `argocd-server` had 98 liveness failures in 16 h and
`argocd-repo-server` was killed 23 times in 5 h (exit 137). When a Terraform
apply made all 16 Applications re-render at once (`helm template` ~14 s, git
fetch ~32 s, `GenerateManifest` up to ~78 s) the repo-server entered a
liveness-kill loop and every Application went `Unknown`, although the process
was healthy and only slow to answer. Two settings address it
([#83](https://github.com/IQVO/warehouse-infra/pull/83)):

| Setting | Value | Effect |
| --- | --- | --- |
| `server` and `repoServer` `livenessProbe` | `timeoutSeconds: 10`, `periodSeconds: 15`, `failureThreshold: 6` | A slow answer is no longer a kill. |
| `server` and `repoServer` `readinessProbe` | `timeoutSeconds: 5`, `failureThreshold: 6` | Same budget for readiness. |
| `configs.params."reposerver.parallelism.limit"` | `4` | Bounds concurrent `helm template` renders (chart default `0` = unlimited); excess requests queue instead of all slowing down together. |

These are Helm values for the ArgoCD release, so they take effect only after a
Terraform apply of `argocd.tf`; merging the PR changes nothing in a running
cluster.

### kind CPU-request overlay

The kind cluster is **one worker** with the Docker VM's 10 CPUs. The charts
request 50-100m CPU per container (about 10 cores for ~76 app containers) while
measured use is ~10 % of that, and every Deployment is 1 replica with the
default RollingUpdate (`maxSurge` 1). A fleet-wide rollout therefore left new
pods `Pending` (`Insufficient cpu`) and stalled (2026-10-14). The overlay lowers
`requests.cpu` to `25m` for every component whose chart default is higher (API,
MCP, analytics projector and reports, frontend, console); limits and memory keep
the chart defaults, so a busy pod can still burst.

* `helm-values/kind-resources/<app>.yaml` — one generated overlay per
  Application (16 files plus a `README.md`). Regenerate it when a chart adds a
  component with a CPU request above `25m`.
* `terraform/kind-overlay.tf` — merges each overlay **into the Application's
  `helm.valuesObject`** (explicitly at `resources`, `mcp`, `frontend` and
  `analytics.projector` / `analytics.reports`, because Terraform's `merge()` is
  shallow). `terraform/applications.tf` passes the merged
  `local.argocd_*_values` to each application's module instance.
* Not a separate `helm.values` string: ArgoCD v2.13 renders **only**
  `valuesObject` when both are set, so a `values` string is silently ignored
  ([#81](https://github.com/IQVO/warehouse-infra/pull/81) shipped that form;
  [#82](https://github.com/IQVO/warehouse-infra/pull/82) fixed it).

After an apply, check that the containers request `25m` and that the node's
requested CPU dropped:

```bash
kubectl get pods -A -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.containers[*].resources.requests.cpu}{"\n"}{end}'
kubectl describe nodes | grep -A8 'Allocated resources'
```

The overlay is a kind-environment setting only; a production-like environment
uses the chart defaults.

---

## Process-path catalogue

process-path-management owns the process-path catalogue. The paths every
environment must define are declared in its repository
(`catalogue/paths.json`: `PICK`, `PACK`, `REBIN`, `SLAM`, `RELOCATE`, `DISPATCH`,
`REPLENISH`, each with its `intake`) and applied by its `scripts/seed_catalogue.py` — step 1 of the
[post-deploy seeds](#post-deploy-seeds). fulfillment-execution,
wes-work-planning, workforce-management and order-management read the catalogue
from `warehouse.process-path-management.events`
(`var.deploy_process_path_kafka_source = true`), not from a file.

`config/process-paths/sortable-fc.yaml` is the **frozen rollback target** of the
retired file-based catalogue: four paths, no `RELOCATE`, no `intake` (the file
schema the services' `filecatalog` loaders read is id / matchPrefix / direct /
requiredCapabilities only, so an `intake` there would be ignored). Do not edit it
to change paths; see its header and
`scripts/README-process-path-seed.md` (whose `seed-process-paths.py` was the
one-time YAML → process-path-management migration and is superseded by
`seed_catalogue.py`).

---

## Network inventory planning (NIP) runbook

`network-inventory-planning` is deployed by `terraform/network-inventory-planning.tf`
(image build/load, database secrets, ArgoCD Application, Kong routes for the API and
`/reports`, chart values incl. MCP, console remote and analytics). Two things a plain
`terraform apply` does NOT do on an already-populated cluster:

1. **Databases and roles (two of them).** Postgres runs its init script once, on an
   empty data directory. On a live cluster create, against the primary as the
   superuser, the OLTP and the analytics database, each with its own owner role and
   the passwords from `terraform output -raw network_inventory_planning_db_password`
   and `terraform output -raw network_inventory_planning_analytics_db_password`
   (the same statements `templates/init-databases.sql.tftpl` renders):

   ```sql
   CREATE ROLE network_inventory_planning WITH LOGIN PASSWORD '<db_password>';
   CREATE DATABASE network_inventory_planning WITH OWNER network_inventory_planning ENCODING 'UTF8';
   REVOKE ALL ON DATABASE network_inventory_planning FROM PUBLIC;
   GRANT CONNECT, TEMPORARY ON DATABASE network_inventory_planning TO network_inventory_planning;

   CREATE ROLE network_inventory_planning_analytics WITH LOGIN PASSWORD '<analytics_db_password>';
   CREATE DATABASE network_inventory_planning_analytics WITH OWNER network_inventory_planning_analytics ENCODING 'UTF8';
   REVOKE ALL ON DATABASE network_inventory_planning_analytics FROM PUBLIC;
   GRANT CONNECT, TEMPORARY ON DATABASE network_inventory_planning_analytics TO network_inventory_planning_analytics;
   ```

   Do this before ArgoCD syncs the pods. No PgBouncer step is needed: `pgbouncer.tf`
   already renders the OLTP role into its userlist on apply, and the analytics database
   is reached directly (never through PgBouncer).
2. **The dispatch path.** NIP releases the dispatch leg with
   `TRANSFER_DISPATCH_PATH_ID=dispatch-transfer`. process-path-management is the
   catalogue's source of truth (the YAML under `config/process-paths/` is frozen) and
   declares the `DISPATCH` family in `catalogue/paths.json` (its ADR 0035: matchPrefix
   `dispatch`, direct, capability `dispatch`, intake `STOCK_TRANSFER`). The path id is
   the fulfillment-execution task type, so the configured value must be `dispatch` or
   `dispatch-*`. Run `seed_catalogue.py` (step 1 of "Post-deploy seeds") once the
   declaration is on process-path-management's `develop`; until the path exists the
   dispatch leg is fail-closed (the saga stops after the pick). Floor stations need the
   `dispatch` capability to claim the task.

---

## Post-deploy seeds

Three idempotent seeds converge data the services own but no deploy step creates.
Run them after every deploy that changes their inputs (and once on a fresh
cluster), **in this order**, all through Kong; each has a `--dry-run` and each is a
no-op when nothing changed:

| # | Seed                                                                 | Owner / source of truth                                        | Why this position |
|---|----------------------------------------------------------------------|----------------------------------------------------------------|-------------------|
| 1 | process-path catalogue: `../process-path-management/scripts/seed_catalogue.py` | process-path-management `catalogue/paths.json` (its ADR 0033/0034) | adds `RELOCATE` (intake `SLOT_RELOCATION`, its ADR 0033), `DISPATCH` (`STOCK_TRANSFER`, ADR 0035) and `REPLENISH` (`REPLENISHMENT`, ADR 0036) and sets every path's `intake` (`PICK` = `CUSTOMER_ORDER`; `PACK`/`REBIN`/`SLAM` = `[]`). Every consumer (wes-work-planning, fulfillment-execution, workforce-management, order-management) gets it live from `warehouse.process-path-management.events`. It must run before anything routes work: before slotting-optimization approves a plan (wes-work-planning plans each move on `RELOCATE`) and before stock-transfer work is released |
| 2 | site transfer capability: `scripts/seed-transfer-capability.py`      | facility-layout `GET /site-roles/transfer-defaults` (its ADR-0035/0037) | turns on inter-site transfers between the sites whose role allows them; network-inventory-planning starts proposing transfers (and releasing their legs onto process paths) as soon as capabilities land, so the catalogue must already be converged |
| 3 | transfer lanes: `scripts/seed-transfer-lanes.py`                      | NIP's own lane catalogue (its ADR-0015), computed from the capabilities of step 2 and the sites' geography | NIP proposes a transfer only along an enabled lane whose origin may send and whose destination may receive, so the lanes follow the capabilities |

```bash
# 1. process-path catalogue (sibling checkout, the same layout the Makefile's CHARTS assume)
python3 ../process-path-management/scripts/seed_catalogue.py \
  --base-url http://localhost:8000/api/process-path-management --dry-run
python3 ../process-path-management/scripts/seed_catalogue.py \
  --base-url http://localhost:8000/api/process-path-management

# 2. site transfer capability
python3 scripts/seed-transfer-capability.py --dry-run
python3 scripts/seed-transfer-capability.py

# 3. transfer lanes (needs step 2: lanes follow the capabilities)
python3 scripts/seed-transfer-lanes.py --dry-run
python3 scripts/seed-transfer-lanes.py
```

`seed_catalogue.py` exits 1 if any declared path is not converged (a DEACTIVATED id
or a changed immutable field such as `direct`: declare a new `pathId` in
`paths.json` instead); fix that before step 2. The first run after
process-path-management's `0009_intake` migration writes at most a `POST` for
each declared path that is absent (`RELOCATE`, `DISPATCH`, `REPLENISH`) and one `PUT` per path whose stored `intake` differs
from the declaration (`PICK`, and `RELOCATE` if it was created before intake
existed); every later run writes nothing. Check the result through Kong:

```bash
curl -s http://localhost:8000/api/process-path-management/process-paths/RELOCATE
curl -s http://localhost:8000/api/process-path-management/process-paths/PICK   # intake ["CUSTOMER_ORDER"]
```

`DISPATCH` (NIP's dispatch leg, see the NIP runbook above) is declared in
`paths.json` too, so the same seed creates it; the catalogue seed never touches
paths it does not declare.

### Site transfer capability (`scripts/seed-transfer-capability.py`)

Inter-site transfers (network-inventory-planning) only run between sites whose
transfer capability allows them, and facility-layout keeps that capability an
explicit, revisioned per-site command (its ADR-0035): nothing sets it
automatically and a site-role change never flips it (ADR-0037). The fleet decision
is that capability follows the site's role in the network; facility-layout
publishes that table as `GET /site-roles/transfer-defaults` and this seed applies it
once:

| Role (facility-layout `siteRole`)                                                                   | origin | destination |
|-----------------------------------------------------------------------------------------------------|--------|-------------|
| Robotics/Non-/Traditional/Soft-Lines Sortable FC, Sub-Same-Day FC, XL FC, Simulated FC              | yes    | yes         |
| Micro-FC                                                                                            | no     | yes         |
| Inbound Cross-Dock, National Inbound Cross-Dock, Returns Center                                     | yes    | no          |
| Fresh Grocery FC, Sortation Center, Delivery Station, Air Hub Gateway                               | no     | no          |

(The table above is for reading only: the script never hard-codes it, it reads the
endpoint, so facility-layout stays the single source of truth.)

```bash
# through Kong (default base URL http://localhost:8000/api/facility-layout,
# overridable with --base-url or $FACILITY_LAYOUT_BASE_URL)
python3 scripts/seed-transfer-capability.py --dry-run   # prints the plan, writes nothing
python3 scripts/seed-transfer-capability.py
```

For every **Active** site it reads `GET /sites/{siteCode}/transfer-capability` and
compares it with its role's default:

| Site state                                            | Action                                                              |
|-------------------------------------------------------|---------------------------------------------------------------------|
| already at the role's default                         | nothing (no PUT, so no revision and no `SiteCapabilityChanged`)     |
| differs from the role's default                       | `PUT /sites/{siteCode}/transfer-capability` (full snapshot) → revision + 1, `SiteCapabilityChanged` |
| `siteRole` `UNSPECIFIED`, or a role with no default row | **never touched**; listed under "sites needing an operator decision" |
| not Active (Decommissioned)                           | never touched (its capability is frozen)                            |

A never-set site reads as capable of nothing at revision 0; if its role's default is
also "neither" it is already at the target and is not written. The PUT carries no
version: a concurrent writer makes it lose with 409 `concurrent-modification`, after
which the script re-reads and re-PUTs (`--retries`, default 3) — or stops if the other
writer already set the target. A second run against an unchanged facility-layout
makes zero writes.

Exit codes: `0` every Active, classified site is at its default (or would be, with
`--dry-run`); `1` at least one site's read or PUT failed (the others are still
reconciled — re-run after fixing); `2` the defaults table or the site list could not
be read (nothing written). An `UNSPECIFIED` site is not a failure: classify it with
`PUT /sites/{siteCode}/role` and re-run. Unit tests: `make seed-scripts-test` (CI job
`seed-scripts`), against a stdlib fake of the facility-layout contract.

Verify a site afterwards:

```bash
curl -s http://localhost:8000/api/facility-layout/sites/ABE8/transfer-capability
```

### Transfer lanes (`scripts/seed-transfer-lanes.py`)

network-inventory-planning (NIP) proposes a transfer only along an **enabled lane** whose
origin may send and whose destination may receive (its ADR-0015). The lane catalogue is
NIP's own operator-managed data and no sibling publishes it, so a fresh cluster has none
and the scheduled rebalance pass can never propose anything. This seed computes the lanes
from the live capabilities (step 2) and from geography:

- for every origin, one directed lane to each of its **K nearest destinations** (default 4)
  in the **same country** within **2,500 km** (`--neighbours`, `--max-km`); no cross-border
  lanes;
- distance is great-circle between city centres (`scripts/data/site-coordinates.json`,
  geocoded from the `(City, ST)` in each site name with OpenStreetMap Nominatim, ODbL; a new
  site is added with `--refresh-coordinates`);
- `LeadTime` = (1 + ceil(km / 800)) days, `UnitHandlingCost` = 1 + ceil(km / 400). NIP scores a
  proposal as `quantity x UnitPriority - quantity x UnitHandlingCost - lead-time days`, so the
  cost is a relative weight, not a currency amount.

Idempotent: an identical lane is not written; a drifted one is updated (revision + 1); a lane
NIP has that the rule does not compute is **left alone** and listed (NIP has no DELETE;
disable one with `Enabled: false`). A capable site without coordinates (the simulator `SIM1`
has no city) gets no lane and is listed. Exit codes: `0` converged, `1` a PUT failed, `2`
sites/capabilities/lane catalogue/coordinates unreadable (nothing written). Unit tests:
`make seed-scripts-test`.

Rebalance **policies** (`PUT /v1/rebalance-policies`, per site + SKU: safety stock, target
stock, priority) are not seeded here: their numbers only mean something against real stock
and demand per site, so they follow the inventory seed.

---

## Prerequisites

Versions this was actually built and verified against, on `darwin/arm64`:

| Tool      | Version                       |
|-----------|-------------------------------|
| Docker    | 29.7.2 (server)               |
| kind      | v0.32.0                       |
| Helm      | v4.2.4                        |
| Terraform | v1.5.7                        |
| kubectl   | v1.36.3                       |

Chart / image versions, all resolved against live registries rather than
guessed (see `terraform/variables.tf` for the reasoning behind each pin):

| Component   | Chart                                                   | Version  | Image                                          |
|-------------|---------------------------------------------------------|----------|------------------------------------------------|
| Kubernetes  | —                                                       | —        | `kindest/node:v1.36.1` (digest-pinned)         |
| PostgreSQL  | `oci://registry-1.docker.io/bitnamicharts/postgresql`   | `16.7.4` | `docker.io/bitnamilegacy/postgresql:17.5.0-debian-12-r3` |
| Istio       | `istio/base` + `istio/istiod`                           | `1.30.3` | upstream                                       |
| Kong        | `kong/kong`                                             | `3.4.1`  | Kong Gateway 3.9 + KIC 3.5                     |

### About that PostgreSQL pin

Bitnami moved its versioned public images behind "Bitnami Secure Images" in
2025. Two consequences, both handled in `terraform/postgres.tf`:

* The **current** chart (18.x) defaults to `bitnami/postgresql:latest` — an
  unpinned rolling tag, which is not reproducible.
* The tag chart 16.7.4 ships by default, `bitnami/postgresql:17.5.0-debian-12-r3`,
  **no longer exists** in the free catalogue. Verified:

  ```
  $ docker manifest inspect bitnami/postgresql:17.5.0-debian-12-r3        -> not found
  $ docker manifest inspect bitnamilegacy/postgresql:17.5.0-debian-12-r3  -> amd64 + arm64
  ```

Chart `16.7.4` (appVersion 17.5.0) is the last coherent pair where the chart's
own default tag still exists verbatim under the frozen `bitnamilegacy` org, so
the stack stays both **pinned** and **pullable**. The chart's image-provenance
check is opted out of with `global.security.allowInsecureImages: true`, which
is exactly what that flag is for.

---

## Bring it up

One command, from zero:

```bash
cd warehouse-infra
./scripts/up.sh
```

That runs `terraform init` + `terraform apply`, which in order:

1. creates the kind cluster (control-plane + worker) with the Kong port
   mappings,
2. installs **PostgreSQL** and creates the four databases via
   `primary.initdb.scripts`,
3. installs **istio-base**, then **istiod** (base first — it owns the CRDs
   istiod's manifests reference),
4. installs **Kong**,
5. `docker build`s all four services from their existing Dockerfiles and
   `kind load docker-image`s them into the cluster,
6. installs the four service charts with their database URLs and Kong routes.

Equivalent by hand:

```bash
cd warehouse-infra/terraform
terraform init
terraform apply -auto-approve
```

Then verify end to end:

```bash
./scripts/smoke-test.sh
```

To stand up only the platform, without building or deploying the four
services:

```bash
terraform apply -auto-approve -var deploy_services=false
```

### If port 80 is taken

`kong_proxy_http_host_port` defaults to `80` and `kong_proxy_https_host_port`
to `443`. If something on your machine already owns them, kind cluster creation
fails with a bind error. Override:

```bash
terraform apply -auto-approve \
  -var kong_proxy_http_host_port=8000 \
  -var kong_proxy_https_host_port=8443
```

---

## Route table

### APIs — Kong, on `http://localhost:8000`

Kong routes purely on path prefix (no Host header required), and strips the
whole `/api/<context>` prefix before proxying, so each pod sees the paths its
own chi router actually registers.

The prefix is not decoration: the old routes were a bare `/<service>`, which
collides head-on with the console shell's own client-side routes —
`/order-management` is a page in the SPA as well as an API namespace.

| Host URL                                                  | Kong route (strip-path)              | In-cluster service                                          |
|-----------------------------------------------------------|--------------------------------------|-------------------------------------------------------------|
| `http://localhost:8000/api/order-management/*`            | `/api/order-management` → `/*`       | `order-management.warehouse-systems.svc.cluster.local`      |
| `http://localhost:8000/api/inventory-storage/*`           | `/api/inventory-storage` → `/*`      | `inventory-storage.warehouse-systems.svc.cluster.local`     |
| `http://localhost:8000/api/wes-work-planning/*`           | `/api/wes-work-planning` → `/*`      | `wes-work-planning.warehouse-systems.svc.cluster.local`     |
| `http://localhost:8000/api/fulfillment-execution/*`       | `/api/fulfillment-execution` → `/*`  | `fulfillment-execution.warehouse-systems.svc.cluster.local` |
| `http://localhost:8000/api/workforce-management/*`        | `/api/workforce-management` → `/*`   | `workforce-management.warehouse-systems.svc.cluster.local`  |
| `http://localhost:8000/api/facility-layout/*`             | `/api/facility-layout` → `/*`        | `facility-layout.warehouse-systems.svc.cluster.local`       |
| `http://localhost:8000/api/labor-performance/*`           | `/api/labor-performance` → `/*`      | `labor-performance.warehouse-systems.svc.cluster.local`     |
| `http://localhost:8000/api/process-path-management/*`     | `/api/process-path-management` → `/*`| `process-path-management...svc.cluster.local`                |
| `http://localhost:8000/api/warehouse-planning/*`          | `/api/warehouse-planning` → `/*`     | `warehouse-planning.warehouse-systems.svc.cluster.local`    |
| `http://localhost:8000/api/product-master/*`              | `/api/product-master` → `/*`         | `product-master.warehouse-systems.svc.cluster.local` (`/api/product-master/reports/*` is meant for `product-master-reports` but currently lands here and 404s, see the known issue above) |
| `http://localhost:8000/api/inbound-receiving/*`           | `/api/inbound-receiving` → `/*`      | `inbound-receiving.warehouse-systems.svc.cluster.local` (`/api/inbound-receiving/reports/*` is meant for `inbound-receiving-reports`; same caveat as product-master) |
| `http://localhost:8000/api/slotting-optimization/*`       | `/api/slotting-optimization` → `/*`  | `slotting-optimization.warehouse-systems.svc.cluster.local` |
| `http://localhost:8000/api/network-inventory-planning/*`  | `/api/network-inventory-planning` → `/*` | `network-inventory-planning.warehouse-systems.svc.cluster.local` |
| `http://localhost:8000/api/warehouse-ops-agent/*`         | `/api/warehouse-ops-agent` → `/*`    | `warehouse-ops-agent.warehouse-systems.svc.cluster.local`   |

Container port 8080 is not an assumption: every `cmd/*/main.go` defaults
`HTTP_ADDR` to `":8080"` and every Dockerfile `EXPOSE`s 8080.

```bash
curl -i http://localhost:8000/api/inventory-storage/healthz
```

### UI — the Nginx web gateway, on `http://localhost`

| Host URL                              | In-cluster service                                            |
|---------------------------------------|---------------------------------------------------------------|
| `http://localhost/`                   | `warehouse-console.warehouse-systems.svc.cluster.local`       |
| `http://localhost/mfes/<context>/*`   | `<context>-frontend.warehouse-systems.svc.cluster.local`      |

The gateway strips `/mfes/<context>` before proxying, so each remote's own nginx
sees root-relative paths. Each remote is built with Vite base
`/mfes/<context>/`, which keeps its chunks inside its own namespace.

`terraform output routes`, `frontend_routes` and `product_endpoints` print the
live tables for the ports you actually applied.

---

## Databases

One PostgreSQL release, four logical databases, four least-privilege owners.
Created by a Terraform-templated init script
(`terraform/templates/init-databases.sql.tftpl`) fed to the chart's
`primary.initdb.scripts` — reproducible from a clean `terraform apply`, never a
manual step.

| Bounded context         | Database                | Owning role             |
|-------------------------|-------------------------|-------------------------|
| inventory-storage       | `inventory_storage`     | `inventory_storage`     |
| wes-work-planning       | `wes_work_planning`     | `wes_work_planning`     |
| workforce-management    | `workforce_management`  | `workforce_management`  |
| fulfillment-execution   | `fulfillment_execution` | `fulfillment_execution` |

Each role owns exactly one database; `REVOKE ALL ... FROM PUBLIC` strips the
implicit grant so no role can connect to another context's database. Since
PostgreSQL 15 the `public` schema is owned by `pg_database_owner`, so the
database owner already has full DDL rights on it.

Services reach it at
`postgres-postgresql.warehouse-data.svc.cluster.local:5432`.

Inspect it:

```bash
kubectl -n warehouse-data exec -it postgres-postgresql-0 -- \
  env PGPASSWORD=postgres psql -U postgres -c '\l'
```

**Storage now persists across pod restarts by default.**
`postgres_persistence_enabled` defaults to `true` (as of 2026-09-26 — data
durability was decided to matter more here than the old
reproducible-from-any-state disposability). One real consequence: initdb
scripts only run against an EMPTY data directory, so once a PVC exists, a
NEW logical database added to `local.services`/`local.analytics_services`
will NOT be created automatically on a pod restart — you have to run the
manual `CREATE ROLE`/`CREATE DATABASE` steps documented for that case (see
this repo's operational notes / the fleet skill's "initdb never re-runs"
pitfall). Set `-var postgres_persistence_enabled=false` to go back to the
old ephemeral emptyDir behavior, e.g. for a disposable CI/throwaway
cluster.

Credentials are deterministic dev values (`postgres` / `<db name>`), not
`random_password`, so the commands in this README are copy-pasteable and a
re-apply cannot rotate a credential out from under a running pod. **Local dev
only.**

---

## Secrets you must supply yourself: ANTHROPIC_API_KEY

warehouse-ops-agent's ADR-0004 model-backed Reasoner is wired real in this
cluster (`LLM_MODE=shadow` — it calls the real Anthropic API alongside the
deterministic policy, logs agreement, but never acts on the model's output
alone). Terraform creates the Kubernetes Secret
(`warehouse-ops-agent-anthropic`, from the ops agent's `secrets` entry in
`terraform/applications.tf`) but
**never generates or hardcodes the API key itself** — `var.anthropic_api_key`
defaults to `""`.

Supply the real value one of two ways, **never** by editing a tracked file:

```bash
export TF_VAR_anthropic_api_key="sk-ant-..."
terraform apply
```

or copy `terraform/terraform.tfvars.example` to a gitignored
`terraform/terraform.tfvars` (already covered by `.gitignore`'s
`terraform/*.tfvars`) and fill in the real value there.

Leaving the key empty is fine for `terraform validate`/`plan` (the default
`""` is deliberately valid input, checked by CI). It is **not** fine for a
real `apply` with `LLM_MODE=shadow`: warehouse-ops-agent's own composition
root (`cmd/agent/reasoner.go`, ADR-0004) fails loudly at pod startup —
`LLM_MODE=shadow requires ANTHROPIC_API_KEY` — rather than silently running
without the model it was told to use. A `check` block in
`terraform/ops-agent.tf` surfaces the same condition as a `terraform
plan`/`apply` warning so you don't have to wait for the crash loop to learn
it.

---

## Where the manifests live

**Decision: each service repo owns its own Helm chart; `warehouse-infra` owns
only the environment.** There is exactly one copy of every manifest.

> [ADR 0002](docs/adr/0002-application-delivery-boundary.md) extends this
> decision: application configuration moves out of the Terraform computed
> layer described below into value files that ArgoCD reads from this repo,
> and every application is registered through one `application` module
> ([ADR 0004](docs/adr/0004-one-application-registry.md), done: see
> `terraform/applications.tf`). Until its other phases land, the split below
> is what the code does.

All four services already ship a complete, well-formed Helm chart at
`<service>/charts/<service>/` — Deployment, Service, ServiceAccount, ConfigMap,
Secret, Ingress, HPA, with liveness/readiness probes already pointed at
`GET /healthz` and a `database.existingSecret` path already modelled. Copying
those into `warehouse-infra/k8s/<service>/` would have created a second home
for the same YAML and guaranteed drift.

So the split is:

* `<service>/charts/<service>/` — **shape of the workload.** Owned by the team
  that owns the service. Unchanged by this task.
* `warehouse-infra/helm-values/<service>.yaml` — **static environment config**
  for this cluster: probe timings, event-publisher mode, Kafka settings.
* `warehouse-infra/terraform/services.tf` — **computed environment config**:
  image repository/tag, `database.existingSecret` (a pre-created Secret, not
  a plaintext URL — see "Deploying a new bounded context" below), and the
  Kong `ingress` block. Appended after the values file, so Terraform always
  wins. Applied via an ArgoCD `Application` per service, not a direct
  `helm_release` — see that section for why.

`terraform/locals.tf` points each service at its chart via a relative
`chart_path` (`${path.module}/../../<service>/charts/<service>`), consumed by
the ArgoCD `Application` source's `path` field (`modules/application`).

### No application changes were required

**Zero Go source files, ports, or env-var names were changed, and none needed
to be.** Concretely:

* **Istio** needs no application change whatsoever. The
  `istio-injection=enabled` label on the `warehouse-systems` namespace is
  sufficient: istiod's mutating admission webhook rewrites the pod spec at
  admission time to add the `istio-proxy` sidecar and an init container that
  installs the iptables redirect. The app keeps listening on `:8080` and keeps
  serving `GET /healthz` exactly as it does under `docker-compose`. A pod going
  `2/2` is the sidecar, not a second app container.

  One thing that surprises people: on Istio 1.30 the sidecar is injected as a
  **native sidecar**, i.e. an entry in `.spec.initContainers` with
  `restartPolicy: Always` (the Kubernetes 1.29+ feature), *not* in
  `.spec.containers`. So this looks alarming but is correct:

  ```
  $ kubectl -n warehouse-systems get pod inventory-storage-... \
      -o jsonpath='{.spec.containers[*].name}'
  inventory-storage                       # <- only one!

  $ kubectl -n warehouse-systems get pod inventory-storage-... \
      -o jsonpath='{range .spec.initContainers[*]}{.name} {.restartPolicy}{"\n"}{end}'
  istio-init
  istio-proxy Always                      # <- the sidecar, counted in READY 2/2
  ```
* **Kong** needs no application change either. Routing is a stock Kubernetes
  `Ingress` with `ingressClassName: kong`, which the existing charts already
  template from `values.ingress`. The `konghq.com/strip-path: "true"`
  annotation removes the path prefix at the gateway, so the services keep
  serving the un-prefixed paths their routers already register.

Because the existing charts covered everything, **nothing was added to any
service repo** — there is no new `deploy/` folder anywhere and no service repo
was staged for commit.

---

## Deploying a new bounded context (GitOps via ArgoCD)

**ArgoCD is now the sole owner of every chart's Helm release lifecycle** —
every application in `terraform/applications.tf`'s registry (the
`local.services` contexts, network-inventory-planning, network-fulfillment,
`warehouse-ops-agent`, `warehouse-console` and the EventCatalog: 17
Applications). Terraform still bootstraps the
platform (kind, Postgres, Kafka, Istio, Kong, the Nginx web gateway, and
ArgoCD itself) and still computes every release's full environment values,
but it no longer runs `helm install`/`upgrade` directly for any of them — it
hands each one to ArgoCD instead.

**Registering a new service with the shared chart shape is two steps: add
it to `terraform/locals.tf`'s `local.services` map, and add its literal
`db_password` line to `local.app_db_passwords` in `terraform/applications.tf`**
(the plan fails until you do). That map feeds BOTH `terraform/services.tf`'s
`local.service_full_values` computation (database secret ref, Kong/Gateway
route, analytics, MCP, and every other conditional block already documented
there) AND the application registry in `terraform/applications.tf`, which
gives every entry one instance of `terraform/modules/application`
([ADR 0004](docs/adr/0004-one-application-registry.md)). Applications with
their own chart shape (`warehouse-ops-agent`, `warehouse-console`, the
EventCatalog, network-fulfillment, network-inventory-planning) get an
explicit entry in `local.other_applications` instead, with values computed in
their own file. A `terraform apply` after adding an entry:

1. Builds and side-loads the new service's image (the module's
   `null_resource.build_and_load`).
2. Creates its `<service>-db` Secret directly (the module's
   `kubernetes_secret.db`) — no chart ever sees a plaintext `DATABASE_URL`
   value through an ArgoCD `Application`'s Git/cluster-visible spec.
3. Applies a new `Application` CR pointed at that service's own
   `charts/<service>` in ITS OWN repo, with `syncPolicy.automated.prune` and
   `.selfHeal` both on. ArgoCD picks it up, installs the release, and from
   then on continuously reconciles it — including reverting manual
   `kubectl` drift automatically, something the old one-shot `terraform
   apply` never did.

Check status with:

```bash
kubectl -n argocd port-forward svc/argocd-server 8080:443 &
argocd app list                        # or: kubectl get applications -n argocd
argocd app get <service>
argocd app diff <service>              # should be empty on a healthy service
```

ArgoCD's own auth is **disabled** (`configs.params."server.disable.auth"` in
`helm-values/argocd.yaml`), matching this fleet's fully-unauthenticated
posture — every REST/MCP endpoint here already has no auth, and this was an
explicit, deliberate choice to keep ArgoCD consistent with that rather than
carve out an exception for the deployment control plane.

**ArgoCD is deliberately NOT exposed through either of the two product
edges** (`http://localhost` Nginx web gateway, `http://localhost:8000` Kong
API gateway) — both are reserved for product traffic per
[docs/exposure/localhost-edge-topology.md](docs/exposure/localhost-edge-topology.md).
Local admin access is `kubectl port-forward` only, same as above.

**Removing a service** is symmetric: delete its entry from `local.services`,
`terraform apply`, and `prune: true` deletes both the `Application` and the
Helm release it owned — no orphaned resources left behind.

**Image tags are content-derived**, not the fixed `"local"` value from
before this GitOps rollout: `modules/application` tags each image
`local-<hash12>` over the service's Go source/migrations/Dockerfile/go.mod/
go.sum. This is required, not cosmetic — ArgoCD's
sync only fires on an actual diff, and a tag that never changes on rebuild
gives it nothing to detect. This also happens to fix the older
"rebuilt image alone does not roll a running Deployment" pitfall documented
below, as a side effect.

---

## metrics-server (HPA support)

`var.deploy_metrics_server` (default `true`) installs the
kubernetes-sigs/metrics-server chart into `kube-system`. Every service
chart in this fleet already ships an `autoscaling/v2` HPA targeting
CPU/memory utilization; without a `metrics.k8s.io` API server in the
cluster those HPAs sit at `<unknown>` forever
(`kubectl describe hpa <name>` reports `FailedGetResourceMetrics`). This
resource is what makes them work.

It sets `--kubelet-insecure-tls` in the chart's `args` — a genuine
kind-specific need, not a general shortcut: kind's kubelet serving certs
are self-signed per-node at cluster boot and aren't trusted by
metrics-server by default, so without the flag every node scrape fails
with `x509: certificate signed by unknown authority`. See
`terraform/metrics-server.tf`'s header comment for the full rationale.
Verify it after an apply with:

```bash
kubectl top nodes
kubectl get hpa -n warehouse-systems
```

---

## Dashboards and alert rules (observability as code)

Both are GENERATED by `scripts/gen-context-dashboards.py` from one
per-context table (`CONTEXTS`); edit the table, re-run the script, commit
the output. Never hand-edit the JSON.

- `terraform/dashboards/contexts/<context>.json`: one Grafana dashboard per
  bounded context (plus `kong-gateway-overview.json`, `logs-overview.json`).
  5xx panels read Kong's `kong_http_requests_total` per route (API
  `<context>`, MCP `<context>-mcp`, reports `<context>-reports`), because
  otelchi records no status code. Contexts that export an outbox-lag gauge
  get a "Transactional outbox" row.
- `terraform/alerting/warehouse-alert-rules.json`: Prometheus alert rules,
  loaded by `observability.tf` into the prometheus chart's
  `serverFiles."alerting_rules.yml"`. Per context: `WarehouseKong5xxRatioHigh`
  (more than 5 % 5xx on one Kong route for 5 m), `WarehouseOutboxLagHigh`
  (outbox gauge above 60 s for 5 m; order-management, wes-work-planning,
  workforce-management, labor-performance, process-path-management) and
  `WarehousePodRestarting` (2 or more restarts in 15 m, from
  kube-state-metrics, which the same release now enables). Every rule's
  `runbook_url` annotation is that context's runbook page. There is no
  outbox dead-row rule (no context exports an attempt-cap metric; it is a log
  line and a SQL query) and no consumer-lag rule (no Kafka exporter runs).
- SLO burn-rate alerts, four per context in the sibling group
  `warehouse-<context>-slo` (same table, so rules, dashboards and runbook URLs
  cannot disagree). SLO 1 is API availability (99 % of Kong requests do not
  answer 5xx per day), SLO 2 is API latency (95 % of Kong requests have
  `kong_upstream_latency_ms` at or under 500 ms per day). Prometheus keeps 24 h
  (`retention`), so every window is one day, not 28 days. Burn = bad ratio /
  (1 − target); the day's budget lasts 24 h / burn:

  | Alert | SLO | Severity | Fires when (both windows hold, `for`) | Budget gone in |
  |---|---|---|---|---|
  | `WarehouseApiAvailabilityBurnFast` | 1 | critical | burn ≥ 14.4 over 1 h and 5 m (5xx ≥ 14.4 %), 2 m | ~100 min |
  | `WarehouseApiAvailabilityBurnSlow` | 1 | warning | burn ≥ 3 over 6 h and 30 m (5xx ≥ 3 %), 15 m | ~8 h |
  | `WarehouseApiLatencyBurnFast` | 2 | critical | burn ≥ 14.4 over 1 h and 5 m (slow ≥ 72 %), 2 m | ~100 min |
  | `WarehouseApiLatencyBurnSlow` | 2 | warning | burn ≥ 3 over 6 h and 30 m (slow ≥ 15 %), 15 m | ~8 h |

  Each is evaluated per Kong route and needs at least 30 requests in the long
  window, so one failed request on an idle local route cannot fire a critical
  alert. Kong 3.9 exports no `le="500"` bucket (its boundaries are 25, 50, 80,
  100, 250, 400, 700, 1000, … spelled `"400.0"`), so the latency rule counts on
  the nearest one, `le="400.0"`: a request between 400 and 500 ms counts as
  slow, which makes the alert slightly stricter than the 500 ms SLO. The
  existing `WarehouseKong5xxRatioHigh` stays as the coarse 5 %-for-5-minutes
  signal. The thresholds are constants at the top of the alert section of
  `scripts/gen-context-dashboards.py`.
- Alertmanager is ON in the Prometheus release (`observability.tf`): one
  replica, no PVC (emptyDir; silences on a disposable cluster are not worth a
  volume), 10m / 32Mi. Its only receiver is `null`, a receiver with no
  integrations, because a local cluster has no pager: **nothing is delivered
  anywhere**. What it gives is grouping (`group_by` alertname, context,
  service), inhibition (a `severity="critical"` alert inhibits the
  `severity="warning"` alerts with the same context and service), silences and
  the `/api/v2/alerts` view; a real receiver is added to
  `alertmanager.config.receivers` and the route when one exists. Prometheus
  finds it with no extra setting (the chart renders `alerting.alertmanagers`
  while `alertmanager.enabled` is true). Reach it with
  `kubectl -n observability port-forward svc/prometheus-alertmanager 9093:9093`;
  Grafana has an `Alertmanager` datasource for the same instance. Alerts also
  show on Prometheus `/alerts` and in the `ALERTS` series.

Gates: `make observability-check` (committed JSON equals the generator
output, valid JSON, no backslash escapes in PromQL, every context in
`local.services` has a dashboard, every rule names its runbook, every context
has the four SLO rules on a bucket Kong exports) and
`make alert-rules-check` (promtool `check rules` plus the unit tests in
`terraform/alerting/tests/`, including the burn-rate cases in
`warehouse-slo-burn-rules.test.yml`; uses docker when `promtool` is not
installed).
Both run in the CI job `observability-as-code`.

---

## Known gaps in the services (observed, deliberately not fixed here)

This task is infra-only. These are real and worth a follow-up in the service
repos, but rewriting handlers here would have been out of scope:

1. **`wes-work-planning` never runs its migrations.** `cmd/wes/main.go` calls
   `postgres.Connect()`, which is a bare `pgxpool.New()` — the other three
   services call `RunMigrations`/`Migrate` before serving. The pod starts,
   reports healthy and serves `GET /healthz` (the handler doesn't touch the
   database), but any endpoint that reads or writes will fail until
   `wes-work-planning/migrations` is applied by hand. Migrate-on-boot belongs
   in the service repo. This is observable on a running cluster — three of the
   four databases self-migrate, one does not:

   ```
   $ psql -U wes_work_planning    -d wes_work_planning    -c '\dt'
   Did not find any relations.
   $ psql -U inventory_storage    -d inventory_storage    -c '\dt'   ->  6 tables
   $ psql -U workforce_management -d workforce_management -c '\dt'   ->  7 tables
   $ psql -U fulfillment_execution -d fulfillment_execution -c '\dt' ->  6 tables
   ```

   Workaround until the service repo grows a migrate step:

   ```bash
   kubectl -n warehouse-systems exec deploy/wes-work-planning -c wes-work-planning -- ls migrations
   # then apply them with your migration tool of choice against wes_work_planning
   ```
2. **`fulfillment-execution` starts its inbound Kafka consumer
   unconditionally**, independent of `EVENT_PUBLISHER`. There is no broker in
   this cluster, so that goroutine logs connection failures on a loop. It is
   cosmetic — the HTTP server is unaffected and `/healthz` stays 200 — but it
   is noise in `kubectl logs`.
3. **No service's `/healthz` checks its database.** That makes the readiness
   probe a liveness probe in disguise: a pod can be `Ready` while its database
   is unreachable. Fine for a local cluster, wrong for anything real.
4. **Slow first boot on the three migrating services.** The chart's default
   liveness probe (`initialDelaySeconds: 5`, 3 failures) can kill a pod
   mid-migration on a cold database. Worked around in `helm-values/` by
   relaxing to `initialDelaySeconds: 15` / `failureThreshold: 6` — a values
   change only. A `startupProbe` in the charts would be the better fix.

---

## Tear down

```bash
cd warehouse-infra
./scripts/down.sh
```

That runs `terraform destroy`, which removes the Helm releases and then deletes
the kind cluster (which is what actually reclaims the Docker containers and
their disk). If `destroy` fails part-way — typically a Helm release that can't
be reached because the API server is already gone — the script falls back to
deleting the cluster directly.

By hand:

```bash
cd warehouse-infra/terraform
terraform destroy -auto-approve
kind delete cluster --name warehouse   # only if destroy left it behind
```

The locally built `warehouse/*:local-<hash12>` images stay in your Docker
daemon. Remove them with:

```bash
docker images --format '{{.Repository}}:{{.Tag}}' 'warehouse/*' | xargs docker rmi
```

---

## Layout

```
warehouse-infra/
├── README.md
├── docs/
│   └── adr/                     # architecture decision records; index in docs/adr/README.md
├── helm-values/                 # static per-service environment config (one file per service; excerpt)
│   ├── _README.md
│   ├── inventory-storage.yaml
│   ├── inbound-receiving.yaml
│   ├── slotting-optimization.yaml
│   ├── product-master.yaml
│   ├── wes-work-planning.yaml
│   ├── workforce-management.yaml
│   ├── argocd.yaml              # ArgoCD release values (probe budgets, render parallelism limit)
│   ├── kind-resources/          # generated per-Application CPU-request overlays (kind only)
│   └── fulfillment-execution.yaml
├── scripts/
│   ├── up.sh                    # single entrypoint: init + apply + next steps
│   ├── down.sh                  # destroy + fallback cluster delete
│   ├── build-and-load.sh        # docker build + kind load, called by Terraform
│   ├── smoke-test.sh            # curls all four /healthz through Kong
│   └── seed-transfer-capability.py  # post-deploy: site transfer capability from role defaults
└── terraform/
    ├── versions.tf              # Terraform + provider pins
    ├── providers.tf             # kind / kubernetes / helm wiring
    ├── variables.tf             # every knob, with the reasoning for each pin
    ├── locals.tf                # every bounded context in one map (local.services; product-master included)
    ├── main.tf                  # kind cluster + namespaces
    ├── postgres.tf              # PostgreSQL release + 4 databases
    ├── istio.tf                 # istio-base -> istiod
    ├── kong.tf                  # Kong Gateway + Ingress Controller
    ├── services.tf              # computed Helm values of the local.services contexts
    ├── argocd.tf                # ArgoCD release (helm-values/argocd.yaml)
    ├── kind-overlay.tf          # merges helm-values/kind-resources/*.yaml into each valuesObject
    ├── applications.tf          # the application registry: one modules/application instance each (ADR 0004)
    ├── moved-applications.tf    # state moves onto the module (ADR 0002 D3)
    ├── outputs.tf
    ├── modules/
    │   └── application/         # one application's platform contract: DB passwords, Secrets, images, Application
    └── templates/
        └── init-databases.sql.tftpl
```

---

## Design notes

**Why the `tehcyx/kind` Terraform provider and not `local-exec kind create`.**
The provider was validated before adoption — it creates a two-node
`kindest/node:v1.36.1` cluster against Docker 29.7.2 in ~27s, accepts
`extra_port_mappings`, and participates properly in `terraform destroy`. A
shell wrapper would have needed hand-written create/destroy/idempotency logic
for no benefit. The kind **CLI** is still used for two narrow jobs where it is
the right tool: exporting the kubeconfig (`null_resource.kubeconfig`, a safety
net so the providers always have a valid file) and side-loading images.

**Why the providers read the cluster's credential attributes, not a
kubeconfig path.** This was got wrong first and fixed: pointing
`kubernetes`/`helm` at a `config_path` is *racy*. Terraform evaluates a
provider node early in the graph walk, before the resources that depend on it,
so on a clean apply the kubeconfig file does not exist yet and both providers
silently fall back to their default host — which surfaces as
`Post "http://localhost/api/v1/namespaces": EOF` rather than an honest error.
Putting `depends_on` on the *resource* does not help, because it is the
*provider* that needs the ordering. Configuring both providers from
`kind_cluster.warehouse.endpoint` / `.cluster_ca_certificate` /
`.client_certificate` / `.client_key` creates a real dependency edge from the
provider node to the cluster resource, so they are configured only after the
cluster exists — and a single `terraform apply` works from clean state.
Nothing here is machine-specific.

`null_resource.kubeconfig` still exports credentials, but purely for the
human's benefit: setting `kubeconfig_path` on `kind_cluster` makes the provider
write to that file *instead of* your default kubeconfig, which would leave
plain `kubectl` with no `kind-warehouse` context. It exports to both.

**Why `kong/kong` and not `kong/ingress`.** `kong/kong` is one release running
the gateway and the ingress controller as two containers in one pod, DB-less,
with KIC on by default. `kong/ingress` is an umbrella that splits them into two
subchart releases wired together by `gatewayDiscovery` — more moving parts and
more to go wrong, for no benefit at this scale. Routing started as plain
`Ingress` objects; it now uses Gateway API `HTTPRoute`s that each chart
renders against the shared `warehouse-gateway` Gateway
(`terraform/gateway-api.tf`, `deploy_gateway_api`, on by default). How those
Gateway API platform objects are installed is set by
[ADR 0002](docs/adr/0002-application-delivery-boundary.md), decision D5.

**Why sidecar Istio and not ambient.** Sidecar mode needs no CNI DaemonSet and
no ztunnel, which is markedly less fragile inside kind, and namespace-label
injection requires zero application changes.

**Why images are built by Terraform rather than by the script.** A
`null_resource` per service, triggered by a hash over that service's `**/*.go`,
`migrations/**`, `Dockerfile`, `go.mod` and `go.sum`, keeps the whole thing a
single `terraform apply` while still rebuilding only what changed. Images are
tagged `warehouse/<service>:local-<hash12>` (the first 12 characters of that
same source hash, computed in `terraform/modules/application`), so a
rebuilt image always carries a new tag and ArgoCD rolls the pods. They use
`pullPolicy: IfNotPresent`, because they exist only in the kind nodes'
containerd store and must never be pulled from Docker Hub.
