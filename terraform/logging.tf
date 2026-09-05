# ---------------------------------------------------------------------------
# Loki + Alloy — log aggregation.
#
#   app pod stdout (JSON via slog) --tailed by Alloy DaemonSet--> Loki (single
#   binary, filesystem storage) <--queried by--> Grafana ("Loki" datasource)
#
# Before this existed, the stack's OTel Collector had NO logs pipeline at
# all: observability.tf's `logs = null` says so explicitly ("Declaring an
# empty logs pipeline would fail validation; dropping it is the honest
# thing."). Every service already writes structured JSON to stdout via
# log/slog (see e.g. inventory-storage/LOGGING.md), and every log line is
# already trace-correlated (`telemetry.WithTraceContext` stamps the active
# trace/span ID into each record) — but the ONLY way to read any of it was
# `kubectl logs <pod>`: no cross-service search, no retention past whatever
# the container runtime keeps, nothing survives a pod restart.
#
# This is deliberately NOT routed through the OTel Collector. Two real
# options existed:
#   1. Point slog handlers at an OTLP log exporter, add a `logs` pipeline to
#      the Collector, export to Loki's OTLP endpoint.
#   2. Tail container stdout directly with a node-level agent (Alloy) and
#      push straight to Loki's push API.
# (2) is what ships here: it needs zero application code changes (every
# service already writes JSON to stdout, which is exactly what a log-tailing
# agent wants), and correlating a log line to its trace still works because
# the trace/span ID is already IN the JSON body as a field — Loki doesn't
# need to understand OTLP to preserve that. (1) stays available later if a
# service ever wants to emit a log OTLP can see that never touches stdout
# (rare), without having to undo this.
#
# Loki runs SingleBinary mode (one StatefulSet, `filesystem` chunk storage,
# no S3/GCS/Azure, no Memcached result/chunk caches, no Loki Canary, no
# built-in Minio) — the same "real but proportionate" call this module
# already makes for Postgres (one instance, several logical databases) and
# Jaeger (in-memory, no Elasticsearch/Cassandra). SimpleScalable or
# microservices mode would buy horizontal scale nobody needs on a laptop
# kind cluster at the cost of running 6+ extra Deployments.
# ---------------------------------------------------------------------------

resource "helm_release" "loki" {
  count = var.deploy_observability && var.deploy_logging ? 1 : 0

  depends_on = [kubernetes_namespace.observability]

  name       = local.loki_release
  repository = "https://grafana.github.io/helm-charts"
  chart      = "loki"
  version    = var.loki_chart_version
  namespace  = var.observability_namespace

  timeout = 600
  wait    = true

  values = [yamlencode({
    deploymentMode = "SingleBinary"

    loki = {
      # No multi-tenant auth: this is a single-tenant laptop cluster, same
      # posture as Postgres/Kafka having no TLS/SASL inside the mesh.
      auth_enabled = false

      commonConfig = {
        # Single Loki instance -- a replication factor above 1 would just
        # make ingestion wait on replicas that will never exist.
        replication_factor = 1
      }

      storage = {
        type = "filesystem"
      }

      # A real Loki install requires an explicit schemaConfig (the chart's
      # own values.yaml says so); `tsdb` is the current recommended index
      # type, replacing the older boltdb-shipper.
      schemaConfig = {
        configs = [{
          from         = "2024-01-01"
          store        = "tsdb"
          object_store = "filesystem"
          schema       = "v13"
          index = {
            prefix = "index_"
            period = "24h"
          }
        }]
      }

      # Same retention posture as Prometheus's 24h (see observability.tf):
      # this is a disposable dev cluster, not a compliance archive.
      limits_config = {
        retention_period = var.loki_retention_period
      }

      compactor = {
        retention_enabled      = true
        compaction_interval    = "10m"
        retention_delete_delay = "2h"
        # Newer Loki refuses to start with retention_enabled and no
        # delete-request store configured ("CONFIG ERROR: invalid
        # compactor config: compactor.delete-request-store should be
        # configured when retention is enabled") -- verified against the
        # real container, not the chart's values.yaml comments, which
        # don't mention this requirement. filesystem matches
        # loki.storage.type above; there is no second store to stand up.
        delete_request_store = "filesystem"
      }
    }

    singleBinary = {
      replicas = 1
      # emptyDir, matching every other "disposable laptop cluster" storage
      # decision in this module (Postgres, Prometheus, Jaeger). Unlike
      # those charts, this one does NOT fall back to an emptyDir when
      # persistence is disabled -- it simply mounts nothing at /var/loki,
      # so Loki crashes with "mkdir /var/loki: read-only file system"
      # (verified against the real container's crash log, not assumed).
      # extraVolumes/extraVolumeMounts below supply the emptyDir the chart
      # itself only wires up via a PVC.
      persistence = {
        enabled = false
      }
      extraVolumes = [{
        name     = "storage"
        emptyDir = {}
      }]
      extraVolumeMounts = [{
        name      = "storage"
        mountPath = "/var/loki"
      }]
    }

    # SingleBinary mode runs everything in that one StatefulSet; the
    # SimpleScalable read/write/backend components must be explicitly
    # zeroed or the chart still renders them.
    read    = { replicas = 0 }
    write   = { replicas = 0 }
    backend = { replicas = 0 }

    # No nginx/gateway in front -- Alloy and Grafana both reach the Loki
    # Service directly, same as every other in-cluster backend here.
    gateway = { enabled = false }

    # Memcached-backed caches exist for multi-replica/high-QPS Loki; a
    # single-binary laptop instance gets nothing from them but two more
    # pods.
    chunksCache  = { enabled = false }
    resultsCache = { enabled = false }

    # The canary DaemonSet writes synthetic log lines to prove end-to-end
    # ingestion continuously -- useful for a production SLO, noise here.
    lokiCanary = { enabled = false }

    test = { enabled = false }

    monitoring = {
      selfMonitoring = { enabled = false }
      serviceMonitor = { enabled = false }
    }

    minio = { enabled = false }

    sidecar = {
      rules = { enabled = false }
    }
  })]
}

# ---------------------------------------------------------------------------
# Alloy — the log-tailing agent. One DaemonSet pod per node, each reading
# only the containers on its own node via the container runtime's log
# files (the chart mounts /var/log and the pod-log symlink tree), so this
# does not add a single extra network hop for the services themselves.
#
# Alloy is Grafana Labs' current agent; Promtail (the older log-only agent)
# is in long-term support only and does not receive new features. Alloy's
# own chart repo already lives alongside Loki's (both `grafana/*`), so this
# adds no new Helm repository.
# ---------------------------------------------------------------------------

resource "helm_release" "alloy" {
  count = var.deploy_observability && var.deploy_logging ? 1 : 0

  depends_on = [helm_release.loki]

  name       = local.alloy_release
  repository = "https://grafana.github.io/helm-charts"
  chart      = "alloy"
  version    = var.alloy_chart_version
  namespace  = var.observability_namespace

  timeout = 300
  wait    = true

  values = [yamlencode({
    alloy = {
      configMap = {
        create  = true
        content = local.alloy_config
      }
    }

    controller = {
      type = "daemonset"
    }
  })]
}

# The Alloy pipeline: discover every pod on this node, label its log stream
# with namespace/pod/container/app, forward to Loki's push API. `app` reads
# `app.kubernetes.io/name`, which every Helm chart in this fleet already
# sets (it is how `kubectl get pods -l app.kubernetes.io/name=<service>`
# already works) -- reusing it means Grafana's Loki queries and its existing
# label vocabulary agree without inventing a second name for the same thing.
locals {
  loki_release  = "loki"
  alloy_release = "alloy"

  alloy_config = <<-EOT
    logging {
      level  = "info"
      format = "logfmt"
    }

    discovery.kubernetes "pods" {
      role = "pod"
    }

    discovery.relabel "pods" {
      targets = discovery.kubernetes.pods.targets

      rule {
        source_labels = ["__meta_kubernetes_namespace"]
        target_label  = "namespace"
      }

      rule {
        source_labels = ["__meta_kubernetes_pod_name"]
        target_label  = "pod"
      }

      rule {
        source_labels = ["__meta_kubernetes_pod_container_name"]
        target_label  = "container"
      }

      rule {
        source_labels = ["__meta_kubernetes_pod_label_app_kubernetes_io_name"]
        target_label  = "app"
      }
    }

    loki.source.kubernetes "pods" {
      targets    = discovery.relabel.pods.output
      forward_to = [loki.process.pods.receiver]
    }

    loki.process "pods" {
      forward_to = [loki.write.default.receiver]

      // Every service here writes JSON via log/slog (see e.g.
      // inventory-storage/LOGGING.md): lift `level` out of the JSON body
      // into a real Loki label so "show me only ERROR" is a label filter,
      // not a per-line regex over every log in the cluster.
      stage.json {
        expressions = {
          level = "level",
        }
      }

      stage.labels {
        values = {
          level = "level",
        }
      }
    }

    loki.write "default" {
      endpoint {
        url = "http://${local.loki_release}.${var.observability_namespace}.svc.cluster.local:3100/loki/api/v1/push"
      }
    }
  EOT
}

# In-cluster Loki query address. Grafana's datasource (observability.tf)
# points here; nothing else in the fleet needs to know Loki exists.
output "loki_push_endpoint" {
  description = "In-cluster Loki push API endpoint, or empty if logging is disabled."
  value       = var.deploy_observability && var.deploy_logging ? "http://${local.loki_release}.${var.observability_namespace}.svc.cluster.local:3100" : ""
}
