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
# Registering an application: one entry in apps.yaml (ADR 0007; the file's
# header documents the fields) plus its configuration, helm-values/<name>.yaml
# and helm-values/kind-resources/<name>.yaml (ADR 0002 D2), which ArgoCD reads
# from this repo's develop: the plan fails while either is missing. The module
# inputs below are derived from the entry.
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

  # Secrets whose values come from Terraform variables, not from Git.
  # warehouse-ops-agent-anthropic (ops-agent.tf's header).
  application_secrets = {
    "warehouse-ops-agent" = {
      anthropic = { ANTHROPIC_API_KEY = var.anthropic_api_key }
    }
  }

  # Source hashes of the static sites (frontends.tf).
  site_source_hash = {
    "warehouse-console" = local.console_source_hash
    "ecosystem"         = local.ecosystem_source_hash
  }

  # Module inputs, one per registry entry (apps.yaml documents the fields).
  applications = {
    for name, a in local.registry : name => {
      deploy = try(a.deploy_with, "services") == "frontends" ? var.deploy_frontends : var.deploy_services
      chart = {
        repo_url = "https://github.com/${try(a.repo_owner, "claudioed")}/${name}.git"
        path     = "charts/${name}"
      }
      # The module's default hash covers every file the Dockerfile copies in,
      # migrations included. {} builds the image; null means it comes from a
      # registry or is the static site below.
      image = try(a.build_image, true) ? {} : null
      frontend = try(a.site, false) ? (
        var.deploy_frontends ? { source_hash = local.site_source_hash[name], dir = ".", values_key = "image" } : null
        ) : (
        contains(keys(local.frontend_remotes), name) ? { source_hash = local.frontend_source_hash[name] } : null
      )
      database = try(a.database, false) ? merge(local.oltp_endpoints, {
        name = replace(name, "-", "_")
        user = replace(name, "-", "_")
      }) : null
      # The <name>-analytics-db Secret the chart reads through
      # analytics.database.existingSecret (analytics.existingSecret for
      # slotting-optimization), set in its helm-values file.
      analytics_database = try(a.analytics, false) != false ? {
        name        = "${replace(name, "-", "_")}_analytics"
        user        = "${replace(name, "-", "_")}_analytics"
        host        = local.postgres_host
        port        = local.postgres_port
        secret_keys = try(a.analytics.secret_keys, ["ANALYTICS_DATABASE_URL", "ANALYTICS_READER_DATABASE_URL"])
      } : null
      secrets = lookup(local.application_secrets, name, {})
    }
  }

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
