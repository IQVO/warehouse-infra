# ---------------------------------------------------------------------------
# Kong — north-south API gateway, fronting the mesh.
#
# Chart choice: `kong/kong` (not `kong/ingress`).
# `kong/kong` is a single release that runs Kong Gateway and Kong Ingress
# Controller as two containers in one pod, DB-less (`env.database: "off"`),
# with KIC enabled by default. `kong/ingress` is an umbrella that splits the
# controller and the gateway into two subchart releases wired together by
# gatewayDiscovery — more moving parts, more to go wrong on a laptop, and no
# benefit at this scale.
#
# Routing was originally plain Kubernetes `Ingress` objects only. As of the
# Gateway API pilot (gateway-api.tf), KIC's Gateway API reconcilers
# (Gateway, HTTPRoute, GRPCRoute, ReferenceGrant) are ALSO live -- verified
# against the real `kong/kubernetes-ingress-controller:3.5` image bundled by
# this chart version: `--enable-controller-gwapi-httproute` and its Gateway
# API siblings default to `true` in the same binary, alongside the existing
# `--enable-controller-ingress-class-networkingv1`. No values change was
# needed here to turn Gateway API on; ingressController.enabled=true starts
# both reconcilers in the same controller process. This means Ingress and
# HTTPRoute can coexist service-by-service during the migration -- no
# fleet-wide flag day, and a service not yet migrated keeps routing exactly
# as it always has via its existing `Ingress` object (services.tf).
#
# Exposure: proxy Service is NodePort (there is no cloud load balancer here);
# kind's extraPortMappings publish those NodePorts on the host. See main.tf.
# ---------------------------------------------------------------------------

resource "helm_release" "kong" {
  depends_on = [
    kubernetes_namespace.kong,
    helm_release.istiod,
  ]

  name       = "kong"
  repository = "https://charts.konghq.com"
  chart      = "kong"
  version    = var.kong_chart_version
  namespace  = var.kong_namespace

  timeout = 900
  wait    = true

  values = [yamlencode({
    env = {
      database = "off"
    }

    proxy = {
      enabled = true
      type    = "NodePort"
      http = {
        enabled       = true
        servicePort   = 80
        containerPort = 8000
        nodePort      = var.kong_proxy_http_node_port
      }
      tls = {
        enabled       = true
        servicePort   = 443
        containerPort = 8443
        nodePort      = var.kong_proxy_https_node_port
      }
    }

    ingressController = {
      enabled      = true
      ingressClass = "kong"
    }

    # Kong's own metrics are surfaced by the (cluster-scoped) `prometheus`
    # KongClusterPlugin in kong-prometheus.tf, which the chart's `status`
    # listener republishes at :8100/metrics -- see that file's header for
    # why a plugin, not the chart's own `serviceMonitor` block, is the
    # mechanism (this cluster's plain-server Prometheus chart has no CRDs
    # to satisfy a ServiceMonitor with; see observability.tf's header).
    # Annotating the pod directly lets Prometheus's existing chart-default
    # `kubernetes-pods` scrape job pick it up with zero Prometheus-side
    # config: no separate job, no extra Service, no port to punch through
    # the kind host mapping.
    podAnnotations = {
      "prometheus.io/scrape" = "true"
      "prometheus.io/port"   = "8100"
      "prometheus.io/path"   = "/metrics"
    }

    resources = {
      requests = { cpu = "100m", memory = "256Mi" }
      limits   = { cpu = "1000m", memory = "1Gi" }
    }
  })]
}
