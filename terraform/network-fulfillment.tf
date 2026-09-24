# ---------------------------------------------------------------------------
# network-fulfillment — the fleet's Anti-Corruption Layer to an external
# retail network (Amazon Vendor Direct Fulfillment). The chart lives in its
# own repo; this file is the environment overlay.
#
# It now HAS a database (its NetworkOrder aggregate carries the 24h
# acknowledgement deadlines the sweep enforces, and an in-memory repo forgets
# them on the restart every pod here takes at rollout). It is still NOT in
# `local.services`, deliberately: membership there also implies the analytics
# projector/reports apparatus, the Kafka wiring and the per-service chart
# shape none of which exist here, and moving it in would recreate the
# resources this file already owns. So the database is wired explicitly
# below, mirroring services.tf's pattern rather than inheriting it.
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

      # The binary REFUSES to boot if this is set and Postgres is
      # unreachable, rather than falling back to the in-memory repo. That
      # is the point: a silent fallback would look healthy while dropping
      # every acknowledgement deadline this context owes the network.
      database = {
        existingSecret    = var.deploy_services ? "network-fulfillment-db" : ""
        existingSecretKey = "DATABASE_URL"
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

# ---------------------------------------------------------------------------
# OLTP database. Mirrors postgres.tf's per-service pattern (generated
# password, never committed; Secret consumed by the chart's
# database.existingSecret) without joining local.services -- see this file's
# header for why.
#
# NOTE FOR AN ALREADY-RUNNING CLUSTER: Bitnami executes
# primary.initdb.scripts exactly ONCE, against an empty data directory. On a
# cluster whose Postgres already has data, adding this role/database here
# renders the SQL but never runs it, and the pod then CrashLoopBackOffs with
# `password authentication failed`. Create them by hand against the live
# primary, mirroring templates/init-databases.sql.tftpl's loop body, using
# the password from `terraform output -raw network_fulfillment_db_password`.
# ---------------------------------------------------------------------------
resource "random_password" "network_fulfillment_db" {
  length  = 24
  special = false # URL-safe: no chars needing percent-encoding in the DSN
}

locals {
  network_fulfillment_db_user = "network_fulfillment"
  network_fulfillment_db_name = "network_fulfillment"

  network_fulfillment_database_url = "postgres://${local.network_fulfillment_db_user}:${random_password.network_fulfillment_db.result}@${local.postgres_host}:${local.postgres_port}/${local.network_fulfillment_db_name}?sslmode=disable"
}

resource "kubernetes_secret" "network_fulfillment_db" {
  count = var.deploy_services ? 1 : 0

  metadata {
    name      = "network-fulfillment-db"
    namespace = var.apps_namespace
  }

  data = {
    DATABASE_URL = local.network_fulfillment_database_url
  }

  depends_on = [kubernetes_namespace.apps]
}

output "network_fulfillment_db_password" {
  description = "Generated password for the network-fulfillment OLTP role (needed to create the role by hand on an already-initialized Postgres)."
  value       = random_password.network_fulfillment_db.result
  sensitive   = true
}

output "network_fulfillment_route" {
  description = "Kong/Gateway path this context's REST surface is reachable on."
  value       = "${var.api_path_prefix}/network-fulfillment"
}
