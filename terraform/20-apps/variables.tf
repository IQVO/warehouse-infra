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
