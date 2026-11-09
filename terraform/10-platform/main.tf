# ---------------------------------------------------------------------------
# Namespaces. The cluster itself is 00-cluster (ADR 0007): this layer starts
# from the credentials that layer publishes.
# ---------------------------------------------------------------------------

resource "kubernetes_namespace" "data" {
  metadata {
    name = var.data_namespace
    labels = {
      "warehouse.local/tier" = "data"
    }
  }
}

resource "kubernetes_namespace" "kong" {
  metadata {
    name = var.kong_namespace
    labels = {
      "warehouse.local/tier" = "gateway"
    }
  }
}

# Sidecar injection is OFF (ADR 0011): every sidecar opens inotify instances on
# the node, and a stock k3s node (fs.inotify.max_user_instances=128, a host
# setting this repo may not change) runs out around 50 pods; the sidecars then
# crash with "couldn't initialize inotify: too many open files". It also removes
# ~100 containers from a node that is capped at 110 pods. The mesh is permissive
# (no PeerAuthentication/AuthorizationPolicy), so the applications run the same
# without it; Kiali just has no traffic to draw.
resource "kubernetes_namespace" "apps" {
  depends_on = [helm_release.istiod]

  metadata {
    name = var.apps_namespace
    labels = {
      "istio-injection"      = "disabled"
      "warehouse.local/tier" = "application"
    }
  }
}

# ---------------------------------------------------------------------------
# ghcr.io pull secret (20-apps, ADR 0011).
#
# The application charts take `imagePullSecrets`; 20-apps puts this Secret's
# name there. Created only when a token is supplied: a public package needs
# none. The credential lives in this layer's state, like every other generated
# secret of the platform, and never in a file of the repository.
# ---------------------------------------------------------------------------
locals {
  image_pull_secret = var.ghcr_token != "" ? "ghcr-pull" : ""
}

resource "kubernetes_secret" "ghcr_pull" {
  count = var.ghcr_token != "" ? 1 : 0

  metadata {
    name      = local.image_pull_secret
    namespace = kubernetes_namespace.apps.metadata[0].name
  }

  type = "kubernetes.io/dockerconfigjson"

  data = {
    ".dockerconfigjson" = jsonencode({
      auths = {
        "ghcr.io" = {
          username = var.ghcr_username
          password = var.ghcr_token
          auth     = base64encode("${var.ghcr_username}:${var.ghcr_token}")
        }
      }
    })
  }
}
