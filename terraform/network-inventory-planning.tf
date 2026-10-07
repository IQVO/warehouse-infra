# ---------------------------------------------------------------------------
# network-inventory-planning (NIP) — the fleet's inter-warehouse transfer
# planning context. It publishes TransferAllocationRequested commands and
# WorkDemandReleased facts onto warehouse.network-inventory-planning.events,
# consumed by inventory-storage's site-scoped allocation consumer
# (ADR-0030 there, enabled in ../helm-values/inventory-storage.yaml in this
# same change) and by wes-work-planning's inbound integration consumer as
# its FIFTH topic (IQVO/wes-work-planning#150 — no env or chart value there:
# the topic is a hardcoded constant on the existing consumer group). The
# chart lives in NIP's own repo; this file is the environment overlay.
#
# NOT in `local.services`, deliberately, for the same reasons as
# network-fulfillment (see network-fulfillment.tf's header): membership
# there implies the analytics projector/reports apparatus, the frontend
# remote wiring, and — blocking today — `service_source_hash`'s
# filesha256(<repo>/Dockerfile) in services.tf, which fails
# `terraform validate` until NIP's packaging PR (Dockerfile +
# charts/network-inventory-planning) lands on its develop. This file
# mirrors network-fulfillment.tf's explicit pattern instead. The packaging
# follow-up (null_resource.build_and_load + content-derived image tag +
# image values block, exactly like network-fulfillment.tf's) is
# deliberately deferred until that PR merges.
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
#
# THE CHART DOES NOT EXIST ON IQVO/network-inventory-planning's develop
# YET (it lands via a parallel PR in that repo). The Application in
# argocd-apps.tf is declared now, behind the same convention every
# sibling uses, and will sit degraded (missing chart path) until that PR
# merges and ArgoCD syncs — expected, and stated in this PR's body.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# OLTP database. Mirrors postgres.tf's per-service pattern (generated
# password, never committed; Secret consumed by the chart's
# database.existingSecret) without joining local.services — see this
# file's header for why.
#
# NOTE FOR AN ALREADY-RUNNING CLUSTER: Bitnami executes
# primary.initdb.scripts exactly ONCE, against an empty data directory. On
# a cluster whose Postgres already has data, adding this role/database
# here renders the SQL but never runs it. Create them by hand against the
# live primary, mirroring templates/init-databases.sql.tftpl's loop body,
# using the password from
# `terraform output -raw network_inventory_planning_db_password`.
# ---------------------------------------------------------------------------
resource "random_password" "network_inventory_planning_db" {
  length  = 24
  special = false # URL-safe: no chars needing percent-encoding in the DSN
}

locals {
  network_inventory_planning_db_user = "network_inventory_planning"
  network_inventory_planning_db_name = "network_inventory_planning"

  # Routed through PgBouncer (pgbouncer.tf) exactly like every other OLTP
  # database: same dbname/user/password, only the host:port is PgBouncer's.
  network_inventory_planning_database_url = "postgres://${local.network_inventory_planning_db_user}:${random_password.network_inventory_planning_db.result}@${local.pgbouncer_host}:${local.pgbouncer_port}/${local.network_inventory_planning_db_name}?sslmode=disable"

  # Direct (non-pooled, session-mode) counterpart, for any future
  # golang-migrate boot step, mirroring locals.tf's direct_database_urls
  # rationale (session-scoped pg_advisory_lock vs PgBouncer
  # transaction-pooling incompatibility). An unconsumed Secret key is
  # harmless if NIP's binary never reads it.
  network_inventory_planning_migrations_database_url = "postgres://${local.network_inventory_planning_db_user}:${random_password.network_inventory_planning_db.result}@${local.postgres_host}:${local.postgres_port}/${local.network_inventory_planning_db_name}?sslmode=disable"
}

resource "kubernetes_secret" "network_inventory_planning_db" {
  count = var.deploy_services ? 1 : 0

  metadata {
    name      = "network-inventory-planning-db"
    namespace = var.apps_namespace
  }

  data = {
    DATABASE_URL            = local.network_inventory_planning_database_url
    MIGRATIONS_DATABASE_URL = local.network_inventory_planning_migrations_database_url
  }

  depends_on = [kubernetes_namespace.apps]
}

output "network_inventory_planning_db_password" {
  description = "Generated password for the network-inventory-planning OLTP role (needed to create the role by hand on an already-initialized Postgres)."
  value       = random_password.network_inventory_planning_db.result
  sensitive   = true
}

output "network_inventory_planning_route" {
  description = "Kong/Gateway path this context's REST surface is reachable on."
  value       = "${var.api_path_prefix}/network-inventory-planning"
}

# ---------------------------------------------------------------------------
# Helm values for the ArgoCD Application (argocd-apps.tf). Minimal on
# purpose: the chart is still landing in NIP's parallel PR, so this sets
# only the keys whose shape is fixed by fleet convention across every
# sibling chart (service/database/kafka/routing) and nothing
# chart-specific. The image block is deliberately absent until the
# build-and-load wiring exists (see this file's header) — the chart's own
# image defaults apply until then.
# ---------------------------------------------------------------------------
locals {
  network_inventory_planning_helm_values = merge(
    {
      service = {
        type       = "ClusterIP"
        port       = 80
        targetPort = 8080
      }

      # Pre-created above; an Application's Git/cluster-visible
      # valuesObject never carries a plaintext DSN (same posture as
      # postgres.tf's header explains for every other service).
      database = {
        existingSecret    = var.deploy_services ? "network-inventory-planning-db" : ""
        existingSecretKey = "DATABASE_URL"
      }

      # Same literal in-cluster bootstrap address every sibling's
      # helm-values/*.yaml sets (kafka.tf's kafka_brokers output).
      kafka = {
        enabled = true
        brokers = "kafka.warehouse-systems.svc.cluster.local:9092"
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
  )
}
