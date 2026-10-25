# ---------------------------------------------------------------------------
# The platform contract `terraform/20-apps` reads through
# `terraform_remote_state` (ADR 0007 step 2, ADR 0003 decision 4). One
# object, so the application layer never names an individual platform
# resource: every field here is a value `terraform/20-apps/main.tf` already
# passes into `module.application`, moved to a boundary a second state can
# cross. Since ADR 0007 step 3 this layer is "the platform"; the cluster's
# credentials come from 00-cluster's `connection` output.
#
# sensitive: the client certificate/key authenticate as the cluster's
# admin -- same credential providers.tf already uses, just re-exposed for a
# second Terraform process to read.
# ---------------------------------------------------------------------------
output "platform" {
  description = "Everything terraform/20-apps needs from this state: cluster credentials, namespaces, Postgres/PgBouncer endpoints, Gateway readiness and the frontend image-hash inputs. Read via terraform_remote_state, never by resource address."
  value = {
    cluster_name = local.cluster.name
    kube_context = local.cluster.kube_context

    cluster_endpoint           = local.connection.host
    cluster_ca_certificate     = local.connection.cluster_ca_certificate
    cluster_client_certificate = local.connection.client_certificate
    cluster_client_key         = local.connection.client_key

    apps_namespace   = kubernetes_namespace.apps.metadata[0].name
    data_namespace   = kubernetes_namespace.data.metadata[0].name
    argocd_namespace = helm_release.argocd.namespace

    postgres       = local.postgres
    pgbouncer_host = local.pgbouncer_host
    pgbouncer_port = local.pgbouncer_port

    gateway_ready = local.gateway_ready

    # Frontend build inputs computed here because they are content hashes
    # over sibling-repo sources, not platform resources; ADR 0007's context
    # flags this as a layer the eventual cleanup (step 4) still owes a home.
    frontend_source_hash = local.frontend_source_hash
    site_source_hash = {
      "warehouse-console" = local.console_source_hash
      "ecosystem"         = local.ecosystem_source_hash
    }
  }
  sensitive = true
}

output "kong_proxy_url" {
  description = "Base URL of the Kong proxy (the API origin) as reachable from the host."
  value       = "http://localhost:${local.cluster.ports.kong_proxy_http_host_port}"
}

# The two product entrypoints, side by side, because the single most common
# question about this topology is "which port serves what". See
# docs/exposure/localhost-edge-topology.md.
output "product_endpoints" {
  description = "The product's two independent host-facing edges: UI (nginx) and API (Kong)."
  value = {
    ui  = var.deploy_frontends ? "${local.web_origin} (console shell + /mfes/<context>/ remotes, served by nginx)" : "(deploy_frontends = false)"
    api = "${local.api_origin}${var.api_path_prefix}/<context> (Kong; never serves assets)"
  }
}

output "frontend_routes" {
  description = "Web gateway route table: host path -> in-cluster frontend Service."
  value = var.deploy_frontends ? merge(
    {
      "${local.web_origin}/" = "${local.console_service_host}:80"
    },
    {
      for name, fe in local.frontend_remotes :
      "${local.web_origin}/mfes/${name}/" => "${local.frontend_service_host[name]}:80"
    },
  ) : {}
}

output "routes" {
  description = "Kong API route table: host path prefix -> in-cluster service:port. APIs only -- frontend routing is the web gateway's (see frontend_routes)."
  value = {
    for name, svc in local.services :
    "http://localhost:${local.cluster.ports.kong_proxy_http_host_port}${svc.path}" =>
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

output "psql_command" {
  description = "Drop into psql as the superuser on the shared Postgres release."
  value = join(" ", [
    "kubectl --context ${local.cluster.kube_context} -n ${var.data_namespace} exec -it",
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

output "observability_urls" {
  description = "Fixed localhost URLs for the observability UIs, reachable via kind's extraPortMappings (main.tf) -- no port-forward needed. Empty when deploy_observability = false."
  value = var.deploy_observability ? {
    jaeger     = "http://localhost:${local.cluster.ports.jaeger_host_port}"
    prometheus = "http://localhost:${local.cluster.ports.prometheus_host_port}"
    grafana    = "http://localhost:${local.cluster.ports.grafana_host_port} (admin / <grafana_admin_password>)"
  } : {}
}

# ---------------------------------------------------------------------------
# Platform components
# ---------------------------------------------------------------------------

output "metrics_server_enabled" {
  description = "Whether metrics-server (metrics.k8s.io, required for every service chart's HPA to report real utilization instead of <unknown>) is deployed. See metrics-server.tf."
  value       = var.deploy_metrics_server
}

output "kiali_url" {
  description = "Fixed localhost URL for the Kiali service-mesh UI, reachable via kind's extraPortMappings (main.tf). Empty when deploy_kiali or deploy_observability is false."
  value       = var.deploy_kiali && var.deploy_observability ? "http://localhost:${local.cluster.ports.kiali_host_port}" : ""
}
