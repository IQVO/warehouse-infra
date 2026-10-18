# ---------------------------------------------------------------------------
# Istio — sidecar mode, installed from the official Helm charts at
# https://istio-release.storage.googleapis.com/charts
#
# Sidecar mode over ambient on purpose: it needs no CNI DaemonSet and no
# ztunnel, which is markedly less fragile inside kind, and namespace-label
# injection (istio-injection=enabled) requires zero application changes.
#
# Ordering is a hard requirement: istio-base installs the CRDs that istiod's
# own manifests reference, so base must land first.
# ---------------------------------------------------------------------------

resource "kubernetes_namespace" "istio_system" {

  metadata {
    name = "istio-system"
    labels = {
      "warehouse.local/tier" = "mesh"
    }
  }
}

resource "helm_release" "istio_base" {
  depends_on = [kubernetes_namespace.istio_system]

  name       = "istio-base"
  repository = "https://istio-release.storage.googleapis.com/charts"
  chart      = "base"
  version    = var.istio_version
  namespace  = kubernetes_namespace.istio_system.metadata[0].name

  timeout = 600
  wait    = true

  values = [yamlencode({
    defaultRevision = "default"
  })]
}

resource "helm_release" "istiod" {
  depends_on = [helm_release.istio_base]

  name       = "istiod"
  repository = "https://istio-release.storage.googleapis.com/charts"
  chart      = "istiod"
  version    = var.istio_version
  namespace  = kubernetes_namespace.istio_system.metadata[0].name

  timeout = 900
  wait    = true

  values = [yamlencode({
    # kind nodes are small; the production-default istiod requests are
    # generous enough to leave the pod Pending on a laptop.
    pilot = {
      resources = {
        requests = { cpu = "100m", memory = "512Mi" }
        limits   = { cpu = "1000m", memory = "1Gi" }
      }
    }
    global = {
      proxy = {
        resources = {
          requests = { cpu = "20m", memory = "64Mi" }
          limits   = { cpu = "500m", memory = "512Mi" }
        }
      }
    }
  })]
}
