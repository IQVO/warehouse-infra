# The cluster layer needs only the kind provider. Every other layer reads the
# cluster's credentials from this layer's `connection` output through
# terraform_remote_state (ADR 0007), so no provider here is configured from a
# resource of the configuration that uses it.
provider "kind" {}

locals {
  # Where the kind provider and `kind export kubeconfig` write the file the
  # scripts use (terraform/00-cluster/kubeconfig, gitignored). The relative
  # form is deliberate: kubeconfig_path forces a new kind_cluster when it
  # changes, and "./kubeconfig" is the value every existing state holds, so
  # the layout change replaces nothing.
  kubeconfig_path = "${path.module}/kubeconfig"
  kube_context    = "kind-${var.cluster_name}"
}
