# ---------------------------------------------------------------------------
# metrics-server — the resource-metrics API (metrics.k8s.io) that the
# Horizontal Pod Autoscaler needs to read CPU/memory utilization.
#
# Chart: kubernetes-sigs/metrics-server, from the project's own chart repo
# https://kubernetes-sigs.github.io/metrics-server/ (mirrors this repo's
# existing pattern of pulling platform charts from each project's own
# canonical source rather than a third-party OCI mirror -- see istio.tf,
# kong.tf, observability.tf's jaeger/prometheus/grafana releases).
#
# Every one of the nine bounded-context service charts in this fleet already
# ships an HPA (`autoscaling/v2` HorizontalPodAutoscaler) template targeting
# CPU/memory utilization -- but with no metrics.k8s.io API aggregated into
# the API server, `kubectl get hpa` shows every one of them stuck at
# `<unknown>` and `kubectl describe hpa` reports
# `FailedGetResourceMetrics: unable to fetch metrics from resource metrics
# API`. This resource is what makes those already-shipped HPA templates
# actually function, with no chart changes needed anywhere else.
#
# --kubelet-insecure-tls is a genuine, well-documented kind-specific need,
# not a blanket "just disable TLS" shortcut: kind's kubelet serving
# certificates are self-signed per-node at cluster boot, not signed by any
# CA metrics-server is configured to trust, so without this flag the
# scraper's first request fails with
# `x509: certificate signed by unknown authority` and every node reports
# `cannot get metrics` (confirmed as the standard failure mode documented by
# the metrics-server project itself and reproduced across all kind versions,
# not something particular to this cluster's config). Setting
# apiService.insecureSkipTLSVerify=true (the chart's own default, kept
# explicit here so a future chart bump can't silently change it) only
# affects TLS verification between kube-apiserver and the metrics-server
# aggregated API service; --kubelet-insecure-tls (passed via `args`, which
# the chart appends to its own `defaultArgs` rather than replacing them --
# verified by reading templates/deployment.yaml) is the separate flag that
# turns off TLS verification from metrics-server to each kubelet, which is
# the actual kind cert-authority mismatch. On any cluster whose kubelets DO
# have properly CA-signed serving certs (a real, non-kind cluster), this
# flag should NOT be set -- it is scoped here specifically for kind.
# ---------------------------------------------------------------------------

resource "helm_release" "metrics_server" {
  count = var.deploy_metrics_server ? 1 : 0

  depends_on = [null_resource.kubeconfig]

  name       = "metrics-server"
  repository = "https://kubernetes-sigs.github.io/metrics-server/"
  chart      = "metrics-server"
  version    = var.metrics_server_chart_version
  namespace  = "kube-system"

  timeout = 300
  wait    = true

  values = [yamlencode({
    apiService = {
      # Chart default; kept explicit so a future chart bump can't silently
      # change the kube-apiserver <-> metrics-server aggregation TLS
      # posture out from under this cluster.
      insecureSkipTLSVerify = true
    }

    # See the file header: this is the kind-specific kubelet-serving-cert
    # workaround, appended to (not replacing) the chart's own defaultArgs.
    args = [
      "--kubelet-insecure-tls",
    ]

    resources = {
      requests = { cpu = "50m", memory = "64Mi" }
      limits   = { cpu = "250m", memory = "256Mi" }
    }
  })]
}
