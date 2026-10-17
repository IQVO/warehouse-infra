# ---------------------------------------------------------------------------
# network-fulfillment — the fleet's Anti-Corruption Layer to an external
# retail network (Amazon Vendor Direct Fulfillment). The chart lives in its
# own repo; this file is the environment overlay.
#
# It now HAS a database (its NetworkOrder aggregate carries the 24h
# acknowledgement deadlines the sweep enforces, and an in-memory repo forgets
# them on the restart every pod here takes at rollout). It is still NOT in
# `local.services`, deliberately: membership there implies services.tf's
# per-service chart shape (Kong routes, MCP, the shared analytics values),
# which this chart does not have. Its values are computed below; its image,
# databases, Secrets and ArgoCD Application come from modules/application
# like every other application (applications.tf, ADR 0002).
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
  network_fulfillment_helm_values = merge(
    {
      image = {
        repository = "warehouse/network-fulfillment"
        # tag: set by modules/application, which builds the image.
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

        # ON since 2026-10-17 (gap K19): this context's outbox now drains to
        # `warehouse.network-fulfillment.events`, which is what its OWN
        # analytics projector, `/reports/acknowledgement` and the console's
        # network-fulfillment report read -- until now they all stared at an
        # empty/absent stream because the publisher logged instead of
        # publishing. No integration consumer of `networkorder.*` exists
        # anywhere, and that is deliberate (Published Language, facts only);
        # the earlier "publisher stays log" note below is superseded by this.
        # The one thing that would ALSO flip this (chart `kafka.enabled`) is
        # still not used, because KAFKA_BROKERS is already set explicitly in
        # the extraEnv block below.
        eventPublisher = "kafka"

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

      # Capability offer (gaps K10/K13/R5, ADR 0001 section 8 there): the
      # throttled "what can this site ship" figure the network is told. The
      # binary gates the whole pipeline behind CAPABILITY_OFFER_ENABLED, so
      # the reference deployment never ran it. None of these four variables
      # has a dedicated chart value, hence extraEnv (a variable with a
      # chart value belongs in the values above, never here).
      #
      #   - Two Kafka-fed caches, rebuilt from FirstOffset on every boot
      #     under a fresh consumer group per process (no group state to
      #     collide with or to clean up): process-path-management's CPT
      #     schedule / cycle times and wes-work-planning's
      #     PathCapacityChanged. Boot BLOCKS (60 s per cache) until both
      #     have replayed, on purpose: an offer computed from a half-read
      #     model would advertise a wrong figure. Both topics hold a few
      #     dozen messages in this cluster, so the replay takes seconds.
      #   - One REST read of inventory-storage's usable-inventory model
      #     (a documented departure from a third Kafka cache, see the
      #     inventoryclient package in network-fulfillment).
      #   - SITE_ID is the single site the recompute targets; site-1 is the
      #     binary's own default and the site the stub demand above uses.
      #
      # KAFKA_BROKERS is set here, NOT through the chart's kafka.enabled,
      # because kafka.enabled also flips EVENT_PUBLISHER to kafka and
      # would start publishing this context's events to the broker: a
      # separate decision. The publisher stays "log".
      #
      # Nothing leaves the cluster: networkMode stays "stub". To switch the
      # offer off again, delete this block; the offer endpoints and the MCP
      # tool are then not registered, exactly as before.
      extraEnv = [
        { name = "CAPABILITY_OFFER_ENABLED", value = "true" },
        { name = "KAFKA_BROKERS", value = "kafka.${var.apps_namespace}.svc.cluster.local:9092" },
        { name = "INVENTORY_STORAGE_URL", value = "http://inventory-storage.${var.apps_namespace}.svc.cluster.local:80" },
        { name = "SITE_ID", value = "site-1" },
      ]

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
        # Kong exposure (chart's mcp-route.yaml): /api/mcp/<context> -> /mcp.
        route = {
          enabled = var.deploy_mcp_servers
          path    = "${var.api_path_prefix}/mcp/network-fulfillment"
          parentRefs = [{
            name        = local.gateway_name
            namespace   = var.kong_namespace
            sectionName = "http"
          }]
        }
      }
      # Kong plugins (chart's kong-plugins.yaml; fleet decision 2026-10-13:
      # ALL Kong config lives in the application charts, this repo only
      # switches it on — kong-plugins.tf's header has the why).
      kongPlugins = local.kong_chart_values.kongPlugins
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
          # tag: set by modules/application, which builds the image.
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
        # Kong exposure of the reports API (chart's reports-route.yaml),
        # replacing the deleted Terraform-side route (fleet decision
        # 2026-10-13: Kong config lives in the application charts).
        reports = {
          route = {
            enabled = var.deploy_services
            path    = "${var.api_path_prefix}/network-fulfillment/reports"
            parentRefs = [{
              name        = local.gateway_name
              namespace   = var.kong_namespace
              sectionName = "http"
            }]
          }
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
# Databases. The generated passwords, the network-fulfillment-db Secret
# (DATABASE_URL through PgBouncer, MIGRATIONS_DATABASE_URL direct) and the
# network-fulfillment-analytics-db Secret come from modules/application
# (applications.tf, ADR 0002). The role and database names stay here,
# because the platform's initdb script and PgBouncer userlist read them.
#
# NOTE FOR AN ALREADY-RUNNING CLUSTER: Bitnami executes
# primary.initdb.scripts exactly ONCE, against an empty data directory. On a
# cluster whose Postgres already has data, adding a role/database renders the
# SQL but never runs it, and the pod then CrashLoopBackOffs with `password
# authentication failed`. Create them by hand against the live primary,
# mirroring templates/init-databases.sql.tftpl's loop body, using the
# passwords from `terraform output -raw network_fulfillment_db_password` and
# `terraform output -raw network_fulfillment_analytics_db_password`.
# ---------------------------------------------------------------------------
locals {
  network_fulfillment_db_user = "network_fulfillment"
  network_fulfillment_db_name = "network_fulfillment"

  # The "Network Order Acknowledgement & Translation" data product's own
  # analytical database (PR#18 upstream, ADR 0002 there). Its chart's
  # analytics-secret.yaml reads a single ANALYTICS_DATABASE_URL key (both
  # netfulfil-projector and netfulfil-reports use it), so the module writes
  # only that key for this context.
  network_fulfillment_analytics_db_user = "network_fulfillment_analytics"
  network_fulfillment_analytics_db_name = "network_fulfillment_analytics"
}

output "network_fulfillment_db_password" {
  description = "Generated password for the network-fulfillment OLTP role (needed to create the role by hand on an already-initialized Postgres)."
  value       = module.application["network-fulfillment"].db_password
  sensitive   = true
}

output "network_fulfillment_route" {
  description = "Kong/Gateway path this context's REST surface is reachable on."
  value       = "${var.api_path_prefix}/network-fulfillment"
}

output "network_fulfillment_analytics_db_password" {
  description = "Generated password for the network-fulfillment analytics role (needed to create the role by hand on an already-initialized Postgres)."
  value       = module.application["network-fulfillment"].analytics_db_password
  sensitive   = true
}
# Reports route: DELETED (fleet decision 2026-10-13) — the chart's own
# reports-route.yaml renders it (/api/<context>/reports -> /reports), switched
# on by the analytics.reports.route values from services.tf's computed layer.
# The old kubectl-applied Ingress/HTTPRoute here silently vanished on cluster
# rebuild; chart-rendered routes are Helm/ArgoCD-reconciled forever.

output "network_fulfillment_reports_route" {
  description = "Kong/Gateway path this context's analytics reports Service is reachable on."
  value       = "${var.api_path_prefix}/network-fulfillment/reports"
}
