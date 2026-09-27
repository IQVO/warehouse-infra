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

        # How often the network is polled. Inbound is a poll and nothing
        # else (ADR 0001 section 5), so this is the ONLY thing that brings
        # demand into this context. Deliberately far below the 24h
        # acknowledgement window: a slow or stopped poller spends a
        # deadline the network set, not one we chose.
        pollInterval = "1m"
      }

      # The Anti-Corruption Layer's dictionary, and NOT optional in any
      # environment that expects to receive anything: with an empty
      # dictionary every order is rejected as untranslatable, and the
      # symptom is invisible because refusing unknown products is also
      # correct behaviour. The binary logs a warning at startup when this
      # is absent.
      #
      # These SKUs match the ones e2e-tests and the process-path catalogue
      # already use in this cluster, so demand seeded below can actually be
      # planned by order-management rather than failing on an unknown SKU.
      productTranslation = {
        mappings = [
          { networkProductId = "ASIN-LOCAL-1", sku = "sku-1" },
          { networkProductId = "ASIN-LOCAL-2", sku = "sku-2" },
        ]
      }

      # Demand for the STUB gateway. This is what makes the inbound leg
      # observable in a credential-free cluster: without it the poller runs
      # correctly forever against a network that has nothing to give it,
      # which is indistinguishable from a poller that is broken.
      #
      # Relative deadlines on purpose — a fixed instant goes stale and every
      # order becomes instantly infeasible, which reads like a promise bug
      # rather than an expired fixture.
      stubDemand = {
        demands = [
          {
            networkRef     = "po-local-1"
            siteId         = "site-1"
            requiredShipBy = "+36h"
            lines = [
              { networkLineRef = "1", networkProductId = "ASIN-LOCAL-1", quantity = 1 },
            ]
          },
        ]
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

      # MCP server (PR#18 upstream, ADR 0003 there). Reuses the SAME shared
      # var.deploy_mcp_servers toggle the other eight contexts use in
      # services.tf -- no separate variable invented for this context.
      mcp = {
        enabled = var.deploy_mcp_servers
      }
    },
    # The context's own Module Federation remote (PR#16 upstream), the same
    # `frontend.enabled` chart block services.tf sets for every service in
    # local.frontend_remotes -- mirrored here by hand since
    # network-fulfillment isn't in local.services and so services.tf's
    # `contains(keys(local.frontend_remotes), name) ? {...}` computed block
    # never reaches it. frontends.tf's own
    # local.frontend_remotes/local.frontend_source_hash already cover
    # "network-fulfillment" (added there in this same change), so this
    # just reads that same shared local, exactly like services.tf's block
    # does for the other eight.
    contains(keys(local.frontend_remotes), "network-fulfillment") ? {
      frontend = {
        enabled = true
        image = {
          repository = "warehouse/network-fulfillment-frontend"
          tag        = "local-${local.frontend_source_hash["network-fulfillment"]}"
          pullPolicy = "IfNotPresent"
        }
      }
    } : {},
    # Analytics data product (PR#18 upstream, ADR 0002 there): its own
    # analytical database, hand-rolled below (own random_password, own
    # db/user locals, own kubernetes_secret, own DSN local) rather than
    # joining local.analytics_services, for the same reason this whole file
    # exists -- see the header. `analytics.database.existingSecret` (NOT
    # `projectorUrl`/`reportsUrl`): this chart's own values.yaml has a
    # SINGLE `analytics.database.url`/`existingSecret` pair, not the
    # projector/reports URL split facility-layout's chart has (both
    # netfulfil-projector and netfulfil-reports read the one
    # ANALYTICS_DATABASE_URL key directly -- confirmed against PR#18's
    # actual values.yaml and templates/_helpers.tpl
    # analyticsSecretName/analytics-secret.yaml, not assumed). existingSecret
    # is used rather than a plaintext `url` for the same reason the OLTP
    # `database` block above uses existingSecret: an ArgoCD Application's
    # `helm.valuesObject` is cluster/Git-visible, so the DSN is never placed
    # there directly.
    var.deploy_services ? {
      analytics = {
        enabled = true
        database = {
          existingSecret = "network-fulfillment-analytics-db"
        }
      }
    } : {},
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

# ---------------------------------------------------------------------------
# Analytics database (PR#18 upstream, ADR 0002 there): the "Network Order
# Acknowledgement & Translation" data product's own analytical Postgres
# database, mirroring the OLTP database block above EXACTLY (own
# random_password, own db/user locals, own kubernetes_secret, own DSN
# local) rather than joining local.analytics_services in locals.tf --
# `analytics_db_info` there does `local.services[name].db`/`.user`, which
# would KeyError for a name not in `local.services`. Same
# not-in-local.services reasoning as the OLTP database above; see this
# file's header.
#
# Same NOTE as the OLTP database above applies here too: Bitnami's
# primary.initdb.scripts runs exactly ONCE. Adding this role/database to
# postgres.tf's already-applied initdb template on an already-initialized
# Postgres renders the SQL but never runs it. Create the role/database by
# hand against the live primary in that case, using the password from
# `terraform output -raw network_fulfillment_analytics_db_password`.
# ---------------------------------------------------------------------------
resource "random_password" "network_fulfillment_analytics_db" {
  length  = 24
  special = false
}

locals {
  network_fulfillment_analytics_db_user = "network_fulfillment_analytics"
  network_fulfillment_analytics_db_name = "network_fulfillment_analytics"

  # This DSN carries the real generated password via interpolation
  # (${random_password.network_fulfillment_analytics_db.result}), matching
  # every other DSN in this repo (locals.tf's database_urls/
  # analytics_database_urls, and this file's own OLTP
  # network_fulfillment_database_url above).
  network_fulfillment_analytics_database_url = "postgres://${local.network_fulfillment_analytics_db_user}:${random_password.network_fulfillment_analytics_db.result}@${local.postgres_host}:${local.postgres_port}/${local.network_fulfillment_analytics_db_name}?sslmode=disable"
}

resource "kubernetes_secret" "network_fulfillment_analytics_db" {
  count = var.deploy_services ? 1 : 0

  metadata {
    name      = "network-fulfillment-analytics-db"
    namespace = var.apps_namespace
  }

  data = {
    # This chart's own analytics-secret.yaml template has a single
    # ANALYTICS_DATABASE_URL key (both netfulfil-projector and
    # netfulfil-reports read it directly) -- NOT the
    # ANALYTICS_DATABASE_URL/ANALYTICS_READER_DATABASE_URL pair
    # facility-layout's chart has. Confirmed against PR#18's actual
    # templates/analytics-secret.yaml, not assumed.
    ANALYTICS_DATABASE_URL = local.network_fulfillment_analytics_database_url
  }

  depends_on = [kubernetes_namespace.apps]
}

output "network_fulfillment_analytics_db_password" {
  description = "Generated password for the network-fulfillment analytics role (needed to create the role by hand on an already-initialized Postgres)."
  value       = random_password.network_fulfillment_analytics_db.result
  sensitive   = true
}

# ---------------------------------------------------------------------------
# Reports route (warehouse-console#43 gap closure): a SECOND Kong
# Ingress/HTTPRoute pointing at this chart's own `<release>-reports`
# Service (analytics.reports.service.port, confirmed 80 in PR#18's
# values.yaml -- see charts/network-fulfillment/values.yaml
# analytics.reports.service), alongside the main OLTP route above. Strips
# `${var.api_path_prefix}/network-fulfillment/reports` down to `/reports`
# -- one path segment longer than the main route's strip, but the same
# strip-path mechanism -- because the reports binary's own router
# (internal/adapters/inbound/http/reports_handler.go's NewReportsRouter,
# confirmed on PR#18's branch) registers `GET /reports/acknowledgement`,
# not `GET /acknowledgement`.
#
# Mirrors the OLTP route's own var.deploy_gateway_api ternary in this same
# file: Ingress when Gateway API is off, HTTPRoute when it's on. Never
# both at once, for the same "disabled-but-present still creates a route
# object nothing removes" reason as the OLTP route.
# ---------------------------------------------------------------------------
resource "kubernetes_ingress_v1" "network_fulfillment_reports" {
  count = (!var.deploy_gateway_api && var.deploy_services) ? 1 : 0

  metadata {
    name      = "network-fulfillment-reports"
    namespace = var.apps_namespace
    annotations = {
      "konghq.com/strip-path"       = "true"
      "kubernetes.io/ingress.class" = "kong"
    }
  }

  spec {
    ingress_class_name = "kong"

    rule {
      http {
        path {
          path      = "${var.api_path_prefix}/network-fulfillment/reports"
          path_type = "Prefix"
          backend {
            service {
              # By convention: the chart's reportsFullname helper renders
              # "<release>-reports"; the release name is "network-fulfillment"
              # (argocd-apps.tf's kubectl_manifest.network_fulfillment_application
              # metadata.name), same convention services.tf's
              # main-route backend names rely on.
              name = "network-fulfillment-reports"
              port {
                number = 80
              }
            }
          }
        }
      }
    }
  }

  depends_on = [kubernetes_namespace.apps]
}

# HTTPRoute variant: a `null_resource` + `kubectl apply` (NOT the
# `kubernetes_manifest` provider resource), for the exact chicken/egg
# reason documented at length in gateway-api.tf's header on
# null_resource.gateway_api_crds/gateway_class/gateway --
# `kubernetes_manifest` needs the CRD's OpenAPI schema at PLAN time, which
# does not exist yet on a from-scratch `terraform apply` that installs the
# Gateway API CRDs and a resource using them in the same run. Mirrors
# those same three resources' shape (triggers, local-exec apply, a
# destroy-time counterpart so flipping deploy_gateway_api back to false --
# or a bare `terraform destroy` -- doesn't orphan this HTTPRoute the way
# an untracked local-exec object otherwise would).
resource "null_resource" "network_fulfillment_reports_httproute" {
  count = (var.deploy_gateway_api && var.deploy_services) ? 1 : 0

  depends_on = [null_resource.gateway]

  triggers = {
    cluster_id      = kind_cluster.warehouse.id
    kubeconfig      = local.kubeconfig_path
    name            = "network-fulfillment-reports"
    namespace       = var.apps_namespace
    gateway_name    = local.gateway_name
    kong_namespace  = var.kong_namespace
    api_path_prefix = var.api_path_prefix
  }

  provisioner "local-exec" {
    command = <<-EOT
      cat <<'MANIFEST' | kubectl --kubeconfig '${local.kubeconfig_path}' apply -f -
      apiVersion: gateway.networking.k8s.io/v1
      kind: HTTPRoute
      metadata:
        name: network-fulfillment-reports
        namespace: ${var.apps_namespace}
      spec:
        parentRefs:
          - name: ${local.gateway_name}
            namespace: ${var.kong_namespace}
            sectionName: http
        rules:
          - matches:
              - path:
                  type: PathPrefix
                  value: ${var.api_path_prefix}/network-fulfillment/reports
            filters:
              - type: URLRewrite
                urlRewrite:
                  path:
                    type: ReplacePrefixMatch
                    replacePrefixMatch: /reports
            backendRefs:
              - name: network-fulfillment-reports
                port: 80
      MANIFEST
    EOT
  }

  # See gateway_api_crds' destroy provisioner comment in gateway-api.tf.
  provisioner "local-exec" {
    when    = destroy
    command = "kubectl --kubeconfig '${self.triggers.kubeconfig}' delete httproute '${self.triggers.name}' -n '${self.triggers.namespace}' --ignore-not-found=true || true"
  }
}

output "network_fulfillment_reports_route" {
  description = "Kong/Gateway path this context's analytics reports Service is reachable on."
  value       = "${var.api_path_prefix}/network-fulfillment/reports"
}
