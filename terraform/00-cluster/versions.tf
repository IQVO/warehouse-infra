# Provider + Terraform version pins for the cluster layer.
terraform {
  required_version = ">= 1.5.0"

  required_providers {
    # Creates the kind cluster. Chosen over a null_resource/local-exec wrapper
    # because it exposes the cluster's credentials as first-class attributes
    # and participates in `terraform destroy` properly.
    kind = {
      source  = "tehcyx/kind"
      version = "~> 0.9.0"
    }

    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
    }
  }
}
