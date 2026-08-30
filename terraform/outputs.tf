output "cluster_name" {
  description = "kind cluster name."
  value       = kind_cluster.warehouse.name
}

output "kube_context" {
  description = "kubectl context for the cluster."
  value       = local.kube_context
}

output "kubeconfig_path" {
  description = "Kubeconfig written by Terraform; also merged into your default kubeconfig by kind."
  value       = local.kubeconfig_path
}

output "kong_proxy_url" {
  description = "Base URL of the Kong proxy as reachable from the host."
  value       = "http://localhost:${var.kong_proxy_http_host_port}"
}

output "routes" {
  description = "Kong route table: host path prefix -> in-cluster service:port."
  value = {
    for name, svc in local.services :
    "http://localhost:${var.kong_proxy_http_host_port}${svc.path}" =>
    "${name}.${var.apps_namespace}.svc.cluster.local:${svc.port}"
  }
}

output "postgres_host" {
  description = "In-cluster DNS name of the shared PostgreSQL primary."
  value       = "${local.postgres_host}:${local.postgres_port}"
}

output "databases" {
  description = "Logical database and owning role per bounded context."
  value = {
    for name, svc in local.services :
    name => { database = svc.db, user = svc.user }
  }
}

output "database_urls" {
  description = "DATABASE_URL handed to each service. LOCAL DEV credentials."
  value       = local.database_urls
  sensitive   = true
}

output "analytics_database_urls" {
  description = "ANALYTICS_DATABASE_URL (projector, read-write) per analytics-enabled service. LOCAL DEV credentials. Same value is also used as ANALYTICS_READER_DATABASE_URL until a distinct read-only role is introduced (see docs/analytics/governance-charter.md's promotion path)."
  value       = local.analytics_database_urls
  sensitive   = true
}

output "psql_command" {
  description = "Drop into psql as the superuser on the shared Postgres release."
  value = join(" ", [
    "kubectl --context ${local.kube_context} -n ${var.data_namespace} exec -it",
    "${local.postgres_release_name}-postgresql-0 --",
    "env PGPASSWORD=<postgres_admin_password> psql -U postgres",
  ])
}

output "apps_namespace" {
  description = "Namespace the four services run in (istio-injection=enabled)."
  value       = kubernetes_namespace.apps.metadata[0].name
}

output "data_namespace" {
  description = "Namespace the shared PostgreSQL release runs in."
  value       = kubernetes_namespace.data.metadata[0].name
}

# ---------------------------------------------------------------------------
# Observability
# ---------------------------------------------------------------------------

output "otlp_endpoint" {
  description = "The OTLP/gRPC endpoint every service's OpenTelemetry exporter should be pointed at. Wired up in each service's own repo, not here."
  value       = local.otlp_grpc_endpoint
}

output "observability_namespace" {
  description = "Namespace holding the OTel Collector, Jaeger, Prometheus and Grafana. Empty when deploy_observability = false."
  value       = var.deploy_observability ? var.observability_namespace : ""
}

output "observability_port_forwards" {
  description = "Port-forward commands for the observability UIs. Grafana logs in as admin / <grafana_admin_password>."
  value = var.deploy_observability ? {
    jaeger     = "kubectl --context ${local.kube_context} port-forward -n ${var.observability_namespace} svc/${local.jaeger_release} ${local.jaeger_query_port}:${local.jaeger_query_port}     # http://localhost:${local.jaeger_query_port}"
    prometheus = "kubectl --context ${local.kube_context} port-forward -n ${var.observability_namespace} svc/${local.prometheus_release}-server ${local.prometheus_port}:${local.prometheus_port}   # http://localhost:${local.prometheus_port}"
    grafana    = "kubectl --context ${local.kube_context} port-forward -n ${var.observability_namespace} svc/${local.grafana_release} ${local.grafana_port}:${local.grafana_port}       # http://localhost:${local.grafana_port}"
    collector  = "kubectl --context ${local.kube_context} port-forward -n ${var.observability_namespace} svc/${local.otel_collector_release} ${local.otel_otlp_grpc_port}:${local.otel_otlp_grpc_port}         # OTLP/gRPC from the host"
  } : {}
}
