# ---------------------------------------------------------------------------
# Provider wiring.
#
# The kubernetes/helm providers are configured from kind_cluster's credential
# ATTRIBUTES rather than from a kubeconfig file path, and that choice is load
# bearing.
#
# A `config_path` pointing at a file the cluster has not written yet is racy:
# Terraform evaluates a provider node early in the graph walk, before the
# resources that depend on it, so on a clean apply the file does not exist yet
# and both providers silently fall back to their default host — producing
# `Post "http://localhost/api/v1/namespaces": EOF` rather than an honest error.
# A `depends_on` on the *resource* does not help, because it is the *provider*
# that needs the ordering.
#
# Referencing kind_cluster.warehouse.* instead creates a real dependency edge
# from the provider node to the cluster resource, so Terraform configures these
# providers only after the cluster exists. That is what makes a single
# `terraform apply` work from clean state.
# ---------------------------------------------------------------------------

locals {
  kubeconfig_path = "${path.module}/kubeconfig"
  kube_context    = "kind-${var.cluster_name}"
}

provider "kind" {}

provider "kubernetes" {
  host                   = kind_cluster.warehouse.endpoint
  cluster_ca_certificate = kind_cluster.warehouse.cluster_ca_certificate
  client_certificate     = kind_cluster.warehouse.client_certificate
  client_key             = kind_cluster.warehouse.client_key
}

provider "helm" {
  kubernetes {
    host                   = kind_cluster.warehouse.endpoint
    cluster_ca_certificate = kind_cluster.warehouse.cluster_ca_certificate
    client_certificate     = kind_cluster.warehouse.client_certificate
    client_key             = kind_cluster.warehouse.client_key
  }
}

# Same attribute-based auth as kubernetes/helm above, same load-bearing
# reason: a config_path provider argument evaluates before kind_cluster
# exists on a clean apply. load_config_file=false stops this provider from
# ALSO trying its own default ~/.kube/config fallback.
#
# Used only for the ArgoCD `Application` CRD instances (argocd-apps.tf) --
# the native `kubernetes_manifest` resource validates a manifest against the
# live cluster's OpenAPI schema at `plan` time, which fails for a CRD
# installed by a `helm_release` in the SAME apply (the CRD doesn't exist yet
# when plan runs). `kubectl_manifest` applies via kubectl-apply semantics
# and only needs the CRD to exist by `apply` time.
provider "kubectl" {
  host                   = kind_cluster.warehouse.endpoint
  cluster_ca_certificate = kind_cluster.warehouse.cluster_ca_certificate
  client_certificate     = kind_cluster.warehouse.client_certificate
  client_key             = kind_cluster.warehouse.client_key
  load_config_file       = false
}
