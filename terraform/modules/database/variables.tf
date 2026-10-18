variable "name" {
  description = "Stem of the Job and Secret names: provision-<name> and <name>-provision. One per role."
  type        = string
}

variable "role" {
  description = "PostgreSQL login role to create, or to bring to the given password."
  type        = string
}

variable "database" {
  description = "Database owned by the role, closed to every other role (REVOKE ALL FROM PUBLIC). null provisions the role only."
  type        = string
  default     = null
}

variable "password" {
  description = "The role's password. The Job sets it on every run, so a changed value reaches Postgres instead of locking the application out."
  type        = string
  sensitive   = true
}

variable "extra_sql" {
  description = "SQL appended to the provisioning script and run in the postgres database as the superuser (the PgBouncer lookup function). Must be idempotent."
  type        = string
  default     = ""
}

variable "postgres" {
  description = "How to reach the platform's Postgres, published by the platform (ADR 0005): where it listens, which Secret holds the superuser password, and the image whose psql runs the script."
  type = object({
    host              = string
    port              = number
    namespace         = string
    admin_secret_name = string
    admin_secret_key  = string
    image             = string
  })
}
