# Variables this layer declares, read from the same
# `terraform/terraform.tfvars` through `-var-file` (ADR 0007 decision 5).
# Only what an application module instance actually needs -- a layer ignores
# variables it does not declare, so e.g. cluster sizing or observability
# toggles stay out of this file on purpose.

variable "deploy_services" {
  description = "Build the API image and create the Secrets and ArgoCD Application for a `service`/`other` registry entry whose deploy_with is services (the default)."
  type        = bool
  default     = true
}

variable "deploy_frontends" {
  description = "Build the API image and create the Secrets and ArgoCD Application for a registry entry whose deploy_with is frontends (the static sites)."
  type        = bool
  default     = true
}

variable "anthropic_api_key" {
  description = "Real Anthropic API key for warehouse-ops-agent's model-backed Reasoner (ANTHROPIC_API_KEY). Empty default so plan/apply succeed without it; see terraform/variables.tf for the full rationale -- unchanged here."
  type        = string
  default     = ""
  sensitive   = true
}

variable "ops_agent_image_repository" {
  description = "Container repository for warehouse-ops-agent. See terraform/variables.tf for the full rationale -- unchanged here."
  type        = string
  default     = "ghcr.io/iqvo/warehouse-ops-agent"
}

variable "ops_agent_image_tag" {
  description = "Image tag for warehouse-ops-agent. Empty string keeps the computed default \"latest\". See terraform/variables.tf for the full rationale -- unchanged here."
  type        = string
  default     = ""
}

# ---------------------------------------------------------------------------
# Where the images come from (ADR 0011)
# ---------------------------------------------------------------------------

variable "state_suffix" {
  description = "Suffix of the platform layer's state file (terraform.tfstate<suffix>); scripts/tf.sh --target sets it. See 10-platform/variables.tf."
  type        = string
  default     = ""
}

variable "image_source" {
  description = <<-EOT
    local     (kind) build every image from the sibling checkouts and side-load
              it into the kind cluster.
    registry  (k3s) build nothing: point every chart at the image already
              published to ghcr.io, at the tag pinned in image_lock_file.
  EOT
  type        = string
  default     = "local"

  validation {
    condition     = contains(["local", "registry"], var.image_source)
    error_message = "image_source must be \"local\" or \"registry\"."
  }
}

variable "image_registry" {
  description = "image_source = registry: the repository prefix of the published images (<prefix>/<app>, <prefix>/<app>-frontend). Written by .github/workflows/publish-images.yml."
  type        = string
  default     = "ghcr.io/iqvo/warehouse-infra"
}

variable "image_lock_file" {
  description = "image_source = registry: YAML pinning the tag of every published image (terraform/targets/k3s.images.yaml). `scripts/k3s-pin-images.sh` rewrites it from a publish-images run."
  type        = string
  default     = "targets/k3s.images.yaml"
}
