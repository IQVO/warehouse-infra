# The cluster layer needs only the kind provider. Every other layer reads the
# cluster's credentials from this layer's `connection` output through
# terraform_remote_state (ADR 0007), so no provider here is configured from a
# resource of the configuration that uses it.
#
# With cluster_provider = existing the provider is still declared but no
# kind_cluster is planned, so it is never called and needs no Docker daemon.
provider "kind" {}

locals {
  # Where the kind provider and `kind export kubeconfig` write the file the
  # scripts use (terraform/00-cluster/kubeconfig, gitignored). The relative
  # form is deliberate: kubeconfig_path forces a new kind_cluster when it
  # changes, and "./kubeconfig" is the value every existing state holds, so
  # the layout change replaces nothing.
  kubeconfig_path = "${path.module}/kubeconfig"

  is_kind  = var.cluster_provider == "kind"
  existing = var.cluster_provider == "existing"

  # ---- cluster_provider = existing: credentials read from the kubeconfig ----
  # try(): in kind mode there may be no kubeconfig_file at all.
  # Round-tripped through JSON so the two branches have one type.
  kubeconfig = jsondecode(local.existing ? jsonencode(yamldecode(file(pathexpand(var.kubeconfig_file)))) : "{}")

  kc_context = one([for c in try(local.kubeconfig.contexts, []) : c.context if c.name == var.kube_context])
  kc_cluster = one([for c in try(local.kubeconfig.clusters, []) : c.cluster if c.name == try(local.kc_context.cluster, "")])
  kc_user    = one([for u in try(local.kubeconfig.users, []) : u.user if u.name == try(local.kc_context.user, "")])

  existing_connection = local.existing ? {
    host                   = local.kc_cluster.server
    cluster_ca_certificate = base64decode(local.kc_cluster["certificate-authority-data"])
    client_certificate     = try(base64decode(local.kc_user["client-certificate-data"]), "")
    client_key             = try(base64decode(local.kc_user["client-key-data"]), "")
    token                  = try(local.kc_user.token, "")
  } : null

  kube_context = local.existing ? var.kube_context : "kind-${var.cluster_name}"
}
