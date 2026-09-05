# ---------------------------------------------------------------------------
# Localhost exposure for observability + Kiali UIs.
#
# Each upstream chart's own Service stays ClusterIP (its defaults, untouched)
# because their `service.*` value schemas differ too much to reliably force
# a deterministic nodePort through every chart's own values (Jaeger's chart
# does not expose a settable nodePort at all; Prometheus/Grafana's schemas
# differ across chart versions). Instead, each UI gets ONE extra
# Terraform-owned Service of type NodePort here, selecting the exact same
# pod labels the chart's own Service already uses. kind's extraPortMappings
# (main.tf) then publish that NodePort on a host port, so every UI is
# reachable at a fixed http://localhost:<port>/ the same way Kong already is
# -- no `kubectl port-forward` process to keep alive across terminal
# restarts or laptop sleep.
# ---------------------------------------------------------------------------

resource "kubernetes_service" "grafana_nodeport" {
  count = var.deploy_observability ? 1 : 0

  depends_on = [helm_release.grafana]

  metadata {
    name      = "grafana-nodeport"
    namespace = var.observability_namespace
    labels = {
      "warehouse.local/tier"     = "observability"
      "warehouse.local/exposure" = "localhost"
    }
  }

  spec {
    type = "NodePort"
    selector = {
      "app.kubernetes.io/name"     = "grafana"
      "app.kubernetes.io/instance" = local.grafana_release
    }
    port {
      name        = "http"
      port        = local.grafana_port
      target_port = 3000
      node_port   = var.grafana_node_port
      protocol    = "TCP"
    }
  }
}

resource "kubernetes_service" "jaeger_nodeport" {
  count = var.deploy_observability ? 1 : 0

  depends_on = [helm_release.jaeger]

  metadata {
    name      = "jaeger-nodeport"
    namespace = var.observability_namespace
    labels = {
      "warehouse.local/tier"     = "observability"
      "warehouse.local/exposure" = "localhost"
    }
  }

  spec {
    type = "NodePort"
    selector = {
      "app.kubernetes.io/name"      = "jaeger"
      "app.kubernetes.io/instance"  = local.jaeger_release
      "app.kubernetes.io/component" = "all-in-one"
    }
    port {
      name        = "http-query"
      port        = local.jaeger_query_port
      target_port = local.jaeger_query_port
      node_port   = var.jaeger_node_port
      protocol    = "TCP"
    }
  }
}

resource "kubernetes_service" "prometheus_nodeport" {
  count = var.deploy_observability ? 1 : 0

  depends_on = [helm_release.prometheus]

  metadata {
    name      = "prometheus-nodeport"
    namespace = var.observability_namespace
    labels = {
      "warehouse.local/tier"     = "observability"
      "warehouse.local/exposure" = "localhost"
    }
  }

  spec {
    type = "NodePort"
    selector = {
      "app.kubernetes.io/name"      = "prometheus"
      "app.kubernetes.io/instance"  = local.prometheus_release
      "app.kubernetes.io/component" = "server"
    }
    port {
      name        = "http"
      port        = local.prometheus_port
      target_port = local.prometheus_port
      node_port   = var.prometheus_node_port
      protocol    = "TCP"
    }
  }
}

resource "kubernetes_service" "kiali_nodeport" {
  count = var.deploy_kiali && var.deploy_observability ? 1 : 0

  depends_on = [helm_release.kiali]

  metadata {
    name      = "kiali-nodeport"
    namespace = kubernetes_namespace.istio_system.metadata[0].name
    labels = {
      "warehouse.local/tier"     = "mesh"
      "warehouse.local/exposure" = "localhost"
    }
  }

  spec {
    type = "NodePort"
    selector = {
      "app.kubernetes.io/name"     = "kiali"
      "app.kubernetes.io/instance" = "kiali"
    }
    port {
      name        = "http"
      port        = local.kiali_port
      target_port = local.kiali_port
      node_port   = var.kiali_node_port
      protocol    = "TCP"
    }
  }
}
