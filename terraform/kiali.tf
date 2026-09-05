# ---------------------------------------------------------------------------
# Kiali — service-mesh observability for Istio: live topology graph, traffic
# health, and per-workload/service/app drill-down, reading Istio's own
# telemetry back out of the SAME Prometheus this cluster already runs (see
# observability.tf) rather than standing up a second metrics backend.
#
# Chart `kiali/kiali-server` from https://kiali.org/helm-charts, installed
# into istio-system alongside istiod (the conventional placement for a mesh
# add-on, and the namespace already carries the "mesh" tier label).
#
# Gated on BOTH deploy_kiali and deploy_observability: Kiali is not useful
# without a Prometheus to read from, and `external_services.prometheus.url`
# below hard-codes the in-cluster DNS name from observability.tf.
#
# auth.strategy = "anonymous": there is no IdP in this cluster (same call
# this fleet makes everywhere else -- see the MCP servers' static-bearer,
# no-OAuth decision) and Kiali is only ever reachable from localhost via the
# NodePort in exposure.tf, never from outside the laptop. LOCAL DEV ONLY.
# ---------------------------------------------------------------------------

resource "helm_release" "kiali" {
  count = var.deploy_kiali && var.deploy_observability ? 1 : 0

  depends_on = [
    helm_release.istiod,
    helm_release.prometheus,
  ]

  name       = "kiali"
  repository = "https://kiali.org/helm-charts"
  chart      = "kiali-server"
  version    = var.kiali_chart_version
  namespace  = kubernetes_namespace.istio_system.metadata[0].name

  timeout = 600
  wait    = true

  values = [yamlencode({
    auth = {
      strategy = "anonymous"
    }

    deployment = {
      # Only istiod's own default in this cluster is "default"; explicit here
      # so a chart bump cannot silently pick a different Istio revision.
      cluster_wide_access = true

      resources = {
        requests = { cpu = "50m", memory = "128Mi" }
        limits   = { memory = "256Mi" }
      }
    }

    external_services = {
      istio = {
        root_namespace = kubernetes_namespace.istio_system.metadata[0].name
      }
      prometheus = {
        url = "http://${local.observability_dns.prometheus}:${local.prometheus_port}"
      }
      grafana = {
        enabled = true
        # In-cluster URL Kiali uses server-side to check Grafana's health and
        # build "View in Grafana" links; the browser separately hits Grafana
        # through its own NodePort (exposure.tf), so this does not need to be
        # localhost-reachable.
        internal_url = "http://${local.observability_dns.grafana}:${local.grafana_port}"
        external_url = "http://localhost:${var.grafana_host_port}"
      }
      tracing = {
        enabled      = true
        provider     = "jaeger"
        internal_url = "http://${local.observability_dns.jaeger}:${local.jaeger_query_port}"
        external_url = "http://localhost:${var.jaeger_host_port}"
        use_grpc     = false
      }
    }
  })]
}
