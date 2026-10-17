variable "name" {
  description = "The application's name: its repo directory under repos_root, its image name (warehouse/<name>), its Secret prefix (<name>-db) and its ArgoCD Application name."
  type        = string
}

variable "deploy" {
  description = "Build the API image and create the Secrets and the ArgoCD Application (the root passes var.deploy_services, or var.deploy_frontends for the static sites). The generated passwords exist either way, because the platform's initdb script and PgBouncer config consume them."
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

variable "cluster_name" {
  description = "kind cluster the images are side-loaded into. Pass the kind_cluster resource's attribute so builds are ordered after the cluster exists."
  type        = string
}

variable "repos_root" {
  description = "Directory that holds the sibling repo checkouts (the root passes \"$${path.module}/../..\"). Images are built from <repos_root>/<name>."
  type        = string
}

variable "scripts_dir" {
  description = "warehouse-infra's scripts/ directory, holding build-and-load.sh and build-and-load-frontend.sh."
  type        = string
}

variable "chart" {
  description = "Where ArgoCD reads the application's Helm chart."
  type = object({
    repo_url        = string
    path            = string
    target_revision = optional(string, "develop")
  })
}

variable "helm_values" {
  description = "Helm values for the ArgoCD Application, without image tags: the module sets image.tag and frontend.image.tag from the images it builds. Still computed by the root module; ADR 0002 phase 3 replaces them with value files. Never put a credential here: charts read them from the Secrets this module creates."
  type        = any
}

variable "image" {
  description = "Build the API image from <repos_root>/<name> and side-load it into kind. Its tag is local-<first 12 chars of a sha256 over the files matched by hash_globs plus Dockerfile, go.mod and go.sum>. null when the image comes from a registry and the values set its repository and tag."
  type = object({
    hash_globs = optional(list(string), ["**/*.go", "migrations/**", "internal/**/migrations/**", "analytics/migrations/**"])
  })
  default = null
}

variable "frontend" {
  description = <<-EOT
    Build a static frontend image, warehouse/<name>-frontend, from
    <repos_root>/<name>/<dir> with scripts/build-and-load-frontend.sh.
    source_hash is its 12-character content hash (the root computes it, because
    it folds in the shared ui-kit's hash). values_key says which chart value
    receives the tag: "frontend" (frontend.image.tag, a Module Federation
    remote next to the API) or "image" (image.tag, an application that IS the
    static site: the console shell, the EventCatalog).
  EOT
  type = object({
    source_hash = string
    dir         = optional(string, "web")
    values_key  = optional(string, "frontend")
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
