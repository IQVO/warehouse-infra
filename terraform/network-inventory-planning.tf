# ---------------------------------------------------------------------------
# network-inventory-planning (NIP) — the fleet's inter-warehouse transfer
# planning context. It publishes TransferAllocationRequested commands and
# WorkDemandReleased facts onto warehouse.network-inventory-planning.events,
# consumed by inventory-storage's site-scoped allocation consumer
# (ADR-0030 there, enabled in ../helm-values/inventory-storage.yaml) and by
# wes-work-planning's inbound integration consumer as its FIFTH topic
# (IQVO/wes-work-planning#150 — no env or chart value there: the topic is a
# hardcoded constant on the existing consumer group). The chart lives in
# NIP's own repo; this file is the environment overlay.
#
# Its platform contract (generated passwords, the network-inventory-planning-db
# and network-inventory-planning-analytics-db Secrets, the API and frontend
# image builds, the ArgoCD Application) is created by modules/application
# (applications.tf, ADR 0002 phase 1:
# docs/adr/0002-application-delivery-boundary.md). This file keeps what the
# module does not own yet: the database names and the chart values (ADR 0002
# phase 3 moves the values to a value file).
#
# NOT in `local.services`: that map's entries also imply the computed values
# layer in services.tf (analytics DSN as a value, the shared MCP/frontend
# blocks), which NIP's chart does not take in that shape.
#
# Kafka topics: NO declaration in this repo is the fleet norm. Every
# business topic (see kafka.tf's overrideConfiguration comment and
# docs/kafka-partition-scaleup.md) is auto-created by its first writer
# with the broker's num.partitions=8 / replication-factor-1 overrides;
# there is no kafka_topic resource and no topic manifest to add.
# warehouse.network-inventory-planning.events and
# warehouse.network-inventory-planning.analytics (NIP's analytics stream
# name follows the warehouse.<context>.analytics convention) take that
# same path, so kafka.tf is untouched by design.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# OLTP database names. The role and database are created by the initdb
# script (postgres.tf) with the module's generated password.
#
# NOTE FOR AN ALREADY-RUNNING CLUSTER: Bitnami executes
# primary.initdb.scripts exactly ONCE, against an empty data directory. On
# a cluster whose Postgres already has data, a new role/database here
# renders the SQL but never runs it. Create them by hand against the live
# primary, mirroring templates/init-databases.sql.tftpl's loop body, using
# the password from
# `terraform output -raw network_inventory_planning_db_password`.
# ---------------------------------------------------------------------------
locals {
  network_inventory_planning_db_user = "network_inventory_planning"
  network_inventory_planning_db_name = "network_inventory_planning"
}

output "network_inventory_planning_db_password" {
  description = "Generated password for the network-inventory-planning OLTP role (needed to create the role by hand on an already-initialized Postgres)."
  value       = module.application["network-inventory-planning"].db_password
  sensitive   = true
}

output "network_inventory_planning_route" {
  description = "Kong/Gateway path this context's REST surface is reachable on."
  value       = "${var.api_path_prefix}/network-inventory-planning"
}

# ---------------------------------------------------------------------------
# Helm values for the ArgoCD Application the module creates. The image tag is
# the module's content-derived tag (ArgoCD's sync only fires on an actual
# diff, so a fixed tag would give it nothing to detect on a rebuild).
# ---------------------------------------------------------------------------
locals {
  network_inventory_planning_helm_values = merge(
    {
      image = {
        repository = "warehouse/network-inventory-planning"
        pullPolicy = "IfNotPresent"
      }

      # Read-only MCP server (NIP ADR 0008): the chart's mcp.enabled flag alone
      # decides whether the Deployment exists (MCP is unauthenticated
      # fleet-wide). Mirrors services.tf's `contains(local.mcp_services, name)`
      # block, which never reaches NIP because it is not in local.services.
      mcp = {
        enabled = var.deploy_mcp_servers
        # Kong exposure (chart's mcp-route.yaml): /api/mcp/<context> -> /mcp.
        route = {
          enabled = var.deploy_mcp_servers
          path    = "${var.api_path_prefix}/mcp/network-inventory-planning"
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

      # Analytics read side (NIP ADR 0009): projector (only writer of the
      # SEPARATE analytical database) + read-only reports. Not in
      # local.analytics_services (NIP is not in local.services); the DSN
      # Secret comes from modules/application (analytics_database.secret
      # in applications.tf). The chart
      # reads BOTH ANALYTICS_DATABASE_URL (projector) and
      # ANALYTICS_READER_DATABASE_URL (reports) from this one Secret; the same
      # DIRECT DSN serves both, the documented local/dev baseline (a
      # read-only role is the promotion path). The projector's consumer group
      # is the chart's fixed default `network-inventory-planning-analytics`.
      analytics = {
        enabled = true
        database = {
          existingSecret = "network-inventory-planning-analytics-db"
        }
        # Kong exposure of the reports API (chart's reports-route.yaml),
        # replacing the deleted Terraform-side route (fleet decision
        # 2026-10-13: Kong config lives in the application charts).
        reports = {
          route = {
            enabled = var.deploy_services
            path    = "${var.api_path_prefix}/network-inventory-planning/reports"
            parentRefs = [{
              name        = local.gateway_name
              namespace   = var.kong_namespace
              sectionName = "http"
            }]
          }
        }
      }

      # Environment the binary reads (cmd/network-inventory-planning/main.go),
      # each key a dedicated chart value. Consumer-group ids are FIXED and
      # STABLE (a rescheduled pod resumes from its committed offsets; a new
      # group rebuilds the read models from topic history). EMPTY would switch
      # that consumer off.
      config = {
        # Fail-closed (NIP ADR 0005): an empty pick path makes
        # POST /v1/transfers:approve answer 503. `pick` is an existing family
        # in the process-path catalogue (PICK).
        transferPickPathId    = "pick"
        transferPickCptOffset = "2h"
        # `dispatch-transfer` falls in the DISPATCH family that
        # process-path-management declares in catalogue/paths.json (ADR 0035:
        # id DISPATCH, matchPrefix dispatch, capability dispatch, intake
        # STOCK_TRANSFER). fulfillment-execution turns the path id into the task
        # type (ADR-0036), and a path matches an id only as `dispatch` or
        # `dispatch-*`, so a value outside that family never resolves. Until
        # seed_catalogue.py has converged the DISPATCH path (README "Post-deploy
        # seeds") the dispatch leg stays fail-closed after the pick.
        transferDispatchPathId    = "dispatch-transfer"
        transferDispatchCptOffset = "3h"
        outboxRelayEnabled        = "true"
      }

      service = {
        type       = "ClusterIP"
        port       = 80
        targetPort = 8080
      }

      # Created by modules/application; an Application's Git/cluster-visible
      # valuesObject never carries a plaintext DSN (same posture as
      # postgres.tf's header explains for every other service).
      database = {
        existingSecret    = var.deploy_services ? "network-inventory-planning-db" : ""
        existingSecretKey = "DATABASE_URL"
        # Direct (non-pooled) DSN for the golang-migrate step; the Secret above
        # already carries it. NIP reads MIGRATIONS_DATABASE_URL since ADR 0006.
        migrationsExistingSecretKey = "MIGRATIONS_DATABASE_URL"
      }

      # Same literal in-cluster bootstrap address every sibling's
      # helm-values/*.yaml sets (kafka.tf's kafka_brokers output).
      kafka = {
        enabled                     = true
        brokers                     = "kafka.warehouse-systems.svc.cluster.local:9092"
        siteCapabilityConsumerGroup = "network-inventory-planning-site-capability"
        siteSkuDemandConsumerGroup  = "network-inventory-planning-site-sku-demand"
        capacityPlanConsumerGroup   = "network-inventory-planning-capacity-plan"
        transferReplyConsumerGroup  = "network-inventory-planning-transfer-reply"
        transferFactConsumerGroup   = "network-inventory-planning-transfer-fact"
      }
      # Kong route: chart-rendered Ingress when Gateway API is off,
      # enabled=false-but-present so the key set stays stable. See the
      # gatewayApi block below for the Gateway API side — split exactly
      # like network-fulfillment.tf's ingress/gatewayApi pair, never both
      # active at once.
      ingress = {
        enabled   = !var.deploy_gateway_api
        className = "kong"
        annotations = {
          "konghq.com/strip-path" = "true"
        }
        hosts = [{
          host = ""
          paths = [{
            path     = "${var.api_path_prefix}/network-inventory-planning"
            pathType = "Prefix"
          }]
        }]
      }
    },
    # Gateway API routing (gateway-api.tf): the chart's own gatewayApi
    # block against the shared Gateway, the same values shape every
    # sibling in local.services gets from services.tf — mirrored by hand
    # here since network-inventory-planning isn't in local.services.
    var.deploy_gateway_api ? {
      gatewayApi = {
        enabled = true
        parentRefs = [{
          name        = local.gateway_name
          namespace   = var.kong_namespace
          sectionName = "http"
        }]
        hosts = [{
          path     = "${var.api_path_prefix}/network-inventory-planning"
          pathType = "PathPrefix"
        }]
        stripPath = true
      }
    } : {},
    # The context's own Module Federation remote (nip_mfe), the same
    # `frontend.enabled` chart block services.tf sets for every service in
    # local.frontend_remotes -- mirrored by hand because NIP is not in
    # local.services (network-fulfillment.tf does the same). Routing for it
    # belongs to the Nginx web gateway (frontends.tf), never Kong. The chart's
    # frontend component lands with IQVO/network-inventory-planning#18; before
    # that merge these values are ignored by the chart (harmless).
    contains(keys(local.frontend_remotes), "network-inventory-planning") ? {
      frontend = {
        enabled = true
        image = {
          repository = "warehouse/network-inventory-planning-frontend"
          # tag: set by modules/application, which builds the image.
          pullPolicy = "IfNotPresent"
        }
      }
    } : {},
  )
}

# ---------------------------------------------------------------------------
# Analytics database names (NIP ADR 0009): the saga-health data product's own
# analytical Postgres database. The module generates its password and writes
# the network-inventory-planning-analytics-db Secret (ANALYTICS_DATABASE_URL
# and ANALYTICS_READER_DATABASE_URL, the same DIRECT DSN for both: the
# projector also runs the analytical migrations, which take a session-scoped
# advisory lock PgBouncer's transaction pooling cannot honour).
#
# Same NOTE as the OLTP database above: on an already-initialized Postgres,
# create the role/database by hand using
# `terraform output -raw network_inventory_planning_analytics_db_password`
# (README "Network inventory planning (NIP) runbook").
# ---------------------------------------------------------------------------
locals {
  network_inventory_planning_analytics_db_user = "network_inventory_planning_analytics"
  network_inventory_planning_analytics_db_name = "network_inventory_planning_analytics"
}

output "network_inventory_planning_analytics_db_password" {
  description = "Generated password for the network-inventory-planning analytics role (needed to create the role by hand on an already-initialized Postgres)."
  value       = module.application["network-inventory-planning"].analytics_db_password
  sensitive   = true
}

# Reports route: DELETED (fleet decision 2026-10-13) — the chart's own
# reports-route.yaml renders it (/api/<context>/reports -> /reports), switched
# on by the analytics.reports.route values from services.tf's computed layer.
# The old kubectl-applied Ingress/HTTPRoute here silently vanished on cluster
# rebuild; chart-rendered routes are Helm/ArgoCD-reconciled forever.

output "network_inventory_planning_reports_route" {
  description = "Kong/Gateway path this context's analytics reports Service is reachable on."
  value       = "${var.api_path_prefix}/network-inventory-planning/reports"
}
