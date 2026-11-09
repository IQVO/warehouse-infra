# ---------------------------------------------------------------------------
# k3s ships Traefik as a LoadBalancer Service: its svclb DaemonSet publishes
# :80 and :443 on every node's LAN address. This fleet routes nothing through
# Traefik (Kong and the Nginx gateway are the two edges) and every REST/MCP
# endpoint is unauthenticated, so the listener is pure exposure -- and
# scripts/test-exposure-policy.sh rightly fails on it.
#
# The change goes through k3s's own extension point, a HelmChartConfig object in
# kube-system (a Kubernetes API object, not a file on the machine): the bundled
# Traefik chart is re-rendered with a ClusterIP Service and the svclb pods go
# away, which also gives back pod slots on a 110-pod node (ADR 0011).
#
# `service.spec.type`, not `service.type`: this chart version (traefik 41.x)
# ignores the latter and silently keeps the LoadBalancer.
# ---------------------------------------------------------------------------
resource "kubectl_manifest" "traefik_cluster_ip" {
  yaml_body = yamlencode({
    apiVersion = "helm.cattle.io/v1"
    kind       = "HelmChartConfig"
    metadata = {
      name      = "traefik"
      namespace = "kube-system"
    }
    spec = {
      valuesContent = yamlencode({
        service = { spec = { type = "ClusterIP" } }
      })
    }
  })
}
