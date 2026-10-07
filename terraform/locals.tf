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
#
# `path` is the PUBLIC route behind Kong, namespaced under var.api_path_prefix
# ("/api") since ADR-0005. It used to be a bare "/<service>", which collides
# head-on with the console shell's own client-side routes -- "/order-management"
# is a page in the SPA as well as an API prefix. Kong strips the whole prefix
# before forwarding, so each Go router keeps its existing unprefixed contract.
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
      path       = "${var.api_path_prefix}/inventory-storage"
      chart_path = "${path.module}/../../inventory-storage/charts/inventory-storage"
    }
    "wes-work-planning" = {
      db         = "wes_work_planning"
      user       = "wes_work_planning"
      port       = 8080
      path       = "${var.api_path_prefix}/wes-work-planning"
      chart_path = "${path.module}/../../wes-work-planning/charts/wes-work-planning"
    }
    "workforce-management" = {
      db         = "workforce_management"
      user       = "workforce_management"
      port       = 8080
      path       = "${var.api_path_prefix}/workforce-management"
      chart_path = "${path.module}/../../workforce-management/charts/workforce-management"
    }
    "fulfillment-execution" = {
      db         = "fulfillment_execution"
      user       = "fulfillment_execution"
      port       = 8080
      path       = "${var.api_path_prefix}/fulfillment-execution"
      chart_path = "${path.module}/../../fulfillment-execution/charts/fulfillment-execution"
    }
    "order-management" = {
      db         = "order_management"
      user       = "order_management"
      port       = 8080
      path       = "${var.api_path_prefix}/order-management"
      chart_path = "${path.module}/../../order-management/charts/order-management"
    }
    "facility-layout" = {
      db         = "facility_layout"
      user       = "facility_layout"
      port       = 8080
      path       = "${var.api_path_prefix}/facility-layout"
      chart_path = "${path.module}/../../facility-layout/charts/facility-layout"
    }
    "labor-performance" = {
      db         = "labor_performance"
      user       = "labor_performance"
      port       = 8080
      path       = "${var.api_path_prefix}/labor-performance"
      chart_path = "${path.module}/../../labor-performance/charts/labor-performance"
    }
    "process-path-management" = {
      db         = "process_path_management"
      user       = "process_path_management"
      port       = 8080
      path       = "${var.api_path_prefix}/process-path-management"
      chart_path = "${path.module}/../../process-path-management/charts/process-path-management"
    }
    # warehouse-planning: capacity planning. Its env (EVENT_PUBLISHER, KAFKA_BROKERS,
    # the two consumer-group ids, OUTBOX_RELAY_INTERVAL) all have DEDICATED chart
    # values, so they live in helm-values/warehouse-planning.yaml, NOT in
    # local.sync_edge_env (that map is only for env with no chart value; setting
    # both would render duplicate env entries). It joins mcp_services (cmd/mcp
    # merged; see terraform/mcp.tf) and analytics_services (its analytics read
    # side, warehouse-planning ADR 0005: projector + reports + a separate
    # warehouse_planning_analytics database).
    "warehouse-planning" = {
      db         = "warehouse_planning"
      user       = "warehouse_planning"
      port       = 8080
      path       = "${var.api_path_prefix}/warehouse-planning"
      chart_path = "${path.module}/../../warehouse-planning/charts/warehouse-planning"
    }
    # product-master: the product master data context (SKU identity,
    # dimensions, handling classification; product-master ADRs 0001-0004). Its
    # env (EVENT_PUBLISHER, KAFKA_BROKERS, LEGACY_IMPORT_CONSUMER_GROUP,
    # OUTBOX_RELAY_INTERVAL) all have DEDICATED chart values, so they live in
    # helm-values/product-master.yaml, NOT in local.sync_edge_env (setting both
    # would render duplicate env entries). It publishes
    # warehouse.product-master.events (ProductClassified is what the
    # classification readers -- inventory-storage, order-management,
    # wes-work-planning, fulfillment-execution -- keep local copies of; ADR 0003
    # stage D). It joins mcp_services (cmd/mcp merged; see terraform/mcp.tf),
    # analytics_services (product-master ADR 0006: product-projector +
    # product-reports + a separate product_master_analytics database) and
    # frontend_remotes (productmaster_mfe, web/; terraform/frontends.tf).
    "product-master" = {
      db         = "product_master"
      user       = "product_master"
      port       = 8080
      path       = "${var.api_path_prefix}/product-master"
      chart_path = "${path.module}/../../product-master/charts/product-master"
    }
  }

  # GitHub owner of the repo ArgoCD clones per service (argocd-apps.tf). The
  # fleet repos were transferred claudioed -> IQVO on 2026-10-03; the older
  # services keep resolving through GitHub's transfer redirect from
  # github.com/IQVO/<name>. warehouse-planning was created directly under
  # IQVO, so github.com/IQVO/warehouse-planning does NOT exist (404) and
  # must be addressed by its real owner. product-master was likewise created
  # directly under IQVO.
  argocd_repo_owner = {
    "warehouse-planning" = "IQVO"
    "product-master"     = "IQVO"
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
  # Traffic between service pods and Postgres (or, since pgbouncer.tf, PgBouncer)
  # is not meshed either (both live in an un-injected namespace), which is fine
  # for a laptop.
  #
  # This map holds the REAL connection string each service receives (services.tf
  # feeds it into the chart's DATABASE_URL Secret), so it must carry the same
  # generated password the initdb script set on the role. It is exposed only
  # through the `database_urls` output, which is marked sensitive.
  #
  # Routed through PgBouncer (pgbouncer.tf), not directly at Postgres, since
  # the PgBouncer connection-pooling rollout (see
  # docs/scalability/pgbouncer-connection-pooling.md): the DSN shape, dbname,
  # user and password are all UNCHANGED from before that rollout -- only the
  # host:port moved from Postgres's own Service to PgBouncer's, which is
  # exactly the point (transparent to every service's pgxpool, same DSN
  # shape, no service-side code change). Analytics DSNs
  # (analytics_database_urls below) are deliberately NOT routed through
  # PgBouncer -- see the design doc's "why analytics stays direct" section.
  database_urls = {
    for name, svc in local.services :
    name => "postgres://${svc.user}:${local.service_passwords[name]}@${local.pgbouncer_host}:${local.pgbouncer_port}/${svc.db}?sslmode=disable"
  }

  # DIRECT (non-pooled, session-mode) Postgres DSN for the SAME 9 OLTP
  # databases as database_urls above -- same dbname/user/password, only the
  # host:port differs (Postgres's own Service, not PgBouncer's). Added to
  # fix a fleet-wide production-blocking bug found during Phase 4 load-test
  # validation (see docs/scalability/pgbouncer-connection-pooling.md's
  # follow-up section and order-management's own ADR documenting this):
  # every OLTP service's golang-migrate postgres driver takes a
  # session-scoped `SELECT pg_advisory_lock($1)` to serialize concurrent
  # migration runs at boot, and PgBouncer's `transaction`-pooling mode
  # (pgbouncer.tf, deliberately left unchanged by this fix -- pool_mode
  # stays "transaction" for all real app traffic) does not support
  # session-scoped state: each statement within one logical client session
  # can land on a DIFFERENT real backend connection, so the advisory lock
  # never behaves as a real mutex and losing replicas crash-loop with
  # `pq: unnamed prepared statement does not exist` / `pq: canceling
  # statement due to statement timeout`. This is the exact same "migrations
  # need a direct/session connection, app traffic goes through the pooler"
  # split this repo already uses for analytics_database_urls below (which
  # were never routed through PgBouncer at all, for the unrelated reason of
  # low QPS -- this local is the OLTP-side counterpart, added specifically
  # for the golang-migrate boot step, NOT a general-purpose bypass of
  # PgBouncer for OLTP runtime traffic).
  #
  # Consumed by postgres.tf's kubernetes_secret.service_db as a SECOND key
  # (MIGRATIONS_DATABASE_URL) alongside the existing DATABASE_URL key --
  # DATABASE_URL itself is completely unchanged (still PgBouncer), so this
  # is purely additive and does not alter runtime traffic behavior at all.
  direct_database_urls = {
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
  # That fix merged 2026-08-30: https://github.com/IQVO/
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
    # Added (warehouse-planning ADR 0005): the analytics read side -- the
    # `warehouse.warehouse-planning.analytics` stream, cmd/planning-projector
    # (writer) and cmd/planning-reports (read-only reader, role/database
    # warehouse_planning_analytics) -- ships in the SAME image as the OLTP api
    # and mcp binaries (one build_and_load resource, no new image). The chart
    # values it needs (analytics.database.projectorUrl/reportsUrl) are the same
    # ones every sibling chart takes, so services.tf's
    # `contains(local.analytics_services, name)` branch, the postgres.tf
    # init-job template, the <name>-reports Kong route (services.tf) and
    # ops-agent's reports URL all pick it up from this one entry. On an
    # already-populated Postgres the new role/database are NOT created by
    # `terraform apply` (initdb never re-runs): see the PR runbook.
    "warehouse-planning",
    # Added (product-master ADR 0006): the master data quality data product --
    # the `warehouse.product-master.analytics` stream (same outbox as the
    # integration topic), cmd/product-projector (writer, admin :8091, group
    # product-master-analytics) and cmd/product-reports (read-only reader,
    # :8092), role/database product_master_analytics. Same image as the api and
    # mcp binaries (one build_and_load). Its analytical migrations live in a
    # top-level analytics/migrations/, already hashed by services.tf's
    # service_source_hash. Same one-time SQL caveat as warehouse-planning above.
    "product-master",
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
  #
  # labor-performance's EVENT_PUBLISHER originally lived here as an
  # extraEnv entry because its chart didn't render that variable. The
  # chart now natively templates it (config.eventPublisher), so the env
  # is set via that key in services.tf instead -- an extraEnv
  # EVENT_PUBLISHER on top of the chart's own rendered one produces a
  # DUPLICATE env entry in the Deployment, which breaks ArgoCD's
  # three-way diff (ComparisonError "doesn't match $setElementOrder
  # list", app stuck Unknown/Progressing; found live 2026-10-05 when the
  # adr-conformance chart changes landed).
  # ---------------------------------------------------------------------------
  sync_edge_env = {
    "wes-work-planning" = [
      { name = "PRODUCT_CLASSIFICATION_MODE", value = "http" },
      { name = "INVENTORY_STORAGE_BASE_URL", value = "http://inventory-storage.${var.apps_namespace}.svc.cluster.local:80" },
      { name = "TRAVEL_DISTANCE_MODE", value = "http" },
      { name = "FACILITY_LAYOUT_BASE_URL", value = "http://facility-layout.${var.apps_namespace}.svc.cluster.local:80" },
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
