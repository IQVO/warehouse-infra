terraform {
  required_version = ">= 1.5.0"

  # Provider configurations are inherited from the root module (no provider
  # blocks here, so the module stays callable with for_each). Versions are
  # pinned once, in the root's versions.tf.
  required_providers {
    kubernetes = {
      source = "hashicorp/kubernetes"
    }
    kubectl = {
      source = "gavinbunney/kubectl"
    }
    null = {
      source = "hashicorp/null"
    }
    random = {
      source = "hashicorp/random"
    }
  }
}
