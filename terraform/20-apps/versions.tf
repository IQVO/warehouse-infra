# Provider + Terraform version pins for the application layer (ADR 0003,
# ADR 0007 step 2). Same pins as the root for every provider an application
# module instance uses; no `kind` provider here -- this layer never touches
# the cluster resource, only reads its credentials from the platform's state.

terraform {
  required_version = ">= 1.5.0"

  # No `backend` block, on purpose. The default is the local backend, with the
  # same files (`terraform.tfstate.d/<workspace>/terraform.tfstate`, ADR 0003
  # decision 1). An explicit `backend "local" {}` makes every `terraform init`
  # after the first workspace exists ask to migrate those workspaces, which
  # fails without a terminal and blocks `scripts/tf.sh`.
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
