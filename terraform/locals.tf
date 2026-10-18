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
  # Platform facts every application chart reads (ADR 0002 D2): the Gateway
  # parentRefs, the Kafka brokers, Kong's traces endpoint and CORS origin.
  # helm-values/_platform.yaml is their one source; Terraform reads them from
  # there and preconditions on the platform resources they describe
  # (gateway-api.tf, kafka.tf, observability.tf, frontends.tf) fail the plan
  # when a variable would install the platform somewhere else.
  platform = yamldecode(file("${path.module}/../helm-values/_platform.yaml"))

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
    # values, so they live in helm-values/warehouse-planning.yaml, NOT in its
    # extraEnv (setting both would render duplicate env entries). Its MCP
    # server (cmd/mcp) is switched on in that file, and it joins
    # analytics_services (its analytics read
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
    # env (EVENT_PUBLISHER, KAFKA_BROKERS,
    # OUTBOX_RELAY_INTERVAL) all have DEDICATED chart values, so they live in
    # helm-values/product-master.yaml, NOT in its extraEnv (setting both
    # would render duplicate env entries). It publishes
    # warehouse.product-master.events (ProductClassified is what the
    # classification readers -- inventory-storage, order-management,
    # wes-work-planning, fulfillment-execution -- keep local copies of; ADR 0003
    # stage D). Its MCP server (cmd/mcp) is on in its values file; it joins
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
    # inbound-receiving: the inbound receiving context (ASN, dock appointment,
    # receipt, putaway handover; inbound-receiving ADRs 0001-0006). Its env
    # (EVENT_PUBLISHER, KAFKA_BROKERS, OUTBOX_RELAY_INTERVAL, PRODUCT_MODE +
    # PRODUCT_CONSUMER_GROUP, DOCK_DOOR_MODE + DOCK_DOOR_CONSUMER_GROUP) all
    # have DEDICATED chart values, so they live in
    # helm-values/inbound-receiving.yaml, NOT in its extraEnv (setting
    # both would render duplicate env entries). It publishes
    # warehouse.inbound-receiving.events; inventory-storage consumes the
    # receipt events from it and books StockReceived (inventory-storage ADR
    # 0037: config.inboundReceiptConsumerGroup). It consumes
    # warehouse.product-master.events (SKU copy) and warehouse.facility.events
    # (inbound dock-door copy). Its MCP server (cmd/mcp) is on in its values
    # file; it joins analytics_services (inbound-receiving ADR 0006:
    # inbound-projector + inbound-reports + a separate
    # inbound_receiving_analytics database) and frontend_remotes
    # (inbound_mfe, web/; terraform/frontends.tf).
    "inbound-receiving" = {
      db         = "inbound_receiving"
      user       = "inbound_receiving"
      port       = 8080
      path       = "${var.api_path_prefix}/inbound-receiving"
      chart_path = "${path.module}/../../inbound-receiving/charts/inbound-receiving"
    }
    # slotting-optimization: the slotting context (forward pick-slot plans by
    # ABC velocity with stickiness and human approval; slotting-optimization
    # docs/adr). Gap fix D10 (2026-10-12): the repo already ships its
    # Dockerfile and charts/slotting-optimization, so this entry is the whole
    # registration -- the role and database (provisioned by modules/application),
    # the <name>-db Secret, the image build and the ArgoCD Application
    # (modules/application) and the
    # Kong route ${var.api_path_prefix}/slotting-optimization (the chart's own
    # gatewayApi HTTPRoute, switched on in helm-values/slotting-optimization.yaml)
    # derive from it and that file. Its env (EVENT_PUBLISHER, KAFKA_BROKERS,
    # DEMAND/PRODUCT/LAYOUT_MODE + their consumer groups) all have DEDICATED
    # chart values in that file, not extraEnv. Its migrations live under
    # internal/ (matched by modules/application's default image hash). Its
    # read-only cmd/mcp is switched on in its values file (the ops-agent
    # consumes it) and it is IN
    # analytics_services (its ADR 0006 analytics read side,
    # cmd/slotting-projector + cmd/slotting-reports, since repo PR #37), but
    # NOT in frontend_remotes (no web/ remote).
    "slotting-optimization" = {
      db         = "slotting_optimization"
      user       = "slotting_optimization"
      port       = 8080
      path       = "${var.api_path_prefix}/slotting-optimization"
      chart_path = "${path.module}/../../slotting-optimization/charts/slotting-optimization"
    }
  }

  # GitHub owner of the repo ArgoCD clones per service (applications.tf). The
  # fleet repos were transferred claudioed -> IQVO on 2026-10-03; the older
  # services keep resolving through GitHub's transfer redirect from
  # github.com/IQVO/<name>. warehouse-planning was created directly under
  # IQVO, so github.com/IQVO/warehouse-planning does NOT exist (404) and
  # must be addressed by its real owner. product-master was likewise created
  # directly under IQVO, as were inbound-receiving and slotting-optimization.
  argocd_repo_owner = {
    "warehouse-planning"    = "IQVO"
    "product-master"        = "IQVO"
    "inbound-receiving"     = "IQVO"
    "slotting-optimization" = "IQVO"
  }

  # sslmode=disable: the Postgres release runs without TLS inside the cluster.
  # Traffic between service pods and Postgres (or, since pgbouncer.tf, PgBouncer)
  # is not meshed either (both live in an un-injected namespace), which is fine
  # for a laptop.
  #
  # This map holds the same connection string modules/application writes
  # into each service's <name>-db Secret (DATABASE_URL), with the same
  # generated password the provisioning Job set on the role. It is exposed only
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
    name => "postgres://${svc.user}:${module.application[name].db_password}@${local.pgbouncer_host}:${local.pgbouncer_port}/${svc.db}?sslmode=disable"
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
  # single generated role, whose DSN modules/application writes into the
  # <name>-analytics-db Secret under both ANALYTICS_DATABASE_URL (projector)
  # and ANALYTICS_READER_DATABASE_URL (reports) — the "local/dev" baseline
  # the charts document, same posture as this file's single-role OLTP
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
    # downstream local (analytics_db_info, the module's analytics database
    # and Secret in applications.tf) and the postgres.tf init-job template
    # derive from this single set; the chart's analytics.* values live in
    # its helm-values file.
    "process-path-management",
    # Added (warehouse-planning ADR 0005): the analytics read side -- the
    # `warehouse.warehouse-planning.analytics` stream, cmd/planning-projector
    # (writer) and cmd/planning-reports (read-only reader, role/database
    # warehouse_planning_analytics) -- ships in the SAME image as the OLTP api
    # and mcp binaries (one build_and_load resource, no new image). The chart
    # values it needs (analytics.* including the <name>-reports Kong route)
    # live in helm-values/warehouse-planning.yaml like every sibling's; the
    # analytics database, its Secret and the role and database
    # (modules/application's provisioning Job) pick it up from this one entry,
    # on a fresh or a populated Postgres alike.
    "warehouse-planning",
    # Added (product-master ADR 0006): the master data quality data product --
    # the `warehouse.product-master.analytics` stream (same outbox as the
    # integration topic), cmd/product-projector (writer, admin :8091, group
    # product-master-analytics) and cmd/product-reports (read-only reader,
    # :8092), role/database product_master_analytics. Same image as the api and
    # mcp binaries (one image build). Its analytical migrations live in a
    # top-level analytics/migrations/, already hashed by modules/application's
    # default image hash. Same one-time SQL caveat as warehouse-planning above.
    "product-master",
    # Added (inbound-receiving ADR 0006): the receiving performance and
    # accuracy data product -- the `warehouse.inbound-receiving.analytics`
    # stream (same outbox as the integration topic), cmd/inbound-projector
    # (writer, admin :8091, group inbound-receiving-analytics) and
    # cmd/inbound-reports (read-only reader, :8092), role/database
    # inbound_receiving_analytics. Same image as the api and mcp binaries (one
    # image build). Its analytical migrations live in a top-level
    # analytics/migrations/, already hashed by modules/application's default
    # image hash. Same one-time SQL caveat as warehouse-planning above.
    "inbound-receiving",
    # Added (slotting-optimization ADR 0006, repo PR #37): the slot-plan
    # funnel data product -- the `warehouse.slotting-optimization.analytics`
    # stream (same outbox as the integration topic), cmd/slotting-projector
    # (writer, admin :8091, group slotting-optimization-analytics) and
    # cmd/slotting-reports (read-only reader, :8092), role/database
    # slotting_optimization_analytics. Same image as the api and mcp
    # binaries (one image build; its analytical migrations live in a
    # top-level analytics/migrations/, already covered by
    # modules/application's default hash_globs). Its chart takes the
    # single-DSN shape (analytics.existingSecret, in its helm-values file),
    # NOT the analytics.database.* pair, and ships no reports Kong route.
    # Same one-time SQL caveat as warehouse-planning above.
    "slotting-optimization",
  ])

  analytics_db_info = {
    for name in local.analytics_services :
    name => {
      db   = "${local.services[name].db}_analytics"
      user = "${local.services[name].user}_analytics"
    }
  }

  # The same DSN modules/application writes into each <name>-analytics-db
  # Secret (ANALYTICS_DATABASE_URL and ANALYTICS_READER_DATABASE_URL), kept
  # only for the sensitive `analytics_database_urls` output. Charts never
  # receive it as a value: they read the Secret (existingSecret).
  analytics_database_urls = {
    for name in local.analytics_services :
    name => "postgres://${local.analytics_db_info[name].user}:${module.application[name].analytics_db_password}@${local.postgres_host}:${local.postgres_port}/${local.analytics_db_info[name].db}?sslmode=disable"
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
