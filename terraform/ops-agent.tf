# ---------------------------------------------------------------------------
# warehouse-ops-agent — a different shape from the other seven services: NO
# database, NO Kafka. A stateless MCP-client aggregator / console-bff fan-out
# reading the other services over plain REST + (eventually) MCP. See its own
# repo's charts/warehouse-ops-agent for the chart; this file is the
# environment overlay, same division of responsibility as helm-values/*.yaml
# for the database-backed services in services.tf.
#
# MCP upstreams (upstreams.* / credentials.* in its chart) are wired from
# terraform/mcp.tf when var.deploy_mcp_servers is true: each of the five
# contexts' `<svc>-mcp` Services plus that context's READ key. This is the
# agent's actual actuator surface (its ADR 0004); before 2026-09-07 no MCP
# server existed in the cluster and every endpoint here was empty.
# ---------------------------------------------------------------------------

locals {
  ops_agent_chart_path = "${path.module}/../../warehouse-ops-agent/charts/warehouse-ops-agent"

  ops_agent_source_hash = sha256(join("", concat(
    [for f in sort(fileset("${path.module}/../../warehouse-ops-agent", "**/*.go")) : filesha256("${path.module}/../../warehouse-ops-agent/${f}")],
    [
      filesha256("${path.module}/../../warehouse-ops-agent/Dockerfile"),
      filesha256("${path.module}/../../warehouse-ops-agent/go.mod"),
      filesha256("${path.module}/../../warehouse-ops-agent/go.sum"),
    ],
  )))
}

resource "null_resource" "build_and_load_ops_agent" {
  count = var.deploy_services ? 1 : 0

  depends_on = [kind_cluster.warehouse]

  triggers = {
    source_hash = local.ops_agent_source_hash
    image       = "warehouse/warehouse-ops-agent:${var.image_tag}"
    cluster     = var.cluster_name
  }

  provisioner "local-exec" {
    command = "${path.module}/../scripts/build-and-load.sh 'warehouse-ops-agent' '${var.image_tag}' '${var.cluster_name}'"
  }
}

resource "helm_release" "ops_agent" {
  count = var.deploy_services ? 1 : 0

  depends_on = [
    kubernetes_namespace.apps,
    helm_release.kong,
    null_resource.build_and_load_ops_agent,
    helm_release.service,
  ]

  name      = "warehouse-ops-agent"
  chart     = local.ops_agent_chart_path
  namespace = var.apps_namespace

  timeout = 300
  wait    = true

  values = [
    yamlencode(merge(
      {
        image = {
          repository = "warehouse/warehouse-ops-agent"
          tag        = var.image_tag
          pullPolicy = "IfNotPresent"
        }

        service = {
          type       = "ClusterIP"
          port       = 80
          targetPort = 8095
        }

        upstreams = {
          wesWorkPlanning      = { endpoint = var.deploy_mcp_servers ? local.mcp_endpoint["wes-work-planning"] : "" }
          fulfillmentExecution = { endpoint = var.deploy_mcp_servers ? local.mcp_endpoint["fulfillment-execution"] : "" }
          inventoryStorage     = { endpoint = var.deploy_mcp_servers ? local.mcp_endpoint["inventory-storage"] : "" }
          workforceManagement  = { endpoint = var.deploy_mcp_servers ? local.mcp_endpoint["workforce-management"] : "" }
          facilityLayout       = { endpoint = var.deploy_mcp_servers ? local.mcp_endpoint["facility-layout"] : "" }
        }
        credentials = {
          wesWorkPlanningReadKey      = var.deploy_mcp_servers ? random_password.mcp_read_key["wes-work-planning"].result : ""
          fulfillmentExecutionReadKey = var.deploy_mcp_servers ? random_password.mcp_read_key["fulfillment-execution"].result : ""
          inventoryStorageReadKey     = var.deploy_mcp_servers ? random_password.mcp_read_key["inventory-storage"].result : ""
          workforceManagementReadKey  = var.deploy_mcp_servers ? random_password.mcp_read_key["workforce-management"].result : ""
          facilityLayoutReadKey       = var.deploy_mcp_servers ? random_password.mcp_read_key["facility-layout"].result : ""
        }

        # Real, in-cluster REST base URLs for the console-bff order-lifecycle
        # fan-out (cmd/agent/main.go's restclient wiring) — these ARE live
        # today, unlike the MCP upstreams above.
        restUrls = {
          orderManagement      = "http://order-management.${var.apps_namespace}.svc.cluster.local:80"
          inventoryStorage     = "http://inventory-storage.${var.apps_namespace}.svc.cluster.local:80"
          wesWorkPlanning      = "http://wes-work-planning.${var.apps_namespace}.svc.cluster.local:80"
          fulfillmentExecution = "http://fulfillment-execution.${var.apps_namespace}.svc.cluster.local:80"
        }

        # Real, in-cluster REST base URLs for the console-bff's WMS/WES
        # dashboard fan-out (GET /console/reports/wms and /wes -- see
        # warehouse-ops-agent PR #27). Each points at that context's own
        # ANALYTICS reports Service -- a SEPARATE Deployment+Service from the
        # OLTP one above, named "<service>-reports" by every analytics-enabled
        # chart's own reportsFullname helper (see locals.tf's analytics_services
        # set, which now includes all seven contexts). These are only live once
        # `analytics.enabled=true` is actually applied for that service (which
        # `contains(local.analytics_services, each.key)` in services.tf already
        # gates) -- an entry here for a service whose analytics rollout hasn't
        # applied yet just means the BFF's restclient gets a connection refused
        # and that one dashboard section degrades to available:false, per its
        # own documented per-section degradation contract. Not a crash.
        reportsUrls = {
          orderManagement      = "http://order-management-reports.${var.apps_namespace}.svc.cluster.local:80"
          inventoryStorage     = "http://inventory-storage-reports.${var.apps_namespace}.svc.cluster.local:80"
          wesWorkPlanning      = "http://wes-work-planning-reports.${var.apps_namespace}.svc.cluster.local:80"
          fulfillmentExecution = "http://fulfillment-execution-reports.${var.apps_namespace}.svc.cluster.local:80"
          workforceManagement  = "http://workforce-management-reports.${var.apps_namespace}.svc.cluster.local:80"
          facilityLayout       = "http://facility-layout-reports.${var.apps_namespace}.svc.cluster.local:80"
          laborPerformance     = "http://labor-performance-reports.${var.apps_namespace}.svc.cluster.local:80"
        }

        # Kong route. NO Ingress at all once Gateway API is on (see the
        # gatewayApi block below) -- disabled-but-present would otherwise
        # still create a Kong route object nothing removes.
        ingress = {
          enabled   = !var.deploy_gateway_api
          className = "kong"
          annotations = {
            "konghq.com/strip-path" = "true"
          }
          hosts = [{
            host = ""
            paths = [{
              path     = "/warehouse-ops-agent"
              pathType = "Prefix"
            }]
          }]
        }
      },
      # Gateway API routing -- see gateway-api.tf's header for the full
      # pilot history. warehouse-ops-agent isn't in local.services (it has
      # no database, see this file's own header), so it gets its own
      # gatewayApi block here rather than going through
      # local.gateway_api_pilot_services.
      var.deploy_gateway_api ? {
        gatewayApi = {
          enabled = true
          parentRefs = [{
            name        = local.gateway_name
            namespace   = var.kong_namespace
            sectionName = "http"
          }]
          hosts = [{
            path     = "/warehouse-ops-agent"
            pathType = "PathPrefix"
          }]
          stripPath = true
        }
      } : {}
    )),
  ]
}

output "ops_agent_route" {
  description = "Kong route for warehouse-ops-agent, once deployed."
  value       = var.deploy_services ? "http://localhost:${var.kong_proxy_http_host_port}/warehouse-ops-agent" : ""
}
