# ---------------------------------------------------------------------------
# network-fulfillment — the fleet's Anti-Corruption Layer to an external
# retail network (Amazon Vendor Direct Fulfillment). Like warehouse-ops-agent
# and unlike the eight database-backed contexts, it is NOT in `local.services`:
# it has NO database and NO Kafka connection, so the whole per-service
# Postgres/secret/analytics apparatus in services.tf and locals.tf would have
# nothing to act on. Same division of responsibility as ops-agent.tf: the
# chart lives in its own repo, this file is the environment overlay.
#
# THE IMPORTANT PART OF THIS FILE IS WHAT IT DOES NOT SET.
#
# `config.networkMode` is left at the chart's "stub" default, deliberately
# and permanently for the local kind cluster. In stub mode the service makes
# no external calls, needs no credentials, and creates no Secret — so this
# cluster cannot acknowledge a real retailer's order, and `terraform apply`
# never needs an SP-API credential to exist anywhere. A future real-network
# environment sets networkMode + credentials.existingSecret in ITS overlay,
# not here. The chart itself refuses to render a non-stub mode without
# credentials rather than producing a pod that dies with
# CreateContainerConfigError (see its tests/test_credential_wiring.py).
# ---------------------------------------------------------------------------

locals {
  network_fulfillment_chart_path = "${path.module}/../../network-fulfillment/charts/network-fulfillment"

  network_fulfillment_source_hash = sha256(join("", concat(
    [for f in sort(fileset("${path.module}/../../network-fulfillment", "**/*.go")) : filesha256("${path.module}/../../network-fulfillment/${f}")],
    [
      filesha256("${path.module}/../../network-fulfillment/Dockerfile"),
      filesha256("${path.module}/../../network-fulfillment/go.mod"),
      filesha256("${path.module}/../../network-fulfillment/go.sum"),
    ],
  )))
}

resource "null_resource" "build_and_load_network_fulfillment" {
  count = var.deploy_services ? 1 : 0

  depends_on = [kind_cluster.warehouse]

  triggers = {
    source_hash = local.network_fulfillment_source_hash
    image       = "warehouse/network-fulfillment:${local.network_fulfillment_image_tag}"
    cluster     = var.cluster_name
  }

  provisioner "local-exec" {
    command = "${path.module}/../scripts/build-and-load.sh 'network-fulfillment' '${local.network_fulfillment_image_tag}' '${var.cluster_name}'"
  }
}

locals {
  # Content-derived, same rationale as services.tf's local.service_image_tags:
  # ArgoCD's sync only fires on an actual diff, so a fixed tag gives it
  # nothing to detect on a rebuild.
  network_fulfillment_image_tag = "local-${substr(local.network_fulfillment_source_hash, 0, 12)}"

  network_fulfillment_helm_values = merge(
    {
      image = {
        repository = "warehouse/network-fulfillment"
        tag        = local.network_fulfillment_image_tag
        pullPolicy = "IfNotPresent"
      }

      service = {
        type       = "ClusterIP"
        port       = 80
        targetPort = 8080
      }

      config = {
        port = "8080"

        # Left at the chart default explicitly rather than by omission, so
        # a reader of this file sees the choice. See the header: a local
        # cluster must not be able to talk to a real retail network.
        networkMode = "stub"

        # The one upstream this context calls. order-management IS in
        # local.services, so its Service name comes from the same
        # convention every other in-cluster REST URL here uses.
        orderManagementUrl = "http://order-management.${var.apps_namespace}.svc.cluster.local:80"

        # Deliberately shorter than the 24h acknowledgement window it
        # sweeps for: the sweep must run many times within the window it
        # enforces, or an expired hold sits on inventory reservations
        # until the next pass rather than at its deadline.
        sweepInterval = "5m"
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
            path     = "${var.api_path_prefix}/network-fulfillment"
            pathType = "Prefix"
          }]
        }]
      }
    },
    # Gateway API routing -- see gateway-api.tf's header for the full pilot
    # history. network-fulfillment isn't in local.services (no database, see
    # this file's own header), so it gets its own gatewayApi block here
    # rather than going through local.gateway_api_pilot_services.
    var.deploy_gateway_api ? {
      gatewayApi = {
        enabled = true
        parentRefs = [{
          name        = local.gateway_name
          namespace   = var.kong_namespace
          sectionName = "http"
        }]
        hosts = [{
          path     = "${var.api_path_prefix}/network-fulfillment"
          pathType = "PathPrefix"
        }]
        stripPath = true
      }
    } : {}
  )
}

output "network_fulfillment_route" {
  description = "Kong/Gateway path this context's REST surface is reachable on."
  value       = "${var.api_path_prefix}/network-fulfillment"
}
