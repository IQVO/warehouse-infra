# One application, chosen by the Terraform CLI workspace (ADR 0003 decisions
# 1-3, ADR 0007 step 2). `terraform/applications.tf` is this file's sibling
# in the still-shared root state; the two stay in lockstep by construction
# because both derive from the same `apps.yaml` entry and the same
# `modules/application` -- read that file's header for what each field of an
# entry means and why registering an application only touches apps.yaml plus
# its value files.
#
# TF_WORKSPACE picks the entry, never `terraform workspace select` (ADR 0003
# decision 2): see Makefile's app-plan/app-apply/apps-plan/apps-apply.

locals {
  registry = yamldecode(file("${path.module}/../apps.yaml")).applications

  # Guarded below by the precondition: `default` and any name missing from
  # the registry fail the plan with a message naming the real problem,
  # instead of a bare "key not found" against local.registry.
  app_name = terraform.workspace

  oltp_endpoints = {
    pooled_host = local.platform.pgbouncer_host
    pooled_port = local.platform.pgbouncer_port
    direct_host = local.platform.postgres.host
    direct_port = local.platform.postgres.port
  }

  # Secrets whose values come from Terraform variables, not from Git. Kept
  # here rather than read off the platform state because it is static
  # per-application configuration, not a platform fact -- same reasoning as
  # applications.tf's own copy, which this one must stay identical to until
  # ADR 0007 step 4 gives it one home.
  application_secrets = {
    "warehouse-ops-agent" = {
      anthropic = { ANTHROPIC_API_KEY = var.anthropic_api_key }
    }
  }

  # lookup(), not a bare index: on the "default" workspace (nobody has set
  # TF_WORKSPACE yet) there is no registry entry at all, and every local
  # below must still evaluate to something try() can fall through on so the
  # `check` block below -- not a crash during local evaluation -- is what
  # reports the real problem.
  a = lookup(local.registry, local.app_name, {})

  deploy = try(local.a.deploy_with, "services") == "frontends" ? var.deploy_frontends : var.deploy_services

  chart = {
    repo_url = "https://github.com/${try(local.a.repo_owner, "claudioed")}/${local.app_name}.git"
    path     = "charts/${local.app_name}"
  }

  image = try(local.a.build_image, true) ? {} : null

  frontend = try(local.a.site, false) ? (
    var.deploy_frontends ? {
      source_hash = local.platform.site_source_hash[local.app_name]
      dir         = "."
      values_key  = "image"
    } : null
    ) : (
    contains(keys(local.platform.frontend_source_hash), local.app_name) ? {
      source_hash = local.platform.frontend_source_hash[local.app_name]
    } : null
  )

  database = try(local.a.database, false) ? merge(local.oltp_endpoints, {
    name = replace(local.app_name, "-", "_")
    user = replace(local.app_name, "-", "_")
  }) : null

  analytics_database = try(local.a.analytics, false) != false ? {
    name        = "${replace(local.app_name, "-", "_")}_analytics"
    user        = "${replace(local.app_name, "-", "_")}_analytics"
    host        = local.platform.postgres.host
    port        = local.platform.postgres.port
    secret_keys = try(local.a.analytics.secret_keys, ["ANALYTICS_DATABASE_URL", "ANALYTICS_READER_DATABASE_URL"])
  } : null

  secrets = lookup(local.application_secrets, local.app_name, {})

  # warehouse-ops-agent's image, chosen per machine through terraform.tfvars
  # (ops-agent.tf's header) -- the only application-owned Terraform value
  # (applications.tf's `application_helm_values`); every other application's
  # configuration lives in its value files. Kept identical to ops-agent.tf's
  # `ops_agent_terraform_values` until ADR 0007 step 4 gives it one home.
  ops_agent_image_tag = "latest"

  ops_agent_terraform_values = {
    image = {
      repository = var.ops_agent_image_repository
      tag        = var.ops_agent_image_tag != "" ? var.ops_agent_image_tag : local.ops_agent_image_tag
      pullPolicy = var.ops_agent_image_repository == "ghcr.io/iqvo/warehouse-ops-agent" ? "Always" : "IfNotPresent"
    }
  }

  helm_values = local.app_name == "warehouse-ops-agent" ? local.ops_agent_terraform_values : {}

  values_source = {
    repo_url        = "https://github.com/IQVO/warehouse-infra.git"
    target_revision = "develop"
    dir             = "helm-values"
    local_dir       = "${path.module}/../../helm-values"
  }
}

module "application" {
  source = "../modules/application"

  name   = local.app_name
  deploy = local.deploy

  apps_namespace   = local.platform.apps_namespace
  argocd_namespace = local.platform.argocd_namespace
  cluster_name     = local.platform.cluster_name

  postgres       = local.platform.postgres
  platform_ready = local.platform.gateway_ready

  repos_root  = "${path.module}/../../.."
  scripts_dir = "${path.module}/../../scripts"

  chart              = local.chart
  image              = local.image
  frontend           = local.frontend
  database           = local.database
  analytics_database = local.analytics_database
  secrets            = local.secrets
  values             = local.values_source
  helm_values        = local.helm_values
}
