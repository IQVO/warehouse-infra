# ---------------------------------------------------------------------------
# Kong plugin wiring — VALUES ONLY, no cluster objects (fleet decision
# 2026-10-13).
#
# All Kong configuration — routes AND plugins — now belongs to each
# bounded context's own Helm chart. Terraform no longer kubectl-applies
# any KongClusterPlugin or HTTPRoute. This file only computes the Helm
# values that switch each chart's own plugins/routes on.
#
# WHY THE MOVE: the previous null_resource + kubectl KongClusterPlugins
# (warehouse-cors, warehouse-prometheus) silently vanished from the
# cluster after a rebuild — local-exec provisioners only run when their
# triggers change, so nothing re-applied them and no sensor noticed
# (verified live 2026-10-13: zero KongClusterPlugins in the cluster while
# tfstate claimed both, and the documented /api/mcp/<context> contract
# had never been routed at all). Chart-rendered KongPlugins/HTTPRoutes
# are Helm/ArgoCD-reconciled forever: delete one and the next sync
# restores it.
#
# Per chart (all default-off in the charts; enabled here):
#   kongPlugins.cors          — exact web origin, never "*" (unauth fleet)
#   kongPlugins.prometheus    — per-route RED metrics on Kong :8100
#   kongPlugins.opentelemetry — OTLP traces; REQUIRES Kong started with
#                               KONG_TRACING_INSTRUMENTATIONS (kong.tf),
#                               or the plugin exports zero spans
#   mcp.route                 — /api/mcp/<context> -> /mcp on the -mcp svc
#   analytics.reports.route   — /api/<context>/reports -> /reports
# NO auth plugin anywhere — authentication/authorization is forbidden at
# the gateway by fleet-wide decision (removed 2026-09-11, never re-added).
#
# The sensor: scripts/test-exposure-policy.sh sections 11-13 assert the
# live cluster state (plugins exist AND flow, no auth plugin, every MCP
# server initialize-able through Kong).
# ---------------------------------------------------------------------------

locals {
  kong_traces_endpoint = "http://${local.observability_dns.otel_collector}:${local.otel_otlp_http_port}/v1/traces"

  # The values block every service's chart needs to switch its Kong
  # plugins and routes on. Consumed by service_helm_values (services.tf)
  # for local.services members, and by network-fulfillment.tf /
  # network-inventory-planning.tf for the two contexts that live outside
  # local.services.
  kong_chart_values = {
    kongPlugins = {
      cors = {
        enabled = var.kong_cors_enabled
        origin  = local.web_origin
      }
      prometheus = { enabled = var.deploy_services }
      opentelemetry = {
        enabled        = var.deploy_services
        tracesEndpoint = local.kong_traces_endpoint
      }
    }
  }

  # MCP route values, for contexts in local.mcp_services. parentRefs point
  # at the shared Gateway (gateway-api.tf).
  kong_mcp_route_values = {
    route = {
      enabled = var.deploy_mcp_servers
      path    = "${var.api_path_prefix}/mcp/%s"
      parentRefs = [{
        name        = local.gateway_name
        namespace   = var.kong_namespace
        sectionName = "http"
      }]
    }
  }

  # Reports route values, for contexts in local.analytics_services.
  kong_reports_route_values = {
    route = {
      enabled = var.deploy_services
      path    = "${var.api_path_prefix}/%s/reports"
      parentRefs = [{
        name        = local.gateway_name
        namespace   = var.kong_namespace
        sectionName = "http"
      }]
    }
  }
}
