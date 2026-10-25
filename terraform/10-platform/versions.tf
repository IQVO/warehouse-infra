# Provider + Terraform version pins.
#
# Every version here was resolved and applied for real against Docker
# 29.7.2 / kind 0.32.0 on darwin/arm64 — see README.md "Verified versions".
terraform {
  required_version = ">= 1.5.0"

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

    # Generates per-service database passwords at apply time so no credential
    # is ever committed (see modules/application's random_password.db).
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }

    # Applies ArgoCD `Application` CRD instances (modules/application). Chosen
    # over the native `kubernetes_manifest` resource because that resource
    # validates against the live OpenAPI schema at PLAN time, which fails
    # when the CRD is installed by a helm_release in the same apply.
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = "~> 1.14"
    }
  }
}
