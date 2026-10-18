# Provider wiring for the platform layer.
#
# The cluster is another layer (00-cluster, ADR 0007). Its credentials arrive
# through terraform_remote_state, a data source Terraform reads at plan time,
# so the providers below are configured from data and never from a resource of
# this configuration. That is the arrangement the Kubernetes provider's
# documentation asks for: the cluster and the resources inside it do not share
# a state. A missing cluster state is a plan error that names the layer to
# apply first.

data "terraform_remote_state" "cluster" {
  backend = "local"

  config = {
    path = "${path.module}/../00-cluster/terraform.tfstate"
  }
}

locals {
  cluster    = data.terraform_remote_state.cluster.outputs.cluster
  connection = data.terraform_remote_state.cluster.outputs.connection
}

provider "kubernetes" {
  host                   = local.connection.host
  cluster_ca_certificate = local.connection.cluster_ca_certificate
  client_certificate     = local.connection.client_certificate
  client_key             = local.connection.client_key
}

provider "helm" {
  kubernetes {
    host                   = local.connection.host
    cluster_ca_certificate = local.connection.cluster_ca_certificate
    client_certificate     = local.connection.client_certificate
    client_key             = local.connection.client_key
  }
}

# Used for the Gateway API objects (gateway-api.tf). `kubectl_manifest`
# applies with kubectl-apply semantics and needs a CRD to exist only by apply
# time, where the native `kubernetes_manifest` resource validates against the
# live OpenAPI schema at PLAN time.
provider "kubectl" {
  host                   = local.connection.host
  cluster_ca_certificate = local.connection.cluster_ca_certificate
  client_certificate     = local.connection.client_certificate
  client_key             = local.connection.client_key
  load_config_file       = false

  # A CRD is created and a custom resource of it applied in the same run
  # (gateway-api.tf); retry the apply while the API server starts serving it.
  apply_retry_count = 5
}
