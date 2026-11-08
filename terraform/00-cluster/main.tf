# ---------------------------------------------------------------------------
# The cluster layer creates nothing.
#
# The cluster is an existing k3s cluster that belongs to someone else (ADR
# 0011): this layer reads the credentials of kube_context out of
# kubeconfig_file and publishes them as `connection` (providers.tf,
# outputs.tf). kind is banned: there is no cluster resource, no Docker daemon
# and no node-side configuration here.
# ---------------------------------------------------------------------------

# Fail the plan, naming the variable, when the context cannot be turned into
# credentials -- instead of a "null value" error from deep inside a local.
check "existing_cluster_credentials" {
  assert {
    condition = (
      var.kube_context != "" &&
      local.kc_context != null &&
      local.kc_cluster != null &&
      local.kc_user != null &&
      try(local.kc_cluster["certificate-authority-data"], "") != "" &&
      (try(local.kc_user["client-certificate-data"], "") != "" || try(local.kc_user.token, "") != "")
    )
    error_message = "kube_context \"${var.kube_context}\" must name a context of ${var.kubeconfig_file} whose cluster carries certificate-authority-data and whose user carries client-certificate-data/client-key-data or a token (exec plugins are not supported)."
  }
}
