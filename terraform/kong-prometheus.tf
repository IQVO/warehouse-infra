# ---------------------------------------------------------------------------
# Kong Prometheus plugin: makes the API gateway itself a first-class metrics
# source, not just a router in front of instrumented services.
#
# WHY A PLUGIN, NOT THE CHART'S serviceMonitor BLOCK:
# `kong/kong`'s `serviceMonitor.enabled` (see kong.tf's header on the chart
# choice) creates a Prometheus Operator CRD object. This cluster runs the
# plain `prometheus-community/prometheus` chart (server + scrape_configs,
# no Operator, no CRDs -- see observability.tf's header on that decision),
# so a ServiceMonitor here would apply cleanly and be watched by nothing,
# exactly like a ServiceMonitor pointed at any other service in this
# cluster. The `prometheus` KongClusterPlugin is the mechanism that
# actually republishes Kong's internal metrics on the existing `status`
# listener (:8100/metrics, enabled by the chart's default `status.http`
# block -- see kong.tf's `helm show values` reference), and kong.tf's
# `podAnnotations` on that same release make Prometheus's stock
# `kubernetes-pods` scrape job pick it up with no dedicated job or Service.
#
# WHY A CLUSTER-WIDE PLUGIN RATHER THAN PER-ROUTE (same reasoning as
# kong-cors.tf): none of the nine charts' httproute.yaml templates render a
# `konghq.com/plugins` annotation block, so per-route attachment would need
# nine chart PRs. It is also the wrong shape here regardless: metrics
# should exist for every route this gateway ever serves, not be opted into
# route by route, and a KongClusterPlugin labelled global:"true" says
# exactly that once, matching the existing CORS plugin's precedent.
#
# METRICS THIS ADDS (Kong's own `prometheus` plugin, verified against the
# plugin's own documented metric set -- not guessed):
#   kong_http_requests_total{service, route, code, consumer}
#   kong_latency_bucket{type="request"|"kong"|"upstream", service, route}
#   kong_bandwidth_bytes{service, route, direction="ingress"|"egress"}
#   kong_upstream_target_health{upstream, target, address, subsystem}
#   kong_datastore_reachable
#   kong_nginx_http_current_connections / kong_nginx_metric_errors_total
#
# This is the north-south view Kong sits in front of: how much traffic is
# actually reaching each bounded context's Kong Service (its route/service
# name, not its pod's own service_name label), how much of it Kong itself
# rejects or slows down (kong_latency_bucket{type="kong"}) versus the
# upstream being slow (type="upstream"), and per-route/per-service error
# rates BEFORE a request even reaches an instrumented service's own
# `http_server_request_duration_seconds`. The two metric families are
# complementary, not redundant: Kong's view stops at 502/503/timeout to an
# upstream that never got instrumented at all (e.g. a crashed pod), which
# an application-side histogram can never report because the request never
# arrived.
# ---------------------------------------------------------------------------

locals {
  kong_prometheus_plugin_name = "warehouse-prometheus"
}

resource "null_resource" "kong_prometheus_plugin" {
  count = var.deploy_services ? 1 : 0

  depends_on = [
    helm_release.kong,
    kubernetes_namespace.apps,
  ]

  triggers = {
    cluster_id = kind_cluster.warehouse.id
    kubeconfig = local.kubeconfig_path
    name       = local.kong_prometheus_plugin_name
  }

  # per_consumer=false: this fleet's REST/MCP endpoints are unauthenticated
  # (no Kong consumer objects exist at all), so a per-consumer breakdown
  # would add label cardinality for a dimension that can never be
  # populated. status_code_metrics/latency_metrics/bandwidth_metrics/
  # upstream_health_metrics=true is the plugin's documented full feature
  # set; nothing here is exotic configuration.
  provisioner "local-exec" {
    command = <<-EOT
      cat <<'MANIFEST' | kubectl --kubeconfig '${local.kubeconfig_path}' apply -f -
      apiVersion: configuration.konghq.com/v1
      kind: KongClusterPlugin
      metadata:
        name: ${local.kong_prometheus_plugin_name}
        labels:
          global: "true"
        annotations:
          kubernetes.io/ingress.class: kong
      plugin: prometheus
      config:
        per_consumer: false
        status_code_metrics: true
        latency_metrics: true
        bandwidth_metrics: true
        upstream_health_metrics: true
      MANIFEST
    EOT
  }

  # local-exec has no destroy counterpart -- same orphaned-object gap
  # kong-cors.tf documents and fixes the same way.
  provisioner "local-exec" {
    when    = destroy
    command = "kubectl --kubeconfig '${self.triggers.kubeconfig}' delete kongclusterplugin '${self.triggers.name}' --ignore-not-found=true || true"
  }
}
