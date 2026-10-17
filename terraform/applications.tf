# ---------------------------------------------------------------------------
# The application registry: every application on the platform, registered
# through modules/application (ADR 0002 decision D3,
# docs/adr/0002-application-delivery-boundary.md; the registry's shape:
# docs/adr/0004-one-application-registry.md). An application is one
# deployable with its own chart and ArgoCD Application: every bounded
# context, plus the console shell, the EventCatalog and the ops agent.
#
# One module instance per application owns that application's platform
# contract: its generated database passwords, its Secrets, its locally built
# images and its ArgoCD Application. Every Kubernetes object of the
# application itself comes from its own chart.
#
# Registering an application:
#   - a database-backed context with the shared chart shape (Kong routes,
#     MCP, analytics values from services.tf) goes in local.services
#     (locals.tf) and is picked up below automatically;
#   - anything else gets its own entry in local.other_applications, with its
#     values computed in its own file (network-fulfillment.tf, ops-agent.tf,
#     frontends.tf, ...).
#
# The moved blocks in moved-applications.tf map every pre-module address
# onto the module, so applying them only rewrites state addresses: no
# password is regenerated, no Secret, image or Application is replaced.
# ---------------------------------------------------------------------------

locals {
  # The database endpoints every OLTP database uses: pooled through PgBouncer
  # for the application, direct for golang-migrate.
  oltp_endpoints = {
    pooled_host = local.pgbouncer_host
    pooled_port = local.pgbouncer_port
    direct_host = local.postgres_host
    direct_port = local.postgres_port
  }

  service_applications = {
    for name, svc in local.services : name => {
      deploy = var.deploy_services
      chart = {
        repo_url = "https://github.com/${lookup(local.argocd_repo_owner, name, "claudioed")}/${name}.git"
        path     = "charts/${name}"
      }
      image    = {}
      frontend = contains(keys(local.frontend_remotes), name) ? { source_hash = local.frontend_source_hash[name] } : null
      database = merge(local.oltp_endpoints, { name = svc.db, user = svc.user })
      # These charts still take the analytics DSN as a value
      # (analytics.database.projectorUrl, set by services.tf), so their
      # analytics passwords stay in postgres.tf until ADR 0002 phase 3 moves
      # the DSN into a Secret.
      analytics_database = null
      secrets            = {}
    }
  }

  other_applications = {
    "network-inventory-planning" = {
      deploy = var.deploy_services
      chart = {
        repo_url = "https://github.com/IQVO/network-inventory-planning.git"
        path     = "charts/network-inventory-planning"
      }
      # Exactly the globs network-inventory-planning.tf hashed before the
      # module. NOTE: the repo also keeps analytics/migrations/, which this
      # list does not hash, so an analytics-migration-only change does not
      # rebuild the image. The module default (which hashes it) replaces this
      # list in its own change, because it changes the image tag.
      image = {
        hash_globs = ["**/*.go", "internal/**/migrations/**"]
      }
      frontend = contains(keys(local.frontend_remotes), "network-inventory-planning") ? { source_hash = local.frontend_source_hash["network-inventory-planning"] } : null
      database = merge(local.oltp_endpoints, {
        name = local.network_inventory_planning_db_name
        user = local.network_inventory_planning_db_user
      })
      analytics_database = {
        name = local.network_inventory_planning_analytics_db_name
        user = local.network_inventory_planning_analytics_db_user
        host = local.postgres_host
        port = local.postgres_port
      }
      secrets = {}
    }

    "network-fulfillment" = {
      deploy = var.deploy_services
      chart = {
        repo_url = "https://github.com/IQVO/network-fulfillment.git"
        path     = "charts/network-fulfillment"
      }
      # Exactly what network-fulfillment.tf hashed before the module: Go
      # sources only. Same follow-up as network-inventory-planning above.
      image = {
        hash_globs = ["**/*.go"]
      }
      frontend = contains(keys(local.frontend_remotes), "network-fulfillment") ? { source_hash = local.frontend_source_hash["network-fulfillment"] } : null
      database = merge(local.oltp_endpoints, {
        name = local.network_fulfillment_db_name
        user = local.network_fulfillment_db_user
      })
      analytics_database = {
        name = local.network_fulfillment_analytics_db_name
        user = local.network_fulfillment_analytics_db_user
        host = local.postgres_host
        port = local.postgres_port
        # Its chart's analytics-secret.yaml reads this one key only.
        secret_keys = ["ANALYTICS_DATABASE_URL"]
      }
      secrets = {}
    }

    # Its image comes from a registry (var.ops_agent_image_repository), not
    # from a local build.
    "warehouse-ops-agent" = {
      deploy = var.deploy_services
      chart = {
        repo_url = "https://github.com/IQVO/warehouse-ops-agent.git"
        path     = "charts/warehouse-ops-agent"
      }
      image              = null
      frontend           = null
      database           = null
      analytics_database = null
      # warehouse-ops-agent-anthropic (ops-agent.tf's header).
      secrets = {
        anthropic = { ANTHROPIC_API_KEY = var.anthropic_api_key }
      }
    }

    # The console shell and the EventCatalog ARE static sites: their one
    # image is built from the repo root and its tag goes to image.tag.
    "warehouse-console" = {
      deploy = var.deploy_frontends
      chart = {
        repo_url = "https://github.com/IQVO/warehouse-console.git"
        path     = "charts/warehouse-console"
      }
      image              = null
      frontend           = var.deploy_frontends ? { source_hash = local.console_source_hash, dir = ".", values_key = "image" } : null
      database           = null
      analytics_database = null
      secrets            = {}
    }

    "ecosystem" = {
      deploy = var.deploy_frontends
      chart = {
        repo_url = "https://github.com/IQVO/ecosystem.git"
        path     = "charts/ecosystem"
      }
      image              = null
      frontend           = var.deploy_frontends ? { source_hash = local.ecosystem_source_hash, dir = ".", values_key = "image" } : null
      database           = null
      analytics_database = null
      secrets            = {}
    }
  }

  applications = merge(local.service_applications, local.other_applications)

  # The chart values, still computed by the root (ADR 0002 phase 3 moves them
  # to value files), kept out of the registry above so that nothing reading
  # the registry (app_db_passwords, which the Postgres release reads) depends
  # on them. Without image tags: the module adds the tags of the images it
  # builds, so these values never depend on the module's outputs.
  application_helm_values = merge(
    { for name in keys(local.services) : name => local.argocd_service_values[name] },
    {
      "network-inventory-planning" = local.argocd_network_inventory_planning_values
      "network-fulfillment"        = local.argocd_network_fulfillment_values
      "warehouse-ops-agent"        = local.argocd_ops_agent_values
      "warehouse-console"          = local.argocd_console_values
      "ecosystem"                  = local.argocd_ecosystem_values
    },
  )

  # The generated OLTP passwords, for the platform's initdb script and
  # PgBouncer userlist: the platform's dependency on the applications, which
  # ADR 0002 phase 4 removes.
  #
  # One LITERAL key per application, never a for expression over
  # module.application: a computed key (module.application[name]) makes the
  # reader depend on the whole module call, image builds and Applications
  # included (`terraform graph` shows the edge to "module.application
  # (close)"), so Postgres would wait for every build. A database-backed
  # application missing here fails the plan: local.service_passwords and the
  # initdb template index this map.
  app_db_passwords = {
    "facility-layout"            = module.application["facility-layout"].db_password
    "fulfillment-execution"      = module.application["fulfillment-execution"].db_password
    "inbound-receiving"          = module.application["inbound-receiving"].db_password
    "inventory-storage"          = module.application["inventory-storage"].db_password
    "labor-performance"          = module.application["labor-performance"].db_password
    "network-fulfillment"        = module.application["network-fulfillment"].db_password
    "network-inventory-planning" = module.application["network-inventory-planning"].db_password
    "order-management"           = module.application["order-management"].db_password
    "process-path-management"    = module.application["process-path-management"].db_password
    "product-master"             = module.application["product-master"].db_password
    "slotting-optimization"      = module.application["slotting-optimization"].db_password
    "warehouse-planning"         = module.application["warehouse-planning"].db_password
    "wes-work-planning"          = module.application["wes-work-planning"].db_password
    "workforce-management"       = module.application["workforce-management"].db_password
  }

}

module "application" {
  source   = "./modules/application"
  for_each = toset(keys(local.applications))

  name   = each.key
  deploy = local.applications[each.key].deploy

  # Resource attributes rather than variables: they carry the ordering the
  # pre-module resources declared with depends_on (namespace before Secrets,
  # ArgoCD before Applications, cluster before image loads).
  apps_namespace   = kubernetes_namespace.apps.metadata[0].name
  argocd_namespace = helm_release.argocd.namespace
  cluster_name     = kind_cluster.warehouse.name

  repos_root  = "${path.module}/../.."
  scripts_dir = "${path.module}/../scripts"

  chart              = local.applications[each.key].chart
  image              = local.applications[each.key].image
  frontend           = local.applications[each.key].frontend
  database           = local.applications[each.key].database
  analytics_database = local.applications[each.key].analytics_database
  secrets            = local.applications[each.key].secrets
  helm_values        = local.application_helm_values[each.key]
}
