# ---------------------------------------------------------------------------
# Observability — OTel Collector -> Jaeger (traces) + Prometheus (metrics),
# with Grafana on top.
#
#   service pods --OTLP/gRPC 4317--> otel-collector --OTLP/gRPC--> jaeger
#                                          |
#                                          `--/metrics:8889--<scraped by> prometheus
#                                                                            ^
#                                                              grafana ------'
#                                                              grafana ------> jaeger
#
# The Collector is the only thing the applications know about. Everything
# behind it can be swapped (Tempo for Jaeger, a remote-write target for
# Prometheus) without touching a single service repo — that indirection is the
# whole point of putting a Collector in the middle rather than having each
# service speak Jaeger's protocol directly.
#
# Whole stack is gated on var.deploy_observability so
# `terraform apply -var=deploy_observability=false` stands up the platform and
# the services without it (Kong's traces endpoint in helm-values/_platform.yaml
# then points at a Collector that is not there, which Kong tolerates).
# ---------------------------------------------------------------------------

# Deliberately NOT labelled istio-injection=enabled. This namespace carries
# telemetry plumbing, not application traffic: a sidecar in front of the
# Collector would add a hop to every span export, and Prometheus scraping
# through a proxy that is itself being observed is a needless circularity.
# Istio's default PERMISSIVE mTLS means the meshed service pods can still send
# plaintext OTLP into this namespace without any extra configuration.
resource "kubernetes_namespace" "observability" {
  count = var.deploy_observability ? 1 : 0


  metadata {
    name = var.observability_namespace
    labels = {
      "warehouse.local/tier" = "observability"
    }
  }
}

# ---------------------------------------------------------------------------
# Jaeger — traces backend + UI.
#
# Chart `jaegertracing/jaeger` from https://jaegertracing.github.io/helm-charts
# (the canonical repo published from github.com/jaegertracing/helm-charts).
#
# Chart 4.x installs Jaeger v2, which is itself an OpenTelemetry Collector
# distribution: one Deployment, one Service, in-memory storage by default, and
# a native OTLP receiver on 4317/4318. That is exactly the all-in-one shape a
# local kind cluster wants — the same "real but proportionate" call the
# Postgres release makes by running one instance with four logical databases
# instead of four clusters.
#
# In-memory storage means traces are lost when the pod restarts. That is
# correct here and wrong anywhere else; an Elasticsearch or Cassandra backend
# would triple the pod count of this cluster to buy durability nobody wants on
# a laptop.
# ---------------------------------------------------------------------------

resource "helm_release" "jaeger" {
  count = var.deploy_observability ? 1 : 0

  depends_on = [kubernetes_namespace.observability]

  name       = local.jaeger_release
  repository = "https://jaegertracing.github.io/helm-charts"
  chart      = "jaeger"
  version    = var.jaeger_chart_version
  namespace  = var.observability_namespace

  timeout = 600
  wait    = true

  values = [yamlencode({
    # No `storage:` block and no `userconfig:` override: with neither set the
    # chart runs the image's built-in all-in-one config, which is memory
    # storage. The chart's top-level `storage.type` only feeds the
    # Elasticsearch/Cassandra maintenance CronJobs, all of which are disabled.
    jaeger = {
      enabled  = true
      replicas = 1

      resources = {
        requests = { cpu = "100m", memory = "256Mi" }
        limits   = { cpu = "1000m", memory = "1Gi" }
      }
    }

    spark          = { enabled = false }
    esIndexCleaner = { enabled = false }
    esRollover     = { enabled = false }
    esLookback     = { enabled = false }
  })]
}

# ---------------------------------------------------------------------------
# Prometheus — metrics backend.
#
# Chart `prometheus-community/prometheus`: the plain server, NOT
# kube-prometheus-stack. That choice decides how scraping is configured:
#
#   * kube-prometheus-stack ships the Prometheus Operator and its CRDs, so you
#     would point Prometheus at the Collector with a `ServiceMonitor`.
#   * this chart ships no Operator and no CRDs, so a ServiceMonitor would be an
#     object nothing in the cluster watches — it would apply cleanly and do
#     nothing at all.
#
# So the Collector is added as a plain `scrape_configs` job below. It is fewer
# moving parts (one Deployment vs. an Operator plus CRDs plus an admission
# webhook) and it is the only one of the two that actually works with the chart
# installed here.
#
# Subcharts node-exporter and pushgateway are off. This Prometheus exists to
# hold application metrics coming through the Collector; a node-exporter
# DaemonSet with hostPath mounts on a two-node kind cluster is cost without
# benefit here.
#
# Alertmanager is ON (gap SLO-1): ONE replica, no PVC (emptyDir; silences on
# a disposable kind cluster are not worth a volume), requests 10m / 32Mi.
# Its config has a route whose default receiver is `null`, a receiver with
# no integrations. The honest statement: a local cluster has no pager, so
# NOTHING IS DELIVERED ANYWHERE. What Alertmanager adds is grouping
# (group_by alertname, context, service), inhibition (a severity="critical"
# alert silences the severity="warning" alerts of the same context and
# service), silences, and the /api/v2/alerts view; a real receiver is added
# here when one exists. Prometheus finds it with no extra setting: the chart
# renders prometheus.yml's `alerting.alertmanagers` (pod discovery of the
# release's alertmanager pods on port 9093) whenever alertmanager.enabled is
# true (verified with `helm template` of chart 29.27.0, subchart
# alertmanager 1.42.0 / v0.34.0). Keys live under the top-level
# `alertmanager` key: replicaCount, persistence.enabled, resources, config.
#
# kube-state-metrics is ON (gap fix D30), limited to the pods and
# deployments collectors: it is the only source of
# kube_pod_container_status_restarts_total, which the WarehousePodRestarting
# rules below need (cAdvisor has no restart counter). Its Service carries
# prometheus.io/scrape, so the chart's built-in kubernetes-service-endpoints
# job scrapes it with no extra scrape config.
#
# Alert rules (gap fix D30): serverFiles."alerting_rules.yml", the plain
# chart's rule mechanism (already listed in its default rule_files; there is
# no PrometheusRule CRD without the Operator). The rules are GENERATED into
# terraform/alerting/warehouse-alert-rules.json by
# scripts/gen-context-dashboards.py from the same per-context table as the
# dashboards, checked by `make alert-rules-check` (promtool check + unit
# tests). Every rule names its context's runbook in annotations.runbook_url.
# Besides the coarse per-route and per-pod rules, every context has four SLO
# burn-rate rules (gaps SLO-1/SLO-2, group warehouse-<key>-slo): API
# availability (99% of requests not 5xx per day) and API latency (95% of
# requests under 500 ms per day), each as a fast (critical) and a slow
# (warning) alert. Every SLO window is ONE DAY because retention is 24h.
# Without a pager they surface in Alertmanager's /api/v2/alerts, Prometheus'
# /alerts page, the ALERTS series and Grafana; nothing pages anyone.
# ---------------------------------------------------------------------------

resource "helm_release" "prometheus" {
  count = var.deploy_observability ? 1 : 0

  depends_on = [kubernetes_namespace.observability]

  name       = local.prometheus_release
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "prometheus"
  version    = var.prometheus_chart_version
  namespace  = var.observability_namespace

  timeout = 600
  wait    = true

  values = [yamlencode({
    alertmanager = {
      enabled      = true
      replicaCount = 1
      persistence  = { enabled = false }
      resources = {
        requests = { cpu = "10m", memory = "32Mi" }
        limits   = { cpu = "100m", memory = "64Mi" }
      }
      config = {
        route = {
          receiver = "null"
          group_by = ["alertname", "context", "service"]
        }
        # `null` has no integrations: nothing is delivered (see the header).
        receivers = [{ name = "null" }]
        inhibit_rules = [{
          source_matchers = ["severity=\"critical\""]
          target_matchers = ["severity=\"warning\""]
          equal           = ["context", "service"]
        }]
      }
    }
    "kube-state-metrics" = {
      enabled    = true
      collectors = ["pods", "deployments"]
      resources = {
        requests = { cpu = "10m", memory = "32Mi" }
        limits   = { cpu = "200m", memory = "128Mi" }
      }
    }
    "prometheus-node-exporter" = { enabled = false }
    "prometheus-pushgateway"   = { enabled = false }

    serverFiles = {
      "alerting_rules.yml" = jsondecode(file("${path.module}/../alerting/warehouse-alert-rules.json"))
    }

    server = {
      # Serve on 9090 rather than the chart's default 80, so the port-forward
      # in the README is the plain `9090:9090` everyone expects.
      service = {
        type        = "ClusterIP"
        servicePort = local.prometheus_port
      }

      # emptyDir, for the same reason Postgres uses one (see postgres.tf):
      # this is a disposable laptop cluster and a PVC only buys the ability to
      # carry stale state across a re-apply.
      persistentVolume = {
        enabled = false
      }

      retention = "24h"

      resources = {
        requests = { cpu = "100m", memory = "256Mi" }
        limits   = { cpu = "1000m", memory = "1Gi" }
      }
    }

    # Merged into the chart's built-in jobs (Kubernetes SD for apiservers,
    # nodes, cAdvisor and annotated pods), which are left on — they need no
    # extra components and give the cluster itself some visibility.
    scrapeConfigs = {
      # The application metrics: everything the five services push over OTLP,
      # re-exposed by the Collector's `prometheus` exporter.
      "otel-collector" = {
        enabled         = true
        scrape_interval = "15s"
        static_configs = [{
          targets = ["${local.observability_dns.otel_collector}:${local.otel_prometheus_exporter_port}"]
        }]
      }

      # The Collector's own health: accepted/refused spans, queue size, export
      # failures. This is what tells you whether a missing trace was dropped by
      # the pipeline or never sent by the service.
      "otel-collector-internal" = {
        enabled         = true
        scrape_interval = "15s"
        static_configs = [{
          targets = ["${local.observability_dns.otel_collector}:${local.otel_internal_metrics_port}"]
        }]
      }

      # No explicit job for Jaeger: it is itself a collector distribution and
      # its chart already sets prometheus.io/scrape + prometheus.io/port=8888
      # on the pod, so the chart's built-in `kubernetes-pods` job picks it up.
      # Adding one here just scrapes the same endpoint twice under two job
      # names.
    }
  })]
}

# ---------------------------------------------------------------------------
# Grafana — dashboards, with the datasources (Prometheus, Jaeger,
# Alertmanager, Loki) pre-provisioned from values.
#
# Provisioning them here rather than clicking through the UI keeps the whole
# environment reproducible from a clean `terraform apply`, which is the same
# rule the Postgres databases follow.
#
# The Prometheus datasource carries an `exemplarTraceIdDestinations` entry
# pointing at the Jaeger datasource's uid: when a service exports exemplars,
# a trace ID on a metric becomes a click-through into the trace. That is why
# both datasources get explicit, stable `uid`s instead of generated ones.
# ---------------------------------------------------------------------------

resource "helm_release" "grafana" {
  count = var.deploy_observability ? 1 : 0

  depends_on = [
    helm_release.prometheus,
    helm_release.jaeger,
    helm_release.loki,
  ]

  name       = local.grafana_release
  repository = "https://grafana.github.io/helm-charts"
  chart      = "grafana"
  version    = var.grafana_chart_version
  namespace  = var.observability_namespace

  timeout = 600
  wait    = true

  values = [yamlencode({
    # Deterministic dev credentials, same rationale as the Postgres ones: the
    # README's commands stay copy-pasteable and a re-apply cannot rotate the
    # password out from under a running pod. LOCAL DEV ONLY.
    adminUser     = "admin"
    adminPassword = var.grafana_admin_password

    # Serve on 3000 rather than the chart's default 80 -> 3000, so the
    # port-forward is a plain `3000:3000`.
    service = {
      type       = "ClusterIP"
      port       = local.grafana_port
      targetPort = 3000
    }

    persistence = { enabled = false }

    resources = {
      requests = { cpu = "50m", memory = "128Mi" }
      limits   = { cpu = "500m", memory = "512Mi" }
    }

    datasources = {
      "datasources.yaml" = {
        apiVersion = 1
        datasources = concat([
          {
            name      = "Prometheus"
            uid       = "prometheus"
            type      = "prometheus"
            access    = "proxy"
            url       = "http://${local.observability_dns.prometheus}:${local.prometheus_port}"
            isDefault = true
            jsonData = {
              httpMethod = "POST"
              # Trace IDs attached to metrics as exemplars become links into
              # the Jaeger datasource below.
              exemplarTraceIdDestinations = [{
                name          = "trace_id"
                datasourceUid = "jaeger"
              }]
            }
          },
          {
            name   = "Jaeger"
            uid    = "jaeger"
            type   = "jaeger"
            access = "proxy"
            url    = "http://${local.observability_dns.jaeger}:${local.jaeger_query_port}"
          },
          # Alertmanager (the chart's alertmanager subchart, Service
          # <release>-alertmanager:9093): the Alerting UI lists its alerts and
          # silences. Same shape as the datasources above.
          {
            name     = "Alertmanager"
            uid      = "alertmanager"
            type     = "alertmanager"
            access   = "proxy"
            url      = "http://${local.prometheus_release}-alertmanager.${var.observability_namespace}.svc.cluster.local:9093"
            jsonData = { implementation = "prometheus" }
          },
          ],
          # Loki (logging.tf). Conditional because deploy_logging can be
          # false while deploy_observability stays true -- a datasource
          # pointing at a Service that was never installed would leave
          # Grafana showing a permanently-red datasource health check.
          var.deploy_logging ? [{
            name   = "Loki"
            uid    = "loki"
            type   = "loki"
            access = "proxy"
            url    = "http://loki.${var.observability_namespace}.svc.cluster.local:3100"
            jsonData = {
              # Every service's slog output already carries the active
              # trace/span ID (telemetry.WithTraceContext) as a field in the
              # JSON body; Loki's derived-fields regex below pulls it out of
              # the raw log line and turns it into a click-through to the
              # matching Jaeger trace, so "found a suspicious log line" and
              # "found a slow trace" land in the same UI either direction.
              derivedFields = [{
                datasourceUid = "jaeger"
                matcherRegex  = "\"trace_id\":\"([a-f0-9]+)\""
                name          = "trace_id"
                url           = "$${__value.raw}"
              }]
            }
          }] : []
        )
      }
    }


    # Dashboards, provisioned from the same values so the install is never an
    # empty Grafana and the whole environment stays reproducible from a clean
    # `terraform apply` (same rule the Postgres databases and Kong's CORS/
    # Prometheus plugins follow). Four groups, all file-provisioned (no
    # click-ops dashboard survives a re-apply):
    #   - go-runtime: the original fleet-wide Go runtime + collector
    #     throughput dashboard (go.opentelemetry.io/contrib/instrumentation/
    #     runtime metrics, arriving over OTLP and re-exported by the
    #     Collector).
    #   - kong-gateway-overview: the API Gateway view -- Kong's own
    #     `prometheus` plugin metrics (kong-prometheus.tf), fleet-wide,
    #     broken down per bounded context's Kong Service.
    #   - logs-overview: fleet-wide Loki view -- cross-context error/warning
    #     triage and log-volume-by-context, backed by logging.tf's Alloy
    #     pipeline.
    #   - contexts/<name>: one dashboard PER bounded context (generated by
    #     scripts/gen-context-dashboards.py), each showing that context's
    #     slice of the Kong view (its API, MCP and reports routes -- the ONLY
    #     5xx source, since otelchi records no status code), its own HTTP
    #     RED (ADR-0009), its Tier-2 business counter(s), its outbox lag
    #     where the context exports a gauge, its Go runtime, and its own
    #     Loki logs. scripts/test_gen_context_dashboards.py (CI
    #     observability-as-code) keeps the JSON equal to the generator.
    dashboardProviders = {
      "dashboardproviders.yaml" = {
        apiVersion = 1
        providers = [{
          name            = "warehouse"
          orgId           = 1
          folder          = "warehouse"
          type            = "file"
          disableDeletion = false
          editable        = true
          options         = { path = "/var/lib/grafana/dashboards/warehouse" }
        }]
      }
    }

    dashboards = {
      warehouse = merge(
        {
          "go-runtime" = {
            json = file("${path.module}/../dashboards/go-runtime.json")
          }
          # Fleet-wide API Gateway view (kong-prometheus.tf's `prometheus`
          # KongClusterPlugin is what makes this data exist at all): request
          # rate/errors/latency/bandwidth PER BOUNDED CONTEXT as seen at the
          # single north-south edge every context's traffic passes through,
          # before any per-service dashboard's own view of the same request.
          "kong-gateway-overview" = {
            json = file("${path.module}/../dashboards/kong-gateway-overview.json")
          }
          # Fleet-wide Logs view (Loki, via logging.tf's Alloy pipeline):
          # cross-context error/warning triage in one screen, so "is
          # anything failing right now" never requires opening all 8
          # per-context dashboards one at a time.
          "logs-overview" = {
            json = file("${path.module}/../dashboards/logs-overview.json")
          }
        },
        # One dashboard per bounded context (terraform/dashboards/contexts/),
        # generated by scripts/gen-context-dashboards.py -- see that file's
        # header before hand-editing any of these JSON files directly. Each
        # follows the same four-row shape: this context's slice of the Kong
        # gateway view, its own HTTP RED (otelchi, ADR-0009), its Tier-2
        # business metric(s), and its Go runtime -- one screen per context
        # that answers "is this bounded context healthy" without cross-
        # referencing the fleet-wide dashboards above.
        {
          for f in fileset("${path.module}/../dashboards/contexts", "*.json") :
          trimsuffix(f, ".json") => {
            json = file("${path.module}/../dashboards/contexts/${f}")
          }
        }
      )
    }
  })]
}

# ---------------------------------------------------------------------------
# OTel Collector — the centre of all of this.
#
# Chart `open-telemetry/opentelemetry-collector`, mode=deployment. The image is
# the CONTRIB distribution, and that is load bearing: the `prometheus`
# EXPORTER (the one that opens a /metrics endpoint for Prometheus to scrape)
# does not exist in the core `otel/opentelemetry-collector` image. Contrib is
# already the chart's default — verified by rendering the chart rather than
# assumed — but it is pinned explicitly so a chart bump cannot move us off it
# silently.
#
# fullnameOverride is what makes the Service resolve at exactly
# `otel-collector.observability.svc.cluster.local:4317` (the chart would
# otherwise name it <release>-opentelemetry-collector). That DNS name is a
# contract: the five service repos hard-code it in their own Helm values.
#
# Traces go to Jaeger with the `otlp` exporter, NOT the `jaeger` exporter
# component — that one was deprecated and removed from contrib, and it is
# unnecessary anyway: Jaeger has accepted OTLP natively since 1.35 and the
# Jaeger v2 image deployed above is an OTel Collector distribution with an
# `otlp` receiver on 4317.
#
# Metrics are PULLED, not pushed: the `prometheus` exporter aggregates what
# arrives over OTLP and republishes it on :8889 for Prometheus to scrape. A
# `prometheusremotewrite` exporter would have been the push alternative and
# would have needed the remote-write receiver enabled on the Prometheus side.
# ---------------------------------------------------------------------------

resource "helm_release" "otel_collector" {
  count = var.deploy_observability ? 1 : 0

  # Kong's traces endpoint in helm-values/_platform.yaml (ADR 0002 D2) must
  # name this Collector's OTLP/HTTP receiver.
  lifecycle {
    precondition {
      condition     = local.platform.kongPlugins.opentelemetry.tracesEndpoint == "http://${local.observability_dns.otel_collector}:${local.otel_otlp_http_port}/v1/traces"
      error_message = "helm-values/_platform.yaml kongPlugins.opentelemetry.tracesEndpoint must be http://${local.observability_dns.otel_collector}:${local.otel_otlp_http_port}/v1/traces."
    }
  }

  # Jaeger first: the Collector's exporter needs somewhere to send to. It would
  # start regardless (the exporter retries), but a clean apply should not spend
  # its first minute logging connection refused.
  depends_on = [helm_release.jaeger]

  name       = local.otel_collector_release
  repository = "https://open-telemetry.github.io/opentelemetry-helm-charts"
  chart      = "opentelemetry-collector"
  version    = var.otel_collector_chart_version
  namespace  = var.observability_namespace

  timeout = 600
  wait    = true

  values = [yamlencode({
    mode             = "deployment"
    fullnameOverride = local.otel_collector_release
    replicaCount     = 1

    image = {
      repository = "otel/opentelemetry-collector-contrib"
    }

    resources = {
      requests = { cpu = "100m", memory = "128Mi" }
      limits   = { cpu = "1000m", memory = "512Mi" }
    }

    # Trim the Service down to what is actually used. The chart enables Jaeger's
    # own legacy receiver ports and Zipkin by default; the services speak OTLP
    # and nothing else, and every extra port here is also a hostPort on the kind
    # node.
    ports = {
      otlp = {
        enabled       = true
        containerPort = local.otel_otlp_grpc_port
        servicePort   = local.otel_otlp_grpc_port
        protocol      = "TCP"
        appProtocol   = "grpc"
      }
      "otlp-http" = {
        enabled       = true
        containerPort = local.otel_otlp_http_port
        servicePort   = local.otel_otlp_http_port
        protocol      = "TCP"
      }
      "jaeger-compact" = { enabled = false }
      "jaeger-thrift"  = { enabled = false }
      "jaeger-grpc"    = { enabled = false }
      zipkin           = { enabled = false }

      # Off by default in the chart; Prometheus needs it on the Service to
      # scrape the collector's own telemetry.
      metrics = {
        enabled       = true
        containerPort = local.otel_internal_metrics_port
        servicePort   = local.otel_internal_metrics_port
        protocol      = "TCP"
      }

      # The `prometheus` exporter's scrape endpoint. Not a chart default; added
      # here so the exporter is reachable through the Service.
      prometheus = {
        enabled       = true
        containerPort = local.otel_prometheus_exporter_port
        servicePort   = local.otel_prometheus_exporter_port
        protocol      = "TCP"
      }
    }

    # The chart DEEP-MERGES this over its own default config, so components are
    # removed by setting them to null rather than by omission. Everything nulled
    # below is a chart default we do not use; leaving them declared-but-unwired
    # would be dead config in the rendered ConfigMap.
    config = {
      receivers = {
        # Bind the OTLP listeners on 0.0.0.0 rather than the chart's default
        # ${env:MY_POD_IP}. Not cosmetic: `kubectl port-forward` connects to
        # localhost INSIDE the pod's network namespace, so a listener bound
        # only to the pod IP refuses the connection —
        # `failed to connect to localhost:4317 inside namespace ...` — and you
        # cannot send OTLP from the host at all. In-cluster traffic is
        # unaffected either way.
        otlp = {
          protocols = {
            grpc = { endpoint = "0.0.0.0:${local.otel_otlp_grpc_port}" }
            http = { endpoint = "0.0.0.0:${local.otel_otlp_http_port}" }
          }
        }

        jaeger = null
        zipkin = null
        # The chart's default scrape of the collector's own :8888. Prometheus
        # scrapes that endpoint directly instead (see the prometheus release
        # above), so routing it back through the collector is a needless loop.
        prometheus = null
      }

      processors = {
        memory_limiter = null
      }

      exporters = {
        debug = null

        # Collector 0.158 logs `"otlp" alias is deprecated; use "otlp_grpc"`
        # on startup. `otlp` still works and is the name every service repo and
        # every piece of documentation uses today; rename this to
        # `otlp_grpc/jaeger` when the alias is actually removed, not before —
        # `otlp_grpc` does not exist in older collector images.
        "otlp/jaeger" = {
          endpoint = "${local.observability_dns.jaeger}:${local.jaeger_otlp_port}"
          # No TLS inside the cluster, and this namespace is outside the mesh,
          # so there is no sidecar to originate it either.
          tls = { insecure = true }
        }

        prometheus = {
          # 0.0.0.0, not ${env:MY_POD_IP}: this has to answer on the pod IP for
          # Prometheus to reach it through the Service.
          endpoint = "0.0.0.0:${local.otel_prometheus_exporter_port}"
          # Turns OTel resource attributes (service.name, service.version, ...)
          # into Prometheus labels, so a metric can be filtered by which
          # bounded context produced it.
          resource_to_telemetry_conversion = { enabled = true }
        }
      }

      service = {
        # Same pod-IP-vs-localhost problem as the OTLP receivers above: the
        # chart binds the collector's own /metrics reader to ${env:MY_POD_IP},
        # which Prometheus can scrape through the Service but which
        # `kubectl port-forward -n observability svc/otel-collector 8888:8888`
        # cannot reach. 0.0.0.0 makes both work.
        telemetry = {
          metrics = {
            readers = [{
              pull = {
                exporter = {
                  prometheus = {
                    host = "0.0.0.0"
                    port = local.otel_internal_metrics_port
                  }
                }
              }
            }]
          }
        }

        pipelines = {
          traces = {
            receivers  = ["otlp"]
            processors = ["batch"]
            exporters  = ["otlp/jaeger"]
          }
          metrics = {
            receivers  = ["otlp"]
            processors = ["batch"]
            exporters  = ["prometheus"]
          }
          # No logs backend in this stack. Declaring an empty logs pipeline
          # would fail validation; dropping it is the honest thing.
          logs = null
        }
      }
    }
  })]
}
