output "image_tag" {
  description = "Content-derived tag of the API image (local-<hash12>), or null when var.image is null."
  value       = local.image_tag
}

output "frontend_image_tag" {
  description = "Content-derived tag of the frontend image, or null when var.frontend is null."
  value       = local.frontend_image_tag
}

output "db_password" {
  description = "Generated OLTP role password (null without var.database)."
  value       = local.db_password
  sensitive   = true
}

output "analytics_db_password" {
  description = "Generated analytics role password (null without var.analytics_database)."
  value       = local.analytics_db_password
  sensitive   = true
}

output "passwords" {
  description = "Both generated passwords, { db, analytics_db } (each null when absent). The platform's initdb script and PgBouncer userlist read them through the root's local.app_passwords until ADR 0002 phase 4."
  value = {
    db           = local.db_password
    analytics_db = local.analytics_db_password
  }
  sensitive = true
}
