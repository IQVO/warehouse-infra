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
# The packaging (Dockerfile + chart) is on NIP's develop; this file builds
# and side-loads the image (null_resource.build_and_load_network_inventory_planning,
# content-derived tag) and carries the chart's environment values.
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
  network_inventory_planning_chart_path = "${path.module}/../../network-inventory-planning/charts/network-inventory-planning"

  # Same content hash as network-fulfillment.tf: every Go file, the
  # Dockerfile and the module files. NIP keeps its migrations under
  # internal/adapters/outbound/postgres/migrations, which holds only .sql
  # files, so they are hashed explicitly (a migration-only change has no Go
  # diff and would otherwise never rebuild the image).
  network_inventory_planning_source_hash = sha256(join("", concat(
    [for f in sort(fileset("${path.module}/../../network-inventory-planning", "**/*.go")) : filesha256("${path.module}/../../network-inventory-planning/${f}")],
    [for f in sort(fileset("${path.module}/../../network-inventory-planning", "internal/**/migrations/**")) : filesha256("${path.module}/../../network-inventory-planning/${f}")],
    [
      filesha256("${path.module}/../../network-inventory-planning/Dockerfile"),
      filesha256("${path.module}/../../network-inventory-planning/go.mod"),
      filesha256("${path.module}/../../network-inventory-planning/go.sum"),
    ],
  )))

  # Content-derived, same rationale as services.tf's local.service_image_tags:
  # ArgoCD's sync only fires on an actual diff, so a fixed tag gives it
  # nothing to detect on a rebuild.
  network_inventory_planning_image_tag = "local-${substr(local.network_inventory_planning_source_hash, 0, 12)}"
}

resource "null_resource" "build_and_load_network_inventory_planning" {
  count = var.deploy_services ? 1 : 0

  depends_on = [kind_cluster.warehouse]

  triggers = {
    source_hash = local.network_inventory_planning_source_hash
    image       = "warehouse/network-inventory-planning:${local.network_inventory_planning_image_tag}"
    cluster     = var.cluster_name
  }

  provisioner "local-exec" {
    command = "${path.module}/../scripts/build-and-load.sh 'network-inventory-planning' '${local.network_inventory_planning_image_tag}' '${var.cluster_name}'"
  }
}

locals {
  network_inventory_planning_helm_values = merge(
    {
      image = {
        repository = "warehouse/network-inventory-planning"
        tag        = local.network_inventory_planning_image_tag
        pullPolicy = "IfNotPresent"
      }

      # Read-only MCP server (NIP ADR 0008): the chart's mcp.enabled flag alone
      # decides whether the Deployment exists (MCP is unauthenticated
      # fleet-wide). Mirrors services.tf's `contains(local.mcp_services, name)`
      # block, which never reaches NIP because it is not in local.services.
      mcp = {
        enabled = var.deploy_mcp_servers
      }

      # Analytics read side (NIP ADR 0009): projector (only writer of the
      # SEPARATE analytical database) + read-only reports. Not in
      # local.analytics_services (NIP is not in local.services), so the DSN
      # secret is hand-rolled below, like network-fulfillment.tf. The chart
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
        # NOT in the seeded catalogue: create it in process-path-management
        # (id TRANSFER_DISPATCH, matchPrefix transfer-dispatch, direct) before
        # a TransferPicked fact can release the dispatch demand; until then the
        # dispatch leg stays fail-closed. README "Network inventory planning".
        transferDispatchPathId    = "transfer-dispatch"
        transferDispatchCptOffset = "3h"
        outboxRelayEnabled        = "true"
      }

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
          tag        = "local-${local.frontend_source_hash["network-inventory-planning"]}"
          pullPolicy = "IfNotPresent"
        }
      }
    } : {},
  )
}

# ---------------------------------------------------------------------------
# Analytics database (NIP ADR 0009): the saga-health data product's own
# analytical Postgres database, mirroring network-fulfillment.tf's analytics
# block EXACTLY (own random_password, own db/user locals, own
# kubernetes_secret, own DSN local) rather than joining
# local.analytics_services, whose analytics_db_info does
# local.services[name].db/.user and would KeyError for a name not in
# local.services.
#
# Same NOTE as the OLTP database above: Bitnami's primary.initdb.scripts runs
# exactly ONCE, against an empty data directory. On an already-initialized
# Postgres, create the role/database by hand against the live primary using
# `terraform output -raw network_inventory_planning_analytics_db_password`
# (README "Network inventory planning (NIP) runbook").
# ---------------------------------------------------------------------------
resource "random_password" "network_inventory_planning_analytics_db" {
  length  = 24
  special = false # URL-safe: no chars needing percent-encoding in the DSN
}

locals {
  network_inventory_planning_analytics_db_user = "network_inventory_planning_analytics"
  network_inventory_planning_analytics_db_name = "network_inventory_planning_analytics"

  # DIRECT (non-pooled) Postgres: the projector also runs the analytical
  # migrations, which take a session-scoped advisory lock PgBouncer's
  # transaction pooling cannot honour (and analytics stays direct fleet-wide,
  # see locals.tf analytics_database_urls).
  network_inventory_planning_analytics_database_url = "postgres://${local.network_inventory_planning_analytics_db_user}:***@${local.postgres_host}:${local.postgres_port}/${local.network_inventory_planning_analytics_db_name}?sslmode=disable"
}

resource "kubernetes_secret" "network_inventory_planning_analytics_db" {
  count = var.deploy_services ? 1 : 0

  metadata {
    name      = "network-inventory-planning-analytics-db"
    namespace = var.apps_namespace
  }

  data = {
    # Both keys the chart's projector and reports Deployments read
    # (templates/projector-deployment.yaml, reports-deployment.yaml).
    ANALYTICS_DATABASE_URL        = local.network_inventory_planning_analytics_database_url
    ANALYTICS_READER_DATABASE_URL = local.network_inventory_planning_analytics_database_url
  }

  depends_on = [kubernetes_namespace.apps]
}

output "network_inventory_planning_analytics_db_password" {
  description = "Generated password for the network-inventory-planning analytics role (needed to create the role by hand on an already-initialized Postgres)."
  value       = random_password.network_inventory_planning_analytics_db.result
  sensitive   = true
}

# ---------------------------------------------------------------------------
# Reports route: a SECOND Kong route to the chart's `<release>-reports`
# Service (analytics.reports.service.port = 80), next to the OLTP route.
# Strips `${var.api_path_prefix}/network-inventory-planning/reports` down to
# `/reports`, because cmd/nip-reports registers GET /reports/transfer-funnel
# etc. Ingress when Gateway API is off, HTTPRoute when it is on, never both
# (same rule as network-fulfillment.tf: a disabled-but-present route object is
# one nothing removes).
# ---------------------------------------------------------------------------
resource "kubernetes_ingress_v1" "network_inventory_planning_reports" {
  count = (!var.deploy_gateway_api && var.deploy_services) ? 1 : 0

  metadata {
    name      = "network-inventory-planning-reports"
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
          path      = "${var.api_path_prefix}/network-inventory-planning/reports"
          path_type = "Prefix"
          backend {
            service {
              # The chart's reportsFullname helper renders "<release>-reports";
              # the release is "network-inventory-planning" (argocd-apps.tf).
              name = "network-inventory-planning-reports"
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

# HTTPRoute variant: null_resource + kubectl apply (NOT kubernetes_manifest)
# for the CRD-schema-at-plan-time chicken/egg documented in gateway-api.tf's
# header; destroy-time counterpart so flipping deploy_gateway_api back does not
# orphan the object.
resource "null_resource" "network_inventory_planning_reports_httproute" {
  count = (var.deploy_gateway_api && var.deploy_services) ? 1 : 0

  depends_on = [null_resource.gateway]

  triggers = {
    cluster_id      = kind_cluster.warehouse.id
    kubeconfig      = local.kubeconfig_path
    name            = "network-inventory-planning-reports"
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
        name: network-inventory-planning-reports
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
                  value: ${var.api_path_prefix}/network-inventory-planning/reports
            filters:
              - type: URLRewrite
                urlRewrite:
                  path:
                    type: ReplacePrefixMatch
                    replacePrefixMatch: /reports
            backendRefs:
              - name: network-inventory-planning-reports
                port: 80
      MANIFEST
    EOT
  }

  provisioner "local-exec" {
    when    = destroy
    command = "kubectl --kubeconfig '${self.triggers.kubeconfig}' delete httproute '${self.triggers.name}' -n '${self.triggers.namespace}' --ignore-not-found=true || true"
  }
}

output "network_inventory_planning_reports_route" {
  description = "Kong/Gateway path this context's analytics reports Service is reachable on."
  value       = "${var.api_path_prefix}/network-inventory-planning/reports"
}
