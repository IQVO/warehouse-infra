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
      "istio-injection"      = "enabled"
      "warehouse.local/tier" = "application"
    }
  }
}
