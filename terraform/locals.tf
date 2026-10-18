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

  # The application registry (apps.yaml): every application, one entry each.
  # Everything below that used to be a hand-maintained map per concern
  # (services, analytics_services, argocd_repo_owner, the network-* names) is
  # derived from it (ADR 0007).
  registry = yamldecode(file("${path.module}/apps.yaml")).applications

  # The applications that share the /api/<name> route shape: each has a role
  # and a database named after it (dashes become underscores).
  services = {
    for name, a in local.registry : name => {
      db   = replace(name, "-", "_")
      user = replace(name, "-", "_")
      port = 8080
      path = "${var.api_path_prefix}/${name}"
    } if a.kind == "service"
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
  # (cmd/<svc>-projector, cmd/<svc>-reports) of every service whose registry
  # entry says `analytics`. Baseline per docs/analytics/governance-charter.md:
  # a dedicated `<svc>_analytics` database in the SAME Postgres release, owned
  # by a single generated role, whose DSN modules/application writes into the
  # <name>-analytics-db Secret (ANALYTICS_DATABASE_URL for the projector,
  # ANALYTICS_READER_DATABASE_URL for the reports reader). The promotion path
  # to a distinct read-only reports role or a separate instance is a later,
  # additive change (see the governance charter).
  #
  # Only `service` entries: network-fulfillment and network-inventory-planning
  # have their analytics database too, but outside this map and the
  # `analytics_database_urls` output (their DSN lives in their Secret).
  # ---------------------------------------------------------------------
  analytics_services = toset([
    for name, a in local.registry : name if a.kind == "service" && try(a.analytics, false) != false
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
