output "image_tag" {
  description = "Content-derived tag of the API image (local-<hash12>), or null when var.image is null."
  value       = local.image_tag
}

output "frontend_image_tag" {
  description = "Content-derived tag of the frontend image, or null when var.frontend is null."
  value       = local.frontend_image_tag
}

output "db_password" {
  description = "Generated OLTP role password. The platform's initdb script and PgBouncer userlist consume it (local.app_db_passwords) until ADR 0002 phase 4."
  value       = local.db_password
  sensitive   = true
}

output "analytics_db_password" {
  description = "Generated analytics role password."
  value       = local.analytics_db_password
  sensitive   = true
}
