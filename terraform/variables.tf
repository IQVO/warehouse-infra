# ---------------------------------------------------------------------------
# Cluster
# ---------------------------------------------------------------------------

variable "cluster_name" {
  description = "Name of the kind cluster. The kubectl context becomes kind-<cluster_name>."
  type        = string
  default     = "warehouse"
}

variable "kind_node_image" {
  description = <<-EOT
    kind node image, digest-pinned. This is the default image shipped with
    kind v0.32.0 — if you upgrade kind, re-pin this to the new default
    (`strings $(which kind) | grep kindest/node`), because an image newer than
    the kind library embedded in the tehcyx/kind provider will not boot.
  EOT
  type        = string
  default     = "kindest/node:v1.36.1@sha256:3489c7674813ba5d8b1a9977baea8a6e553784dab7b84759d1014dbd78f7ebd5"
}

variable "worker_count" {
  description = "Number of kind worker nodes (in addition to the control-plane node)."
  type        = number
  default     = 1
}

# ---------------------------------------------------------------------------
# Kong north-south exposure
#
# There is no cloud load balancer here, so Kong's proxy Service is a NodePort
# and kind's extraPortMappings publish that NodePort on a host port. This is
# the only ingress path into the cluster from the host.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Frontends and the Nginx web gateway (ADR-0005).
#
# The product has TWO host-facing entrypoints and they are deliberately
# independent -- the web gateway serves frontend bytes, Kong serves APIs, and
# neither proxies to the other. Both bind to 127.0.0.1 only, because every
# REST/MCP endpoint in this fleet is currently unauthenticated.
# ---------------------------------------------------------------------------

variable "deploy_frontends" {
  description = <<-EOT
    Deploy the product UI: the warehouse-console shell, the eight bounded-context
    Module Federation remotes (each served by its own nginx pod), and the Nginx
    web gateway that routes between them on host port 80.

    Requires each context repo's frontend chart templates (frontend.enabled) and
    warehouse-console's runtime /config.json support, all merged 2026-09-12.
  EOT
  type        = bool
  default     = true
}

variable "web_gateway_node_port" {
  description = "NodePort for the Nginx web gateway."
  type        = number
  default     = 30081
}

variable "web_gateway_host_port" {
  description = <<-EOT
    Host port for the Nginx web gateway -- where the product UI actually lives.
    Defaults to 80 so the console is at http://localhost/.

    Note Kong moved OFF port 80 to make room for this (see
    kong_proxy_http_host_port, now 8000). kind's extraPortMappings are
    immutable, so changing either port requires a cluster destroy/recreate.
  EOT
  type        = number
  default     = 80
}

variable "cluster_dns_ip" {
  description = <<-EOT
    ClusterIP of kube-dns, used as the Nginx web gateway's `resolver`.

    This must be an IP, not a DNS name: nginx cannot resolve its own resolver,
    and a name here fails config parsing outright with "host not found in
    resolver" -- the container never starts. Caught by running `nginx -t`
    against the rendered config before deploying it.

    10.96.0.10 is kubeadm's deterministic choice (the .10 address of the
    default 10.96.0.0/16 service CIDR, confirmed live against this cluster),
    so it survives a destroy/recreate. Override if the service CIDR changes.
  EOT
  type        = string
  default     = "10.96.0.10"
}

variable "web_gateway_image" {
  description = "Image for the Nginx web gateway. Unprivileged: it listens on 8080 as uid 101."
  type        = string
  default     = "nginxinc/nginx-unprivileged:1.31-alpine"
}

variable "api_path_prefix" {
  description = <<-EOT
    Public path prefix for every bounded-context API behind Kong, e.g.
    /api/order-management. Kong strips it before forwarding, so each Go router
    keeps its existing unprefixed contract.

    This exists because the old routes were /<service>, which collide head-on
    with the console shell's own client-side routes (/order-management is a
    page in the SPA). Separating the namespaces is what lets both live at
    localhost without ambiguity.
  EOT
  type        = string
  default     = "/api"
}

variable "kong_cors_enabled" {
  description = <<-EOT
    Attach Kong's CORS plugin to every API route, granting exactly the web
    gateway's origin.

    This is load-bearing rather than optional: the product deliberately serves
    assets and APIs from two different origins, so without it every browser
    call from the console is blocked. Never widen this to "*" -- these
    endpoints are unauthenticated.
  EOT
  type        = bool
  default     = true
}

variable "kong_proxy_http_node_port" {
  description = "NodePort inside the cluster for Kong's HTTP proxy listener."
  type        = number
  default     = 30080
}

variable "kong_proxy_https_node_port" {
  description = "NodePort inside the cluster for Kong's HTTPS proxy listener."
  type        = number
  default     = 30443
}

variable "kong_proxy_http_host_port" {
  description = <<-EOT
    Host port mapped to the Kong HTTP NodePort: the product's API origin,
    http://localhost:8000.

    This was 80 until the Nginx web gateway took that port for the product UI
    (ADR-0005). Kong serves APIs only and must never serve HTML/JS/CSS, so the
    two edges get their own ports rather than one proxying to the other.
  EOT
  type        = number
  default     = 8000
}

variable "kong_proxy_https_host_port" {
  description = "Host port mapped to the Kong HTTPS NodePort. Defaults to 443."
  type        = number
  default     = 443
}

# ---------------------------------------------------------------------------
# Observability + Kiali north-south exposure
#
# Same pattern as Kong above: no cloud load balancer, so each UI's Service is
# a NodePort and kind's extraPortMappings publish that NodePort on a host
# port at cluster-creation time. This replaces ad-hoc `kubectl port-forward`
# for these UIs — a host port survives pod restarts and multiple terminal
# tabs; a port-forward process does neither.
# ---------------------------------------------------------------------------

variable "grafana_node_port" {
  description = "NodePort inside the cluster for Grafana."
  type        = number
  default     = 30300
}

variable "grafana_host_port" {
  description = "Host port mapped to Grafana's NodePort. Grafana is reachable at http://localhost:<this>/."
  type        = number
  default     = 3000
}

variable "jaeger_node_port" {
  description = "NodePort inside the cluster for the Jaeger query UI."
  type        = number
  default     = 30686
}

variable "jaeger_host_port" {
  description = "Host port mapped to Jaeger's NodePort. Jaeger is reachable at http://localhost:<this>/."
  type        = number
  default     = 16686
}

variable "prometheus_node_port" {
  description = "NodePort inside the cluster for the Prometheus UI."
  type        = number
  default     = 30909
}

variable "prometheus_host_port" {
  description = "Host port mapped to Prometheus's NodePort. Prometheus is reachable at http://localhost:<this>/."
  type        = number
  default     = 9090
}

variable "kiali_node_port" {
  description = "NodePort inside the cluster for the Kiali UI."
  type        = number
  default     = 30200
}

variable "kiali_host_port" {
  description = "Host port mapped to Kiali's NodePort. Kiali is reachable at http://localhost:<this>/."
  type        = number
  default     = 20001
}

# ---------------------------------------------------------------------------
# Namespaces
# ---------------------------------------------------------------------------

variable "data_namespace" {
  description = "Namespace holding the shared PostgreSQL release."
  type        = string
  default     = "warehouse-data"
}

variable "apps_namespace" {
  description = "Namespace holding the four bounded-context services. Labelled istio-injection=enabled."
  type        = string
  default     = "warehouse-systems"
}

variable "kong_namespace" {
  description = "Namespace holding Kong (gateway + ingress controller)."
  type        = string
  default     = "kong"
}

# ---------------------------------------------------------------------------
# Chart versions — all resolved against live registries, none guessed.
# ---------------------------------------------------------------------------

variable "postgresql_chart_version" {
  description = <<-EOT
    Bitnami postgresql chart version, pulled from the OCI registry
    oci://registry-1.docker.io/bitnamicharts/postgresql.

    16.7.4 is deliberately NOT the newest chart. Bitnami moved its versioned
    public images behind "Bitnami Secure Images" in 2025: the current chart
    (18.x) defaults to `bitnami/postgresql:latest`, an unpinned rolling tag.
    The frozen, version-pinned images live in the `bitnamilegacy` Docker Hub
    org. Chart 16.7.4 (appVersion 17.5.0) is the last coherent pair where the
    chart's own default tag still exists verbatim under bitnamilegacy, so the
    whole stack stays reproducible. See postgres.tf for the image override.
  EOT
  type        = string
  default     = "16.7.4"
}

variable "postgresql_image_tag" {
  description = "PostgreSQL image tag under docker.io/bitnamilegacy. Must match the chart's appVersion."
  type        = string
  default     = "17.5.0-debian-12-r3"
}

variable "istio_version" {
  description = "Istio chart version for istio/base and istio/istiod (must match each other)."
  type        = string
  default     = "1.30.3"
}

variable "kong_chart_version" {
  description = "kong/kong chart version (bundles Kong Gateway + Kong Ingress Controller in one release)."
  type        = string
  default     = "3.4.1"
}

# ---------------------------------------------------------------------------
# Credentials — LOCAL DEV ONLY
#
# These are deliberately deterministic (not random_password) so the README's
# psql/curl examples are copy-pasteable and so a re-apply does not silently
# rotate credentials out from under a running pod. Never reuse this pattern
# for anything reachable from outside a laptop.
# ---------------------------------------------------------------------------

variable "postgres_admin_password" {
  description = "Password for the PostgreSQL superuser. LOCAL DEV ONLY."
  type        = string
  default     = "postgres"
  sensitive   = true
}

variable "postgres_persistence_enabled" {
  description = <<-EOT
    Whether the PostgreSQL primary gets a PersistentVolumeClaim.

    Defaults to false (emptyDir). The four logical databases are created by
    `primary.initdb.scripts`, and initdb scripts only run when the data
    directory is empty — with persistence on, a pod restart would reuse the old
    volume and silently skip them. Ephemeral storage keeps `terraform apply`
    reproducible from any state, which is what a local cluster wants.
  EOT
  type        = bool
  default     = false
}

# ---------------------------------------------------------------------------
# Application images
# ---------------------------------------------------------------------------

variable "image_tag" {
  description = "Tag applied to the four locally-built service images (warehouse/<service>:<tag>)."
  type        = string
  default     = "local"
}

variable "deploy_services" {
  description = "Set false to stand up only the platform (cluster, Postgres, Istio, Kong) without building/deploying the four services."
  type        = bool
  default     = true
}

# ---------------------------------------------------------------------------
# Kafka
#
# Independent on/off switch from deploy_services: the fleet's services all
# default to EVENT_PUBLISHER=log / kafka.enabled=false in their own
# helm-values, so nothing breaks with Kafka off. Turning it on is what lets
# EVENT_PUBLISHER=kafka actually deliver anywhere.
# ---------------------------------------------------------------------------

variable "deploy_kafka" {
  description = "Whether to install the single-broker Kafka release (kafka.tf)."
  type        = bool
  default     = true
}

variable "kafka_chart_version" {
  description = <<-EOT
    Bitnami kafka chart version, pulled from the OCI registry
    oci://registry-1.docker.io/bitnamicharts/kafka.
  EOT
  type        = string
  default     = "32.4.3"
}

variable "kafka_image_tag" {
  description = "Kafka image tag under docker.io/bitnamilegacy. Must match the chart's appVersion."
  type        = string
  default     = "4.0.0-debian-12-r10"
}

variable "kafka_persistence_enabled" {
  description = <<-EOT
    Whether the Kafka controller/broker gets a PersistentVolumeClaim.

    Defaults to false (emptyDir), matching postgres_persistence_enabled's
    reasoning: a laptop kind cluster is disposable, and every topic here is
    either integration events (replayable from the OLTP source of truth) or
    an analytics fan-out (rebuildable by a projector re-consuming from
    FirstOffset) — nothing stored in Kafka itself is the sole copy of
    anything.
  EOT
  type        = bool
  default     = false
}

# ---------------------------------------------------------------------------
# Kafka host exposure — ONE broker for the whole platform.
#
# Before this existed, the fleet ran TWO Kafkas: this in-cluster release for
# pods, and a separate docker-compose broker (container "warehouse-kafka",
# ~/warehouse-systems/docker-compose.kafka.yml) on host port 9092 for the
# out-of-cluster consumers — `go run` local development and the e2e-tests
# harness (its env.sh pins KAFKA_BROKERS=localhost:9092). Two brokers with
# the same name and no relationship is a topology, not a convenience: an
# event published in-cluster was invisible to a host consumer and vice
# versa, so which broker you were on silently changed the behaviour.
#
# The Bitnami chart's externalAccess gives the single in-cluster broker a
# SECOND advertised listener. Kafka clients bootstrap by asking the broker
# for its advertised address and then reconnect to whatever it answers, so
# a broker serving both audiences must advertise a different address to
# each: in-cluster pods keep the pod's headless DNS name on the CLIENT
# listener, while host clients get EXTERNAL://localhost:9092. That is why
# this is externalAccess and not simply another NodePort Service like
# exposure.tf's UIs — a plain Service would route the TCP connection
# correctly and then hand the host client an unreachable in-cluster
# address on the very next round trip.
# ---------------------------------------------------------------------------

variable "kafka_external_access_enabled" {
  description = <<-EOT
    Whether the in-cluster Kafka broker also advertises a host-reachable
    EXTERNAL listener on localhost:<kafka_host_port>. Set false to make the
    broker cluster-internal only (nothing on the host can reach it).
  EOT
  type        = bool
  default     = true
}

variable "kafka_node_port" {
  description = <<-EOT
    NodePort inside the cluster for Kafka's EXTERNAL listener.

    Deliberately 9092 — the same number as the host port — so there is one
    Kafka port to remember across the whole fleet. This is BELOW the default
    service-node-port-range (30000-32767), which is why main.tf patches the
    apiserver's --service-node-port-range; without that patch the Service is
    rejected with "provided port is not in the valid range".
  EOT
  type        = number
  default     = 9092
}

variable "kafka_host_port" {
  description = <<-EOT
    Host port mapped to Kafka's NodePort. Kafka is reachable from the host at
    localhost:<this>, which is the address e2e-tests/env.sh and every service
    repo's README already use.
  EOT
  type        = number
  default     = 9092
}

variable "service_node_port_range" {
  description = <<-EOT
    The apiserver's --service-node-port-range, applied via a kubeadm config
    patch in main.tf. Widened from the 30000-32767 default down to 9000 so
    Kafka's NodePort can be 9092 (see kafka_node_port). Kong's and the
    observability UIs' NodePorts stay in the 30000s and are unaffected.
  EOT
  type        = string
  default     = "9000-32767"
}


# ---------------------------------------------------------------------------
# Observability
#
# A separate namespace and a separate on/off switch from the services, on
# purpose: the five bounded contexts export OTLP on a non-blocking exporter and
# start fine with nothing listening on the other end, so this stack is never a
# prerequisite for them. See observability.tf.
# ---------------------------------------------------------------------------

variable "observability_namespace" {
  description = "Namespace holding the OTel Collector, Jaeger, Prometheus and Grafana. NOT istio-injected — this is telemetry plumbing, not application traffic."
  type        = string
  default     = "observability"
}

variable "deploy_observability" {
  description = "Set false to skip the whole observability stack (OTel Collector, Jaeger, Prometheus, Grafana). The services do not depend on it."
  type        = bool
  default     = true
}

variable "jaeger_chart_version" {
  description = <<-EOT
    jaegertracing/jaeger chart version from https://jaegertracing.github.io/helm-charts.

    4.12.0 (appVersion 2.20.0) is the current release, resolved with
    `helm search repo jaegertracing/jaeger --versions`. Chart 4.x deploys
    Jaeger v2 as a single all-in-one Deployment whose default configuration
    uses in-memory storage — no Elasticsearch or Cassandra, which is the right
    trade for a laptop cluster. Jaeger v2 also accepts OTLP directly on 4317,
    so the Collector talks to it with the plain `otlp` exporter rather than the
    long-deprecated `jaeger` exporter component.
  EOT
  type        = string
  default     = "4.12.0"
}

variable "prometheus_chart_version" {
  description = <<-EOT
    prometheus-community/prometheus chart version.

    This is the PLAIN Prometheus chart, not kube-prometheus-stack: it ships no
    Prometheus Operator and therefore no ServiceMonitor/PodMonitor CRDs. Scrape
    targets are configured as ordinary `scrape_configs` entries in
    prometheus.yml (see observability.tf), which is both simpler and the only
    thing that actually works with this chart.
  EOT
  type        = string
  default     = "29.27.0"
}

variable "grafana_chart_version" {
  description = "grafana/grafana chart version. Datasources are pre-provisioned from values; see observability.tf."
  type        = string
  default     = "10.5.15"
}

variable "otel_collector_chart_version" {
  description = <<-EOT
    open-telemetry/opentelemetry-collector chart version.

    The chart's default image is `otel/opentelemetry-collector-contrib`
    (verified by rendering the chart: `helm template ... | grep image:` yields
    otel/opentelemetry-collector-contrib:0.158.0), which matters because the
    `prometheus` EXPORTER used below is a contrib-only component — it is not in
    the core `otel/opentelemetry-collector` distribution. The repository is
    still pinned explicitly in observability.tf so a chart bump cannot silently
    move us to a distribution without it.
  EOT
  type        = string
  default     = "0.170.0"
}

variable "grafana_admin_password" {
  description = "Grafana admin password. Deterministic dev value, same rationale as the Postgres credentials above. LOCAL DEV ONLY."
  type        = string
  default     = "admin"
  sensitive   = true
}

# ---------------------------------------------------------------------------
# Kiali — service mesh observability UI for Istio.
# ---------------------------------------------------------------------------

variable "deploy_kiali" {
  description = "Whether to install Kiali (kiali.tf). Depends on Istio and Prometheus; has no effect if either is off."
  type        = bool
  default     = true
}

variable "kiali_chart_version" {
  description = <<-EOT
    kiali/kiali-server chart version from https://kiali.org/helm-charts.

    2.31.0 is the current release, resolved with `helm search repo
    kiali/kiali-server --versions`.
  EOT
  type        = string
  default     = "2.31.0"
}

# ---------------------------------------------------------------------------
# Logging — Loki + Alloy (see logging.tf for the full rationale).
# ---------------------------------------------------------------------------

variable "deploy_logging" {
  description = <<-EOT
    Whether to install Loki + Alloy (logging.tf). Independent of
    deploy_observability's other components so `-var=deploy_logging=false`
    can drop just the log stack while keeping traces/metrics, but gated
    behind deploy_observability too since logging without the rest of the
    observability namespace makes no sense on its own.
  EOT
  type        = bool
  default     = true
}

variable "loki_chart_version" {
  description = <<-EOT
    grafana/loki chart version, resolved with `helm search repo grafana/loki
    --versions` against https://grafana.github.io/helm-charts.
  EOT
  type        = string
  default     = "7.3.0"
}

variable "alloy_chart_version" {
  description = <<-EOT
    grafana/alloy chart version, resolved with `helm search repo
    grafana/alloy --versions` against https://grafana.github.io/helm-charts.
    Alloy (not Promtail) is Grafana Labs' current log-collection agent;
    Promtail is in long-term support only.
  EOT
  type        = string
  default     = "1.12.1"
}

variable "loki_retention_period" {
  description = <<-EOT
    How long Loki keeps ingested logs before its compactor deletes them.
    24h matches Prometheus's own retention (observability.tf) and the same
    "disposable laptop cluster" reasoning: nothing here is meant to survive
    long-term, and a laptop's disk is the actual constraint.
  EOT
  type        = string
  default     = "24h"
}

# ---------------------------------------------------------------------------
# Gateway API — pilot phase (see gateway-api.tf and kong.tf's header).
# ---------------------------------------------------------------------------

variable "deploy_gateway_api" {
  description = <<-EOT
    Whether to install the Gateway API CRDs, GatewayClass, and the shared
    Gateway (gateway-api.tf). Independent of Kong's own deployment: Kong
    installs unconditionally either way, this only adds the Gateway API
    platform pieces on top.

    RESOLVED: an earlier iteration of this pilot found KIC 3.5's `Gateway`
    controller appearing to silently stop reconciling after one pass at
    startup, reproduced across two KIC patch versions and two Helm
    deployment topologies (single-release and gatewayDiscovery
    split-release). Root cause turned out to be a real, documented KIC
    behavior, not a bug: `GatewayClass` objects require the
    `konghq.com/gatewayclass-unmanaged: "true"` annotation to be
    reconciled when Kong's dataplane is deployed via
    `deployment.kong.enabled=true` rather than provisioned dynamically by
    KIC/Kong Gateway Operator per-Gateway (an "unmanaged" gateway in KIC's
    terminology -- exactly this fleet's topology). Without the
    annotation, the `Gateway` controller has no code path to follow and
    goes idle after its first pass. With it, the Gateway immediately
    reaches `Accepted: True` / `Programmed: True`
    ("this unmanaged gateway has been picked up by the controller and
    will be processed"), and a real end-to-end curl through a resulting
    HTTPRoute on a path that only exists via that route (not the
    pre-existing Ingress) returned 200. See gateway-api.tf's GatewayClass
    comment for the full verification trail.
  EOT
  type        = bool
  default     = true
}

variable "gateway_api_version" {
  description = <<-EOT
    kubernetes-sigs/gateway-api release tag for the standard-channel CRD
    bundle, resolved from
    https://github.com/kubernetes-sigs/gateway-api/releases/latest.
  EOT
  type        = string
  default     = "v1.6.2"
}

variable "deploy_process_path_kafka_source" {
  description = <<-EOT
    Whether fulfillment-execution, wes-work-planning, and
    workforce-management source their process-path catalogue from
    process-path-management's Kafka topic
    (warehouse.process-path-management.events) instead of the static
    config/process-paths/sortable-fc.yaml file (see locals.tf's
    path_catalogue_* comment for the full "SUPERSEDED" rationale).

    Default true since the 2026-09-06 cutover: the cluster was flipped,
    process-path-management was seeded (scripts/seed-process-paths.py)
    and live propagation was verified without consumer restarts. Setting
    this false is the documented rollback: every consumer's chart still
    defaults PATH_CATALOGUE_SOURCE to "file", so the frozen
    config/process-paths/sortable-fc.yaml mount returns unchanged.

    Setting this true does three things per consumer (fulfillment-execution,
    wes-work-planning, workforce-management): (1) pathCatalogue.enabled
    flips to false, so the file ConfigMap volume/mount disappears from
    that chart's render; (2) PATH_CATALOGUE_SOURCE=kafka is injected via
    the chart's own extraEnv (each chart already unconditionally sets
    KAFKA_BROKERS, so no separate wiring is needed for that); (3) nothing
    else about the consumer changes -- same Service, same route, same
    database.

    It also flips process-path-management's OWN config.eventPublisher
    from the chart's "log" default to "kafka", since there would
    otherwise be nothing for the three consumers to actually consume.

    This is deliberately independent from var.deploy_services (which
    controls whether process-path-management is deployed AT ALL, since
    it is unconditionally a member of local.services): a cluster can run
    process-path-management without any consumer having switched over
    yet, which is the intended rollout order -- deploy the new service
    first, prove its own REST API and Kafka publish path work, THEN flip
    this flag once satisfied.
  EOT
  type        = bool
  default     = true
}

variable "deploy_order_management_path_catalogue_kafka" {
  description = <<-EOT
    Whether order-management validates a resolved process-path against
    process-path-management's Kafka topic
    (warehouse.process-path-management.events) before persisting an
    order, instead of skipping that validation entirely (order-management
    ADR-0013 / PATH_CATALOGUE_SOURCE=none|kafka).

    This is INDEPENDENT of var.deploy_process_path_kafka_source above:
    order-management is a NEW consumer of this topic (it never had a
    static file-based catalogue like fulfillment-execution /
    wes-work-planning / workforce-management did), so there is no
    rollback-to-file case to preserve here -- only "skip validation"
    (false, the chart's default) or "validate for real" (true).

    Default false until the discriminating live-propagation probe
    (see order-management's process-path-selection plan, Phase 4) has
    been run against this specific consumer: flipping this before that
    verification would silently start rejecting real orders if
    order-management's own kafkacatalog consumer has any wiring bug the
    probe would have caught. Setting this true injects
    PATH_CATALOGUE_SOURCE=kafka via order-management's chart extraEnv;
    KAFKA_BROKERS needs no separate wiring since order-management's
    helm-values already sets config.eventPublisher=kafka unconditionally
    (it already publishes integration/analytics events), so the chart
    already renders KAFKA_BROKERS regardless of this flag.

    Flipped to true on 2026-09-10 after the Phase 4 probe verified live
    propagation end-to-end (see the process-path-selection plan's Phase 4
    section for the exact commands run): a fresh path defined in
    process-path-management became acceptable to order-management within
    seconds with no restart, and deactivating it flipped order-management
    back to rejecting it with its own 400 -- the actual regression this
    whole feature exists to fix.
  EOT
  type        = bool
  default     = true
}

variable "deploy_facility_events_integration" {
  description = <<-EOT
    Whether inventory-storage sources location classifications from
    facility-layout's Kafka topic (warehouse.facility.events) instead of
    calling that service synchronously over HTTP on every stow.

    Default true since the 2026-09-06 cutover (inventory-storage is
    facility-layout's first real event consumer, ADR 0013). Setting this
    false is the documented rollback: inventory-storage's chart still
    defaults LOCATION_LOOKUP_MODE to "permissive", so the sync HTTP /
    permissive path returns unchanged.

    Setting this true switches BOTH sides of the integration together, so
    they can never end up half-wired:

      (1) facility-layout's config.eventPublisher flips from the chart's
          "log" default (Postgres outbox only -- nothing ever reaches
          Kafka) to "kafka", and kafka.enabled=true so the chart renders
          KAFKA_BROKERS. Without this there is literally no
          warehouse.facility.events topic for anyone to consume.

      (2) inventory-storage gets LOCATION_LOOKUP_MODE=kafka via extraEnv.
          Its chart already sets kafka.enabled (it publishes its own
          integration events), so KAFKA_BROKERS is already present --
          but the consumer REQUIRES it, and inventory-storage's
          composition root fails startup loudly if it is missing rather
          than silently degrading.

    Ordering caveat, and the reason this is one flag rather than two: a
    fresh consumer replays the topic from its earliest offset, so it can
    only cache what has actually been PUBLISHED. facility-layout events
    that predate the publisher flip live only in that service's Postgres
    outbox and will never appear on the topic. On a cluster with existing
    layout data, re-register (or re-import) the layout after flipping this
    so the events are emitted -- an empty/partial cache is not a hard
    failure but a FAIL-OPEN one (every lookup reports Known=false and
    stows are waved through unclassified), which inventory-storage logs
    loudly at startup.

    Rollback is pure configuration: set this false and re-apply, and
    inventory-storage returns to its previous lookup mode. See
    inventory-storage's ADR 0013 for the full decision record.
  EOT
  type        = bool
  default     = true
}

variable "deploy_mcp_servers" {
  description = <<-EOT
    Whether to deploy each context's MCP server (fulfillment-execution,
    wes-work-planning, inventory-storage, workforce-management,
    facility-layout -- see terraform/mcp.tf) and wire their endpoints and
    read keys into warehouse-ops-agent.

    Default true since 2026-09-07: this is what makes warehouse-ops-agent's
    "MCP tools as actuators" real (its ADR 0004). false is the rollback:
    every chart's mcp.enabled falls back to its own default (false), the
    -mcp Deployments/Services/Secrets are removed, and the agent's
    *_MCP_ENDPOINT values go back to empty -- which its config treats as
    "skip this client", not a crash.
  EOT
  type        = bool
  default     = true
}
