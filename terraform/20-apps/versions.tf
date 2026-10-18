# Provider + Terraform version pins for the application layer (ADR 0003,
# ADR 0007 step 2). Same pins as the root for every provider an application
# module instance uses; no `kind` provider here -- this layer never touches
# the cluster resource, only reads its credentials from the platform's state.

terraform {
  required_version = ">= 1.5.0"

  backend "local" {
    # No `path`: the default `terraform.tfstate` in this directory, workspace
    # states under `terraform.tfstate.d/<workspace>/terraform.tfstate` (ADR
    # 0003 decision 1). Both are covered by the repo-wide
    # `terraform/*/terraform.tfstate*` / `terraform/*/terraform.tfstate.d/`
    # .gitignore patterns already -- no change needed there.
  }

  required_providers {
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.17"
    }

    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.35"
    }

    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
    }

    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }

    kubectl = {
      source  = "gavinbunney/kubectl"
      version = "~> 1.14"
    }
  }
}
