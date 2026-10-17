variable "name" {
  description = "The application's name: its repo directory under repos_root, its image name (warehouse/<name>), its Secret prefix (<name>-db) and its ArgoCD Application name."
  type        = string
}

variable "deploy" {
  description = "Build the images and create the Secrets and the ArgoCD Application (the root's var.deploy_services). The generated passwords exist either way, because the platform's initdb script and PgBouncer config consume them."
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
  description = "Helm values for the ArgoCD Application, without image tags: the module sets image.tag and frontend.image.tag from the images it builds. Still computed by the root module in ADR 0002 phase 1; phase 3 replaces them with value files. Never put a credential here: charts read them from the Secrets this module creates."
  type        = any
}

variable "image" {
  description = "Build the API image from <repos_root>/<name> and side-load it into kind. Its tag is local-<first 12 chars of a sha256 over the files matched by hash_globs plus Dockerfile, go.mod and go.sum>. null when the image comes from a registry."
  type = object({
    hash_globs = optional(list(string), ["**/*.go", "migrations/**", "internal/**/migrations/**", "analytics/migrations/**"])
  })
  default = null
}

variable "frontend" {
  description = "Build the Module Federation remote from <repos_root>/<name>/web. source_hash is its 12-character content hash (the root computes it, because it folds in the shared ui-kit's hash)."
  type = object({
    source_hash = string
  })
  default = null
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
  description = "Analytical database (direct connection): a generated password and the <name>-analytics-db Secret with ANALYTICS_DATABASE_URL (projector) and ANALYTICS_READER_DATABASE_URL (reports)."
  type = object({
    name = string
    user = string
    host = string
    port = number
  })
  default = null
}
