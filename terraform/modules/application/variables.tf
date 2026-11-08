variable "name" {
  description = "The application's name: its image name (<registry prefix>/<name>), its Secret prefix (<name>-db) and its ArgoCD Application name."
  type        = string
}

variable "deploy" {
  description = "Create the Secrets and the ArgoCD Application (the root passes var.deploy_services, or var.deploy_frontends for the static sites). The generated passwords exist either way, because the platform's initdb script and PgBouncer config consume them."
  type        = bool
  default     = true
}

variable "apps_namespace" {
  description = "Namespace the application runs in. Pass the namespace resource's attribute (not the variable) so the Secrets are ordered after the namespace exists."
  type        = string
}

variable "argocd_namespace" {
  description = "Namespace of the ArgoCD install. Pass an attribute of the ArgoCD helm_release so the Application is ordered after ArgoCD's CRDs exist."
  type        = string
}

variable "registry" {
  description = <<-EOT
    Required (ADR 0011): nothing is built or loaded here -- kind is banned. The
    images already sit in a registry (built by the publish-images workflow) and
    the chart is pointed at them:
      prefix        <prefix>/<name> and <prefix>/<name>-frontend
      image_tag     tag of <prefix>/<name>           (required when var.image is set)
      frontend_tag  tag of <prefix>/<name>-frontend  (required when var.frontend is set)
      pull_secret   name of a dockerconfigjson Secret in apps_namespace, "" for none
  EOT
  type = object({
    prefix       = string
    image_tag    = optional(string)
    frontend_tag = optional(string)
    pull_secret  = optional(string, "")
  })
}

variable "chart" {
  description = "Where ArgoCD reads the application's Helm chart."
  type = object({
    repo_url        = string
    path            = string
    target_revision = optional(string, "develop")
  })
}

variable "values" {
  description = "Where ArgoCD reads the application's value files (ADR 0002 D2): repo_url/target_revision of this repo, dir inside it, and local_dir, the same directory on disk, which the plan checks so a missing file fails here rather than in ArgoCD."
  type = object({
    repo_url        = string
    target_revision = optional(string, "develop")
    dir             = optional(string, "helm-values")
    local_dir       = string
  })
}

variable "helm_values" {
  description = "Values Terraform itself owns, placed in the Application's valuesObject (which wins over the value files). Empty for almost every application: configuration belongs in the value files. The module adds image.tag and frontend.image.tag from the lock file. Never put a credential here: charts read credentials from the Secrets this module creates."
  type        = any
  default     = {}
}

variable "image" {
  description = "Set (to {}) when the application has an API image: the chart gets image.repository and image.tag from var.registry. null when the application has no image of its own."
  type        = object({})
  default     = null
}

variable "frontend" {
  description = <<-EOT
    Set when the application has a frontend image, <registry prefix>/<name>-frontend,
    tagged var.registry.frontend_tag. values_key says which chart value receives
    the tag: "frontend" (frontend.image.tag, a Module Federation remote next to
    the API) or "image" (image.tag, an application that IS the static site: the
    console shell, the EventCatalog).
  EOT
  type = object({
    values_key = optional(string, "frontend")
  })
  default = null

  validation {
    condition     = var.frontend == null || contains(["frontend", "image"], try(var.frontend.values_key, ""))
    error_message = "frontend.values_key must be \"frontend\" or \"image\"."
  }
}

variable "secrets" {
  description = "Additional Secrets the chart reads, created as <name>-<key> with the given data (e.g. an external API key supplied as a sensitive Terraform variable). The data values may be sensitive; the map itself must not be, because its keys drive for_each."
  type        = map(map(string))
  default     = {}
}

variable "database" {
  description = "OLTP database: a generated password and the <name>-db Secret with DATABASE_URL (pooled, through PgBouncer) and MIGRATIONS_DATABASE_URL (direct, for golang-migrate's session advisory lock)."
  type = object({
    name        = string
    user        = string
    pooled_host = string
    pooled_port = number
    direct_host = string
    direct_port = number
  })
  default = null
}

variable "analytics_database" {
  description = "Analytical database (direct connection): a generated password and the <name>-analytics-db Secret holding the DSN under each of secret_keys (default: ANALYTICS_DATABASE_URL for the projector and ANALYTICS_READER_DATABASE_URL for the reports reader)."
  type = object({
    name        = string
    user        = string
    host        = string
    port        = number
    secret_keys = optional(list(string), ["ANALYTICS_DATABASE_URL", "ANALYTICS_READER_DATABASE_URL"])
  })
  default = null
}

variable "postgres" {
  description = "How to reach the platform's Postgres (ADR 0005): host, port, namespace, the superuser Secret and the psql image. Required when database or analytics_database is set: the module creates the role and the database through a Job and waits for it before it creates the Application."
  type = object({
    host              = string
    port              = number
    namespace         = string
    admin_secret_name = string
    admin_secret_key  = string
    image             = string
  })
  default = null
}

variable "platform_ready" {
  description = "Any value that exists only once the platform objects the chart's manifests need (the Gateway API CRDs and the Gateway) are in the cluster. The Application is created after it, so ArgoCD never syncs a route before its CRD."
  type        = string
  default     = null
}
