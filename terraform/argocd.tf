# ---------------------------------------------------------------------------
# ArgoCD: the GitOps control plane for the fleet's bounded-context service
# charts (see argocd-apps.tf for the ApplicationSet that actually deploys
# them). This file only bootstraps ArgoCD itself.
#
# Deliberately NOT istio-injection=enabled -- ArgoCD talks to the Kubernetes
# API and to each service repo's Git remote over the internet; it has no
# reason to be in the product mesh, mirroring how the `kong` namespace is
# also left un-injected.
#
# Auth is disabled (helm-values/argocd.yaml: configs.params."server.disable
# .auth") and there is no Ingress -- both explicit, user-approved departures
# documented in that values file's header comment. Local access is via
# `kubectl port-forward svc/argocd-server -n argocd 8080:443`.
# ---------------------------------------------------------------------------

resource "kubernetes_namespace" "argocd" {
  metadata {
    name = "argocd"
  }

  depends_on = [kind_cluster.warehouse]
}

resource "helm_release" "argocd" {
  name       = "argocd"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  version    = "7.7.11"
  namespace  = kubernetes_namespace.argocd.metadata[0].name

  timeout = 600
  wait    = true

  values = [file("${path.module}/../helm-values/argocd.yaml")]

  depends_on = [kubernetes_namespace.argocd]
}
