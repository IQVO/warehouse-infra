# One application's own outputs, mirroring the subset of
# modules/application's outputs the root's sensitive database_urls /
# analytics_database_urls outputs read today. terraform/applications.tf
# still owns those aggregate outputs until ADR 0007 step 4; this workspace's
# own DSN, if you need it by hand, is `terraform output -raw database_url`.

output "image_tag" {
  description = "Content-derived tag of this application's API image, or null."
  value       = module.application.image_tag
}

output "frontend_image_tag" {
  description = "Content-derived tag of this application's frontend image, or null."
  value       = module.application.frontend_image_tag
}

output "database_url" {
  description = "DATABASE_URL for this application (pooled, through PgBouncer), or null without var.database. LOCAL DEV credentials."
  value = local.database == null ? null : (
    "postgres://${local.database.user}:${module.application.db_password}@${local.platform.pgbouncer_host}:${local.platform.pgbouncer_port}/${local.database.name}?sslmode=disable"
  )
  sensitive = true
}

output "analytics_database_url" {
  description = "ANALYTICS_DATABASE_URL for this application, or null without var.analytics_database. LOCAL DEV credentials."
  value = local.analytics_database == null ? null : (
    "postgres://${local.analytics_database.user}:${module.application.analytics_db_password}@${local.platform.postgres.host}:${local.platform.postgres.port}/${local.analytics_database.name}?sslmode=disable"
  )
  sensitive = true
}

# A workspace that is not an application of terraform/apps.yaml (the default
# one, a typo) would plan to create an application of that name: an ArgoCD
# Application, a role and a database. A `check` block only warns, so this is a
# precondition, which stops the plan. scripts/tf.sh rejects the name earlier.
output "workspace" {
  description = "The application this state belongs to (the Terraform workspace)."
  value       = local.app_name

  precondition {
    # The conditional's predicate is a value only the platform state knows, so
    # `terraform validate` (no state, always the default workspace) leaves the
    # result unknown and skips this; a plan reads the state and evaluates it.
    condition = local.platform.apps_namespace == "" ? true : (
      local.app_name != "default" && contains(keys(local.registry), local.app_name)
    )
    error_message = "terraform.workspace is \"${local.app_name}\". Select a registered application with TF_WORKSPACE=<name> (see terraform/apps.yaml for the list), or use scripts/tf.sh / make app-plan APP=<name> -- never the \"default\" workspace, and never `terraform workspace select` (ADR 0003 decision 2)."
  }
}
