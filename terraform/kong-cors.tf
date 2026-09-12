# ---------------------------------------------------------------------------
# Kong CORS: the load-bearing consequence of two independent edges (ADR-0005).
#
# The product deliberately serves assets from http://localhost and APIs from
# http://localhost:8000. Those are different origins, so EVERY browser call the
# console makes is cross-origin and would be blocked outright without this
# plugin. This is not hardening-after-the-fact; it is what makes the chosen
# topology work at all.
#
# The two rejected alternatives (routing assets through Kong, or chaining Nginx
# to Kong) would both have kept a single origin and needed no CORS. Strict
# traffic separation was chosen over that convenience, so CORS is the accepted
# cost of the decision rather than an oversight.
#
# Exact origin, never "*": these endpoints are unauthenticated, so a wildcard
# would let any page on the internet read this warehouse's data through the
# user's own browser.
#
# WHY A CLUSTER-WIDE PLUGIN RATHER THAN PER-ROUTE:
# The per-route mechanism is a `konghq.com/plugins` annotation on each
# HTTPRoute, but none of the nine charts' httproute.yaml templates render an
# annotations block at all (verified across every repo's origin/develop), so
# attaching per-route would mean nine more chart PRs before this environment
# could work. It would also be the wrong shape: in THIS topology every single
# Kong route is an API by construction -- Kong never serves a frontend -- so
# "allow the web origin" is a property of the gateway, not of any one service.
# A KongClusterPlugin labelled global:"true" says exactly that, once.
#
# Shape verified against the live CRD and KIC's own source, not guessed:
#   * `plugin:` and `config:` are TOP-LEVEL keys on configuration.konghq.com/v1
#     (`kubectl explain kongclusterplugin --recursive`), NOT nested under spec:.
#   * KIC selects global plugins by the label `global: "true"` AND a matching
#     ingress class -- see ListGlobalKongClusterPlugins in
#     Kong/kubernetes-ingress-controller internal/store/store.go, which builds
#     exactly that label requirement and then filters by isValidIngressClass.
# ---------------------------------------------------------------------------

locals {
  kong_cors_plugin_name = "warehouse-cors"
}

resource "null_resource" "kong_cors_plugin" {
  count = var.deploy_services && var.kong_cors_enabled ? 1 : 0

  depends_on = [
    helm_release.kong,
    kubernetes_namespace.apps,
  ]

  triggers = {
    cluster_id = kind_cluster.warehouse.id
    kubeconfig = local.kubeconfig_path
    name       = local.kong_cors_plugin_name
    origin     = local.web_origin
  }

  # credentials=false deliberately: nothing here uses cookies or an
  # Authorization header, and leaving it false keeps the browser from ever
  # combining credentialed requests with a broad origin by mistake.
  provisioner "local-exec" {
    command = <<-EOT
      cat <<'MANIFEST' | kubectl --kubeconfig '${local.kubeconfig_path}' apply -f -
      apiVersion: configuration.konghq.com/v1
      kind: KongClusterPlugin
      metadata:
        name: ${local.kong_cors_plugin_name}
        labels:
          global: "true"
        annotations:
          kubernetes.io/ingress.class: kong
      plugin: cors
      config:
        origins:
          - ${local.web_origin}
        methods:
          - GET
          - POST
          - PUT
          - PATCH
          - DELETE
          - OPTIONS
        headers:
          - Accept
          - Content-Type
          - Origin
        exposed_headers:
          - Content-Length
        credentials: false
        max_age: 3600
        preflight_continue: false
      MANIFEST
    EOT
  }

  # local-exec has no destroy counterpart, so without this a count 1->0 leaves
  # the plugin orphaned in the cluster with nothing tracking it -- the same
  # failure already documented on gateway-api.tf's CRD resource.
  provisioner "local-exec" {
    when    = destroy
    command = "kubectl --kubeconfig '${self.triggers.kubeconfig}' delete kongclusterplugin '${self.triggers.name}' --ignore-not-found=true || true"
  }
}

output "cors_allowed_origin" {
  description = "The single browser origin Kong grants API access to."
  value       = var.kong_cors_enabled ? local.web_origin : ""
}
