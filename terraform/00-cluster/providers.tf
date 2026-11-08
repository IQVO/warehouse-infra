# The cluster layer reads the credentials of an existing cluster from a kubeconfig.
# Every other layer reads them from this layer's `connection` output through
# terraform_remote_state (ADR 0007), so no provider here is configured from a
# resource of the configuration that uses it. This layer needs no provider.

locals {
  # Round-tripped through JSON so every branch has one type.
  kubeconfig = jsondecode(jsonencode(yamldecode(file(pathexpand(var.kubeconfig_file)))))

  kc_context = one([for c in try(local.kubeconfig.contexts, []) : c.context if c.name == var.kube_context])
  kc_cluster = one([for c in try(local.kubeconfig.clusters, []) : c.cluster if c.name == try(local.kc_context.cluster, "")])
  kc_user    = one([for u in try(local.kubeconfig.users, []) : u.user if u.name == try(local.kc_context.user, "")])

  connection = {
    host                   = local.kc_cluster.server
    cluster_ca_certificate = base64decode(local.kc_cluster["certificate-authority-data"])
    client_certificate     = try(base64decode(local.kc_user["client-certificate-data"]), "")
    client_key             = try(base64decode(local.kc_user["client-key-data"]), "")
    token                  = try(local.kc_user.token, "")
  }
}
