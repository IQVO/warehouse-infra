# ---------------------------------------------------------------------------
# The four bounded contexts, in one place.
#
# `chart_path` deliberately points OUTSIDE warehouse-infra, at the Helm chart
# that already lives in each service's own repo. warehouse-infra owns the
# ENVIRONMENT (which cluster, which database URL, which Kong route); each
# service repo owns the SHAPE of its own workload. See README.md
# "Where the manifests live" for the full rationale.
#
# `port` was read from each service's cmd/*/main.go: all four default
# HTTP_ADDR to ":8080" and the Dockerfiles all EXPOSE 8080.
# ---------------------------------------------------------------------------

locals {
  postgres_release_name = "postgres"
  postgres_host         = "${local.postgres_release_name}-postgresql.${var.data_namespace}.svc.cluster.local"
  postgres_port         = 5432

  services = {
    "inventory-storage" = {
      db         = "inventory_storage"
      user       = "inventory_storage"
      port       = 8080
      path       = "/inventory-storage"
      chart_path = "${path.module}/../../inventory-storage/charts/inventory-storage"
    }
    "wes-work-planning" = {
      db         = "wes_work_planning"
      user       = "wes_work_planning"
      port       = 8080
      path       = "/wes-work-planning"
      chart_path = "${path.module}/../../wes-work-planning/charts/wes-work-planning"
    }
    "workforce-management" = {
      db         = "workforce_management"
      user       = "workforce_management"
      port       = 8080
      path       = "/workforce-management"
      chart_path = "${path.module}/../../workforce-management/charts/workforce-management"
    }
    "fulfillment-execution" = {
      db         = "fulfillment_execution"
      user       = "fulfillment_execution"
      port       = 8080
      path       = "/fulfillment-execution"
      chart_path = "${path.module}/../../fulfillment-execution/charts/fulfillment-execution"
    }
    "order-management" = {
      db         = "order_management"
      user       = "order_management"
      port       = 8080
      path       = "/order-management"
      chart_path = "${path.module}/../../order-management/charts/order-management"
    }
    "facility-layout" = {
      db         = "facility_layout"
      user       = "facility_layout"
      port       = 8080
      path       = "/facility-layout"
      chart_path = "${path.module}/../../facility-layout/charts/facility-layout"
    }
    "labor-performance" = {
      db         = "labor_performance"
      user       = "labor_performance"
      port       = 8080
      path       = "/labor-performance"
      chart_path = "${path.module}/../../labor-performance/charts/labor-performance"
    }
  }

  # Per-service database passwords are GENERATED, never committed. Each service
  # gets a random 24-char password (see random_password.service_db in
  # postgres.tf); the value lives only in Terraform state, which is gitignored.
  # This keeps credentials out of version control so the repo is safe to publish.
  service_passwords = {
    for name in keys(local.services) :
    name => random_password.service_db[name].result
  }

  # sslmode=disable: the Postgres release runs without TLS inside the cluster.
  # Traffic between service pods and Postgres is not meshed either (Postgres
  # lives in an un-injected namespace), which is fine for a laptop.
  #
  # This map holds the REAL connection string each service receives (services.tf
  # feeds it into the chart's DATABASE_URL Secret), so it must carry the same
  # generated password the initdb script set on the role. It is exposed only
  # through the `database_urls` output, which is marked sensitive.
  database_urls = {
    for name, svc in local.services :
    name => "postgres://${svc.user}:${local.service_passwords[name]}@${local.postgres_host}:${local.postgres_port}/${svc.db}?sslmode=disable"
  }

  # ---------------------------------------------------------------------
  # Analytics data-mesh (ADR-0010 in each service repo): the "report part"
  # (cmd/<svc>-projector, cmd/<svc>-reports) alongside the six services
  # whose charts ship the projector-deployment.yaml/reports-deployment.yaml/
  # analytics-secret.yaml templates. labor-performance is deliberately
  # excluded — it is a pure Kafka consumer with no analytics chart of its
  # own (see warehouse-systems-fleet-ops skill's kubernetes-deployment.md
  # audit note); warehouse-ops-agent (not in local.services at all — see
  # ops-agent.tf) has no database, so it never had an analytics chart
  # either.
  #
  # fulfillment-execution WAS temporarily excluded here (its Dockerfile
  # never built/copied the projector/reports binaries its own chart
  # references, a real deploy gap that would CrashLoopBackOff both pods).
  # That fix merged 2026-08-30: https://github.com/claudioed/
  # fulfillment-execution/pull/47. Re-included in the set below, but the
  # NEXT `terraform apply` must not run until REPOS_ROOT/
  # fulfillment-execution (what build-and-load.sh actually builds from)
  # is clean -- it currently has unrelated uncommitted work on
  # feature/gift-wrap-handling-flag that would otherwise get baked into
  # the live image.
  #
  # Baseline per docs/analytics/governance-charter.md: a dedicated
  # `<svc>_analytics` database in the SAME Postgres release, owned by a
  # single generated role. The chart's own `analytics.database.reportsUrl`
  # falls back to `projectorUrl` when left empty (see each chart's
  # values.yaml comment) — matching the "local/dev" baseline the charts
  # already document, same posture as this file's single-role OLTP
  # database_urls above (no separate read-only role there either). The
  # promotion path to a distinct read-only reports role / a physically
  # separate instance is a later, additive change (see the governance
  # charter), not required to bring analytics live today.
  analytics_services = toset([
    "wes-work-planning",
    "fulfillment-execution",
    "order-management",
    "inventory-storage",
    "workforce-management",
    "facility-layout",
  ])

  analytics_db_info = {
    for name in local.analytics_services :
    name => {
      db   = "${local.services[name].db}_analytics"
      user = "${local.services[name].user}_analytics"
    }
  }

  analytics_service_passwords = {
    for name in local.analytics_services :
    name => random_password.service_analytics_db[name].result
  }

  analytics_database_urls = {
    for name in local.analytics_services :
    name => "postgres://${local.analytics_db_info[name].user}:${local.analytics_service_passwords[name]}@${local.postgres_host}:${local.postgres_port}/${local.analytics_db_info[name].db}?sslmode=disable"
  }
}

# ---------------------------------------------------------------------------
# Observability endpoints.
#
# Names, not guesses: `otel_collector_release` is fed to the chart's
# fullnameOverride, so the Service is called exactly `otel-collector` and
# `otel_collector_endpoint` is the DNS name the five services' OTLP exporters
# are pointed at. The Jaeger v2 chart deploys ONE all-in-one Service named
# after the release (there is no separate jaeger-query Service as in the v1
# chart), which carries both OTLP 4317 and the query UI on 16686.
# ---------------------------------------------------------------------------

locals {
  otel_collector_release = "otel-collector"
  jaeger_release         = "jaeger"
  prometheus_release     = "prometheus"
  grafana_release        = "grafana"

  otel_otlp_grpc_port = 4317
  otel_otlp_http_port = 4318
  # The collector's `prometheus` exporter listens here; Prometheus scrapes it.
  otel_prometheus_exporter_port = 8889
  # The collector's own internal telemetry (queue depth, refused spans, ...).
  otel_internal_metrics_port = 8888

  jaeger_otlp_port  = 4317
  jaeger_query_port = 16686
  prometheus_port   = 9090
  grafana_port      = 3000

  observability_dns = {
    otel_collector = "${local.otel_collector_release}.${var.observability_namespace}.svc.cluster.local"
    jaeger         = "${local.jaeger_release}.${var.observability_namespace}.svc.cluster.local"
    prometheus     = "${local.prometheus_release}-server.${var.observability_namespace}.svc.cluster.local"
    grafana        = "${local.grafana_release}.${var.observability_namespace}.svc.cluster.local"
  }

  # THE endpoint. Every service's Helm values gets pointed here (in its own
  # repo — warehouse-infra does not edit service charts).
  otlp_grpc_endpoint = "${local.observability_dns.otel_collector}:${local.otel_otlp_grpc_port}"
}
