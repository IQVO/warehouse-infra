output "image_tag" {
  description = "Content-derived tag of the API image (local-<hash12>), or null when var.image is null."
  value       = local.image_tag
}

output "frontend_image_tag" {
  description = "Content-derived tag of the frontend image, or null when var.frontend is null."
  value       = local.frontend_image_tag
}

output "db_password" {
  description = "Generated OLTP role password (null without var.database). Read by the root's sensitive database_urls output only; the platform no longer depends on it (ADR 0005)."
  value       = local.db_password
  sensitive   = true
}

output "analytics_db_password" {
  description = "Generated analytics role password (null without var.analytics_database). Read by the root's sensitive analytics_database_urls output only."
  value       = local.analytics_db_password
  sensitive   = true
}
