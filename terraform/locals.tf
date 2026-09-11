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
    "process-path-management" = {
      db         = "process_path_management"
      user       = "process_path_management"
      port       = 8080
      path       = "/process-path-management"
      chart_path = "${path.module}/../../process-path-management/charts/process-path-management"
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
  # (cmd/<svc>-projector, cmd/<svc>-reports) alongside the seven services
  # whose charts ship the projector-deployment.yaml/reports-deployment.yaml/
  # analytics-secret.yaml templates. warehouse-ops-agent (not in
  # local.services at all — see ops-agent.tf) has no database, so it never
  # had an analytics chart either.
  #
  # labor-performance WAS excluded here (its chart shipped no
  # projector-deployment.yaml/reports-deployment.yaml/analytics-secret.yaml
  # at all, despite the OLTP-side analytics code landing in PR #9 — a real
  # deploy gap, not the CrashLoopBackOff kind fulfillment-execution hit,
  # but the same root cause: infra can't enable what the chart doesn't
  # ship). That gap closed via labor-performance's own
  # feature/analytics-chart-wiring PR, mirroring order-management's
  # ADR-0006 chart shape verbatim. Re-included in the set below.
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
    "labor-performance",
    # Added 2026-09-11 (fleet-wide bounded-context wiring plan, Phase 5):
    # process-path-management shipped its own analytics data product
    # (projector + reports binaries, warehouse.process-path-management.analytics
    # topic, "Process Path Catalogue Growth & Change" report bucketed by
    # day) in the same PR that closed this fleet's last remaining
    # analytics gap -- 8 of 8 backend contexts now have one. Every
    # downstream local (analytics_db_info, analytics_service_passwords,
    # analytics_database_urls) and the postgres.tf init-job template and
    # services.tf's `contains(local.analytics_services, each.key)` gate
    # already derive from this single set, so no other file needs a
    # change to pick this service up.
    "process-path-management",
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

  # ---------------------------------------------------------------------
  # Process-path catalogue (ADR-0017 in fulfillment-execution / ADR-0012 in
  # wes-work-planning / ADR-0013 in workforce-management): these three
  # services read a boot-time-required YAML file (PATH_CATALOGUE_FILE) that
  # declares the fleet's process paths and their required capabilities. It
  # is a PUBLISHED LANGUAGE owned by warehouse-infra (same reasoning as the
  # `services` map above: a fact about what exists in THIS deployment, not
  # business logic belonging to any one bounded context) -- read from disk
  # once here and fed identically into all three charts' pathCatalogue.content
  # so they can never disagree about what paths exist.
  #
  # SUPERSEDED AND FROZEN (cutover 2026-09-06; var.deploy_process_path_kafka_source
  # now defaults to true): the source of truth for process paths is
  # process-path-management (its own bounded context, in local.services
  # above), which publishes ProcessPathCreated/Updated/Deactivated onto
  # warehouse.process-path-management.events. Its store was seeded from
  # this file by scripts/seed-process-paths.py (idempotent, re-runnable).
  # Each of the three consumers ships a PATH_CATALOGUE_SOURCE=file|kafka
  # switch; with the flag true each consumer's pathCatalogue.enabled is
  # false (no file mount) and PATH_CATALOGUE_SOURCE=kafka is injected via
  # extraEnv (see services.tf), and process-path-management's own
  # config.eventPublisher is "kafka".
  #
  # DO NOT EDIT config/process-paths/sortable-fc.yaml to change the fleet's
  # paths any more -- define/revise them through process-path-management's
  # REST API. The file is kept ONLY as the rollback payload for
  # var.deploy_process_path_kafka_source=false. Deleting the file, this
  # block, and the consumers' filecatalog loaders is a follow-up once the
  # kafka source has soaked for a full cycle.
  # ---------------------------------------------------------------------------
  # Synchronous HTTP edges between contexts (the fleet's Customer/Supplier
  # REST calls). Every consumer binary defaults its *_MODE to "permissive"
  # (never reaches the network), which is the right default for a bare
  # `go run` -- but in THIS cluster every supplier is deployed, so leaving
  # the defaults in place silently degrades real behaviour:
  #
  #   - workforce-management INSTALLED_CAPACITY_MODE=permissive is fail-LOUD:
  #     every POST /shift-plans returned 503 (ADR-0014 there) -- found live
  #     on 2026-09-07 while verifying the outbox rollout.
  #   - wes-work-planning / fulfillment-execution
  #     PRODUCT_CLASSIFICATION_MODE=permissive is fail-open: WorkReleased
  #     never carries hazmat/fragile hints, so no station gating happens.
  #   - workforce-management LABOR_PERFORMANCE_MODE=permissive: ProposePathPlan
  #     always proposes 0 heads (no measured rate).
  #
  # order-management's inventory-storage edge was already wired (its
  # helm-values file); inventory-storage's facility-layout edge moved to
  # Kafka (var.deploy_facility_events_integration). This map covers the
  # rest, keyed by consumer, injected via each chart's extraEnv. Suppliers
  # are addressed by their in-cluster Service (port 80).
  #
  # NOTE: services.tf's computed merge sets `extraEnv` for EVERY service
  # (it must -- both branches of the catalogue ternary need the same key
  # set), and that computed layer overrides the helm-values/*.yaml file.
  # So an extraEnv entry in a helm-values file is silently dropped; any
  # per-service env that has no dedicated chart value MUST live here.
  # labor-performance's EVENT_PUBLISHER is the first such case: its chart
  # never rendered that variable, so the binary ran the log publisher and
  # warehouse.labor-performance.analytics stayed at offset 0 until
  # 2026-09-07 -- the labor projector/reports pair never saw an event.
  # ---------------------------------------------------------------------------
  sync_edge_env = {
    "labor-performance" = [
      { name = "EVENT_PUBLISHER", value = "kafka" },
    ]
    "wes-work-planning" = [
      { name = "PRODUCT_CLASSIFICATION_MODE", value = "http" },
      { name = "INVENTORY_STORAGE_BASE_URL", value = "http://inventory-storage.${var.apps_namespace}.svc.cluster.local:80" },
    ]
    "fulfillment-execution" = [
      { name = "PRODUCT_CLASSIFICATION_MODE", value = "http" },
      { name = "INVENTORY_STORAGE_BASE_URL", value = "http://inventory-storage.${var.apps_namespace}.svc.cluster.local:80" },
    ]
    "workforce-management" = [
      { name = "INSTALLED_CAPACITY_MODE", value = "http" },
      { name = "FULFILLMENT_EXECUTION_BASE_URL", value = "http://fulfillment-execution.${var.apps_namespace}.svc.cluster.local:80" },
      # LABOR_PERFORMANCE_MODE=kafka-cache (workforce-management ADR-0019):
      # ProposePathPlan's measured-rate + observed-idle-share enrichment now
      # comes from an event-fed local cache of labor-performance's
      # warehouse.labor-performance.events (TaskPerformanceRecorded), not a
      # synchronous GET per request. LABOR_PERFORMANCE_BASE_URL is kept below
      # only as the rollback value if this ever needs to flip back to "http".
      { name = "LABOR_PERFORMANCE_MODE", value = "kafka-cache" },
      { name = "LABOR_PERFORMANCE_BASE_URL", value = "http://labor-performance.${var.apps_namespace}.svc.cluster.local:80" },
    ]
  }

  path_catalogue_services = [
    "fulfillment-execution",
    "wes-work-planning",
    "workforce-management",
  ]

  path_catalogue_content = file("${path.module}/../config/process-paths/sortable-fc.yaml")
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
  kiali_port        = 20001

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
