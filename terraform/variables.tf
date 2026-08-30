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
    Host port mapped to the Kong HTTP NodePort. Defaults to 80 so the gateway
    is reachable at http://localhost/. Set this to e.g. 8000 if something else
    on your machine already owns port 80 — kind cluster creation fails with a
    bind error if the port is taken.
  EOT
  type        = number
  default     = 80
}

variable "kong_proxy_https_host_port" {
  description = "Host port mapped to the Kong HTTPS NodePort. Defaults to 443."
  type        = number
  default     = 443
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
