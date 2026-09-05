# ---------------------------------------------------------------------------
# warehouse-ops-agent — a different shape from the other seven services: NO
# database, NO Kafka. A stateless MCP-client aggregator / console-bff fan-out
# reading the other services over plain REST + (eventually) MCP. See its own
# repo's charts/warehouse-ops-agent for the chart; this file is the
# environment overlay, same division of responsibility as helm-values/*.yaml
# for the database-backed services in services.tf.
#
# MCP upstream endpoints (upstreams.* in its chart) are deliberately left
# UNSET here: none of the other seven services' Docker images build the
# cmd/mcp binary yet (only the main REST binary is built/deployed — verified
# by inspecting each Dockerfile), so there is no live MCP endpoint anywhere
# in this cluster for this agent to call. Its own internal/config treats an
# unset MCP endpoint as "skip this client," not a crash, so this is a real,
# intentionally partial deployment (REST fan-out live, MCP upstreams not),
# not a broken one. Wiring MCP server deployment fleet-wide is a separate,
# larger follow-up (a Dockerfile + chart change in five repos).
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
    yamlencode({
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

      ingress = {
        enabled   = true
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
    }),
  ]
}

output "ops_agent_route" {
  description = "Kong route for warehouse-ops-agent, once deployed."
  value       = var.deploy_services ? "http://localhost:${var.kong_proxy_http_host_port}/warehouse-ops-agent" : ""
}
