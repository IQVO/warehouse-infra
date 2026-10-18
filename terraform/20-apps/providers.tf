# Provider wiring, read from the platform's state rather than from a
# resource in this configuration (ADR 0007 step 2). Same load-bearing shape
# as the root's providers.tf -- see that file's header for why attributes,
# not a kubeconfig path -- except the attributes now come from
# `data.terraform_remote_state.platform` instead of `kind_cluster.warehouse`.
#
# A missing platform state is a plan error here (the data source fails to
# read the file), which is exactly ADR 0007 decision 3's "names the layer to
# apply first": run `terraform apply` in terraform/ before anything in
# terraform/20-apps.

data "terraform_remote_state" "platform" {
  backend = "local"

  config = {
    path = "${path.module}/../10-platform/terraform.tfstate"
  }
}

locals {
  platform = data.terraform_remote_state.platform.outputs.platform
}

provider "kubernetes" {
  host                   = local.platform.cluster_endpoint
  cluster_ca_certificate = local.platform.cluster_ca_certificate
  client_certificate     = local.platform.cluster_client_certificate
  client_key             = local.platform.cluster_client_key
}

provider "helm" {
  kubernetes {
    host                   = local.platform.cluster_endpoint
    cluster_ca_certificate = local.platform.cluster_ca_certificate
    client_certificate     = local.platform.cluster_client_certificate
    client_key             = local.platform.cluster_client_key
  }
}

provider "kubectl" {
  host                   = local.platform.cluster_endpoint
  cluster_ca_certificate = local.platform.cluster_ca_certificate
  client_certificate     = local.platform.cluster_client_certificate
  client_key             = local.platform.cluster_client_key
  load_config_file       = false
  apply_retry_count      = 5
}
