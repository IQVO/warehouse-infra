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
http://localhost        ->  Nginx web gateway  ->  console shell + /mfes/<context>/ remotes
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

## Process-path catalogue

`config/process-paths/sortable-fc.yaml` is the published-language source of
truth for this fleet's process paths (`PICK`, `PACK`, `REBIN`, `SLAM`) —
their ids, and the capability vocabulary each one requires. It is read by
three services (fulfillment-execution, wes-work-planning,
workforce-management), none of which owns it individually, for the same
reason `terraform/locals.tf`'s `services` map lives in this repo: it is a
fact about what exists in this deployment, not business logic belonging to
any one bounded context. See the file's own header comment for the full
schema and rationale.

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

**Storage is ephemeral by design.** `postgres_persistence_enabled` defaults to
`false`. initdb scripts only run against an empty data directory, so a
PersistentVolumeClaim would cause a restarted pod to silently skip database
creation. An emptyDir keeps `terraform apply` reproducible from any state,
which is what a laptop cluster wants. Set
`-var postgres_persistence_enabled=true` if you need data to survive a pod
restart, and accept that you then own the migration story.

Credentials are deterministic dev values (`postgres` / `<db name>`), not
`random_password`, so the commands in this README are copy-pasteable and a
re-apply cannot rotate a credential out from under a running pod. **Local dev
only.**

---

## Where the manifests live

**Decision: each service repo owns its own Helm chart; `warehouse-infra` owns
only the environment.** There is exactly one copy of every manifest.

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
the ArgoCD `Application` source's `path` field (`argocd-apps.tf`).

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
all 8 database-backed bounded-context services, `warehouse-ops-agent`, and
`warehouse-console` (10 Applications total). Terraform still bootstraps the
platform (kind, Postgres, Kafka, Istio, Kong, the Nginx web gateway, and
ArgoCD itself) and still computes every release's full environment values,
but it no longer runs `helm install`/`upgrade` directly for any of them — it
hands each one to ArgoCD instead.

**Registering a new service is still exactly one step: add it to
`terraform/locals.tf`'s `local.services` map.** Nothing else changes. That
map feeds BOTH `terraform/services.tf`'s `local.service_full_values`
computation (image tag, database secret ref, Kong/Gateway route, analytics,
MCP, and every other conditional block already documented there) AND
`terraform/argocd-apps.tf`'s `kubectl_manifest.application` resource, which
`for_each`-es over that same map. (`warehouse-ops-agent` and
`warehouse-console` sit outside `local.services` — no database — and each
gets its own single, explicitly-named `kubectl_manifest` resource instead;
see `ops-agent.tf`'s `local.ops_agent_helm_values` and `frontends.tf`'s
`local.console_helm_values`.) A `terraform apply` after adding an entry:

1. Builds and side-loads the new service's image
   (`null_resource.build_and_load`, unchanged from before).
2. Creates its `<service>-db` Secret directly
   (`kubernetes_secret.service_db` in `postgres.tf`) — no chart ever sees a
   plaintext `DATABASE_URL` value through an ArgoCD `Application`'s
   Git/cluster-visible spec.
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
before this GitOps rollout: `local.service_image_tags[name]` hashes each
service's Go source/migrations/Dockerfile/go.mod/go.sum (mirroring the
existing `service_source_hash`). This is required, not cosmetic — ArgoCD's
sync only fires on an actual diff, and a tag that never changes on rebuild
gives it nothing to detect. This also happens to fix the older
"rebuilt image alone does not roll a running Deployment" pitfall documented
below, as a side effect.

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

The locally built `warehouse/*:local` images stay in your Docker daemon. Remove
them with:

```bash
docker rmi warehouse/inventory-storage:local warehouse/wes-work-planning:local \
           warehouse/workforce-management:local warehouse/fulfillment-execution:local
```

---

## Layout

```
warehouse-infra/
├── README.md
├── helm-values/                 # static per-service environment config
│   ├── _README.md
│   ├── inventory-storage.yaml
│   ├── wes-work-planning.yaml
│   ├── workforce-management.yaml
│   └── fulfillment-execution.yaml
├── scripts/
│   ├── up.sh                    # single entrypoint: init + apply + next steps
│   ├── down.sh                  # destroy + fallback cluster delete
│   ├── build-and-load.sh        # docker build + kind load, called by Terraform
│   └── smoke-test.sh            # curls all four /healthz through Kong
└── terraform/
    ├── versions.tf              # Terraform + provider pins
    ├── providers.tf             # kind / kubernetes / helm wiring
    ├── variables.tf             # every knob, with the reasoning for each pin
    ├── locals.tf                # the four bounded contexts in one map
    ├── main.tf                  # kind cluster + namespaces
    ├── postgres.tf              # PostgreSQL release + 4 databases
    ├── istio.tf                 # istio-base -> istiod
    ├── kong.tf                  # Kong Gateway + Ingress Controller
    ├── services.tf              # build/load + the four service releases
    ├── outputs.tf
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
more to go wrong, for no benefit at this scale. Routing is therefore plain
`Ingress` objects, which the existing service charts already emit; **no Gateway
API CRDs are needed.**

**Why sidecar Istio and not ambient.** Sidecar mode needs no CNI DaemonSet and
no ztunnel, which is markedly less fragile inside kind, and namespace-label
injection requires zero application changes.

**Why images are built by Terraform rather than by the script.** A
`null_resource` per service, triggered by a hash over that service's `**/*.go`,
`migrations/**`, `Dockerfile`, `go.mod` and `go.sum`, keeps the whole thing a
single `terraform apply` while still rebuilding only what changed. Images are
tagged `warehouse/<service>:local` with `pullPolicy: IfNotPresent`, because
they exist only in the kind nodes' containerd store and must never be pulled
from Docker Hub.
