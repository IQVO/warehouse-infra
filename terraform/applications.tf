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
#   - a database-backed context with the shared database naming goes in
#     local.services (locals.tf) and is picked up below automatically;
#   - anything else gets its own entry in local.other_applications;
#   - either way its configuration is helm-values/<name>.yaml plus
#     helm-values/kind-resources/<name>.yaml (ADR 0002 D2), which ArgoCD
#     reads from this repo's develop: the plan fails while either is
#     missing.
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
      # The <name>-analytics-db Secret the chart reads through
      # analytics.database.existingSecret (analytics.existingSecret for
      # slotting-optimization), set in its helm-values file.
      analytics_database = contains(local.analytics_services, name) ? {
        name        = local.analytics_db_info[name].db
        user        = local.analytics_db_info[name].user
        host        = local.postgres_host
        port        = local.postgres_port
        secret_keys = ["ANALYTICS_DATABASE_URL", "ANALYTICS_READER_DATABASE_URL"]
      } : null
      secrets = {}
    }
  }

  other_applications = {
    "network-inventory-planning" = {
      deploy = var.deploy_services
      chart = {
        repo_url = "https://github.com/IQVO/network-inventory-planning.git"
        path     = "charts/network-inventory-planning"
      }
      # The module's default hash covers both migration trees its Dockerfile
      # copies into the image (internal/**/migrations, analytics/migrations).
      image    = {}
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
      # The module's default hash covers migrations/ (OLTP, plus
      # migrations/analytics), which its Dockerfile copies into the image.
      image    = {}
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

  # Values Terraform itself owns, for the Application's valuesObject. Every
  # application's configuration lives in its value files (helm-values/,
  # ADR 0002 D2); the only exception is the ops agent's image, chosen per
  # machine through terraform.tfvars (ops-agent.tf). The module adds the
  # tags of the images it builds.
  application_helm_values = {
    "warehouse-ops-agent" = local.ops_agent_terraform_values
  }

  # Where ArgoCD reads the value files: this repo's GitHub develop (public,
  # like every chart repo). A values change deploys on merge, through an
  # ArgoCD sync, with no terraform apply.
  application_values_source = {
    repo_url        = "https://github.com/IQVO/warehouse-infra.git"
    target_revision = "develop"
    dir             = "helm-values"
    local_dir       = "${path.module}/../helm-values"
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

  # Where the module creates the application's role and database (ADR 0005).
  postgres = local.postgres

  # The Application is created after the Gateway API CRDs and the Gateway
  # (ADR 0006).
  platform_ready = local.gateway_ready

  repos_root  = "${path.module}/../.."
  scripts_dir = "${path.module}/../scripts"

  chart              = local.applications[each.key].chart
  image              = local.applications[each.key].image
  frontend           = local.applications[each.key].frontend
  database           = local.applications[each.key].database
  analytics_database = local.applications[each.key].analytics_database
  secrets            = local.applications[each.key].secrets
  values             = local.application_values_source
  helm_values        = lookup(local.application_helm_values, each.key, {})
}
