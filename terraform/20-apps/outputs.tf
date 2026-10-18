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
