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

# The ONLY thing required to put the four Go services into the Istio mesh.
# No application code, port, or env-var change is needed: istiod's mutating
# admission webhook rewrites the pod spec at admission time to add the
# istio-proxy sidecar and an init container that installs the iptables
# redirect. The apps keep listening on :8080 and keep serving GET /healthz
# exactly as they do under docker-compose.
resource "kubernetes_namespace" "apps" {
  depends_on = [helm_release.istiod]

  metadata {
    name = var.apps_namespace
    labels = {
      "istio-injection"      = var.istio_injection_enabled ? "enabled" : "disabled"
      "warehouse.local/tier" = "application"
    }
  }
}

# ---------------------------------------------------------------------------
# ghcr.io pull secret (20-apps image_source = registry).
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
