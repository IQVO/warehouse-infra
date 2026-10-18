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
  platform = yamldecode(file("${path.module}/../../helm-values/_platform.yaml"))

  postgres_release_name = "postgres"
  postgres_host         = "${local.postgres_release_name}-postgresql.${var.data_namespace}.svc.cluster.local"
  postgres_port         = 5432

  # The application registry (apps.yaml): every application, one entry each.
  # Everything below that used to be a hand-maintained map per concern
  # (services, analytics_services, argocd_repo_owner, the network-* names) is
  # derived from it (ADR 0007).
  registry = yamldecode(file("${path.module}/../apps.yaml")).applications

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
