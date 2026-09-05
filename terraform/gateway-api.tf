# ---------------------------------------------------------------------------
# Gateway API — Kong fronts every service via HTTPRoute.
#
# Kong originally fronted every service via plain Kubernetes `Ingress`
# objects (see kong.tf's header comment on that original choice). This
# migrates every service in local.services (plus warehouse-ops-agent, see
# ops-agent.tf) from Ingress to the Kubernetes Gateway API's HTTPRoute,
# chart-rendered via each service's own `gatewayApi` values block --
# services.tf and ops-agent.tf compute those values the same way they
# already computed `ingress`.
#
# HISTORY (kept because the root cause below is easy to re-trip on a future
# Kong/KIC upgrade): this started as a single-service pilot on
# fulfillment-execution using a raw kubectl-applied HTTPRoute, because none
# of the eight services' charts had an httproute.yaml template yet. That
# pilot hit a real bug (or so it looked) in Kong Ingress Controller 3.5:
# the `Gateway` controller appeared to silently stop reconciling after one
# pass at startup -- confirmed via `kubectl patch --subresource=status`
# sitting untouched for 10+ minutes, reproduced across KIC 3.5 and 3.5.13,
# and reproduced again after switching to the `gatewayDiscovery`
# split-release Helm topology. It turned out not to be a bug: `GatewayClass`
# objects require the annotation `konghq.com/gatewayclass-unmanaged: "true"`
# to be reconciled at all when Kong's dataplane is deployed via
# `deployment.kong.enabled=true` (this fleet's setup, and the setup used by
# the vast majority of self-managed Kong-on-Kubernetes deployments) rather
# than provisioned dynamically per-Gateway by KIC/Kong Gateway Operator --
# an "unmanaged" gateway in KIC's own terminology. Without the annotation,
# KIC's Gateway controller has no code path at all for that topology and
# goes idle after one pass, with zero error or log line pointing at the
# missing annotation. Found by reading KIC's own CHANGELOG.md for prior
# fixes mentioning "GatewayReconciler falls into a loop" and "unmanaged
# Gateway mode", not by guessing. With the annotation (see
# null_resource.gateway_class below), a Gateway immediately reaches
# `Accepted: True` / `Programmed: True` with the message "this unmanaged
# gateway has been picked up by the controller and will be processed", and
# a curl through a resulting HTTPRoute on a path that only existed via that
# route (not any Ingress) returned a real 200 -- verified live, then again
# via a full Terraform destroy/apply rebuild before trusting it. Once that
# fix was confirmed, the same `httproute.yaml` chart template pattern was
# fanned out to the other 7 services (each repo's own PR, independently
# verified: helm lint, a real enabled-render, a real default-is-a-no-op
# render, and CI green) so every service could migrate the same way
# fulfillment-execution did, without a fleet-wide flag day.
#
# Why not the `kubernetes_manifest` provider resource for the CRDs
# themselves: it needs the CRD's OpenAPI schema to validate the resource at
# PLAN time, which does not exist yet on a `terraform apply` that installs
# the CRD and a custom resource using it in the same run — a real, known
# chicken/egg limitation of that provider. A `null_resource` + `kubectl
# apply` avoids it and matches this module's own existing pattern for
# cluster-side actions Terraform's typed providers don't cleanly cover
# (see main.tf's kubeconfig export).
# ---------------------------------------------------------------------------

resource "null_resource" "gateway_api_crds" {
  count = var.deploy_gateway_api ? 1 : 0

  depends_on = [null_resource.kubeconfig]

  triggers = {
    version = var.gateway_api_version
    # Re-run if the cluster gets recreated, since the CRDs live IN the
    # cluster and do not survive a kind_cluster replacement.
    cluster_id  = kind_cluster.warehouse.id
    kubeconfig  = local.kubeconfig_path
    api_version = var.gateway_api_version
  }

  provisioner "local-exec" {
    command = <<-EOT
      kubectl --kubeconfig '${local.kubeconfig_path}' apply -f \
        https://github.com/kubernetes-sigs/gateway-api/releases/download/${var.gateway_api_version}/standard-install.yaml
    EOT
  }

  # local-exec has no built-in destroy counterpart, so a plain count=0 (or
  # `terraform destroy`) would otherwise leave these CRDs -- and therefore
  # every GatewayClass/Gateway/HTTPRoute instance depending on them --
  # ORPHANED in the cluster with no Terraform state tracking them at all.
  # Verified this the hard way: after flipping deploy_gateway_api to false,
  # `terraform apply` reported the resources destroyed while `kubectl get
  # gateway,httproute,gatewayclass` still showed all three, 20+ minutes
  # old, completely untracked. `when = destroy` + `self.triggers` (the only
  # values available to a destroy-time provisioner) fixes it for the
  # ordinary count-1-to-0 case; a bare `terraform destroy` still relies on
  # down.sh's kind-cluster-deletion safety net, which removes everything
  # at once regardless of provisioner ordering.
  provisioner "local-exec" {
    when    = destroy
    command = "kubectl --kubeconfig '${self.triggers.kubeconfig}' delete -f https://github.com/kubernetes-sigs/gateway-api/releases/download/${self.triggers.api_version}/standard-install.yaml --ignore-not-found=true || true"
  }
}

# The GatewayClass: a cluster-scoped "which controller implements this"
# declaration. controllerName is Kong KIC's own default
# (`konghq.com/kic-gateway-controller`, matched exactly against the real
# binary's --gateway-api-controller-name flag default, not guessed).
#
# The `konghq.com/gatewayclass-unmanaged: "true"` annotation is REQUIRED
# and is the actual fix for a real bug this pilot spent a long time
# isolating: without it, KIC's `Gateway` controller silently processes a
# Gateway object exactly once at controller startup and then NEVER
# reconciles it again (confirmed via `kubectl patch --subresource=status`
# sitting untouched for 10+ minutes; reproduced across KIC 3.5 and 3.5.13;
# reproduced even after switching to the gatewayDiscovery split-release
# topology). Root cause: this deployment runs Kong's dataplane via
# `deployment.kong.enabled=true` in the same/adjacent Helm release
# (i.e. "unmanaged" from KIC's perspective -- KIC does not itself
# provision the Gateway's dataplane pods the way Kong Gateway Operator
# would). KIC's Gateway controller has a genuinely different code path
# for that topology, gated behind this annotation, that was never
# exercised without it. With the annotation present, the Gateway
# immediately reaches `Accepted: True` / `Programmed: True` with the
# message "this unmanaged gateway has been picked up by the controller
# and will be processed" -- verified live, along with a real end-to-end
# curl through a resulting HTTPRoute returning 200 on a path that only
# exists via that route (not the pre-existing Ingress).
resource "null_resource" "gateway_class" {
  count = var.deploy_gateway_api ? 1 : 0

  depends_on = [
    null_resource.gateway_api_crds,
    helm_release.kong,
  ]

  triggers = {
    cluster_id = kind_cluster.warehouse.id
    kubeconfig = local.kubeconfig_path
  }

  provisioner "local-exec" {
    command = <<-EOT
      cat <<'MANIFEST' | kubectl --kubeconfig '${local.kubeconfig_path}' apply -f -
      apiVersion: gateway.networking.k8s.io/v1
      kind: GatewayClass
      metadata:
        name: kong
        annotations:
          konghq.com/gatewayclass-unmanaged: "true"
      spec:
        controllerName: konghq.com/kic-gateway-controller
      MANIFEST
    EOT
  }

  # See gateway_api_crds' destroy provisioner comment: local-exec resources
  # need an explicit destroy-time counterpart or count=0 orphans the object.
  provisioner "local-exec" {
    when    = destroy
    command = "kubectl --kubeconfig '${self.triggers.kubeconfig}' delete gatewayclass kong --ignore-not-found=true || true"
  }
}

# The Gateway: the actual listener KIC programs into the running Kong
# proxy. One shared Gateway for the whole fleet, matching the existing
# "one Kong release fronts every service" topology — HTTPRoutes attach to
# this by name via parentRefs, they do not each get their own Gateway.
resource "null_resource" "gateway" {
  count = var.deploy_gateway_api ? 1 : 0

  depends_on = [null_resource.gateway_class]

  triggers = {
    cluster_id = kind_cluster.warehouse.id
    kubeconfig = local.kubeconfig_path
    name       = local.gateway_name
    namespace  = var.kong_namespace
  }

  provisioner "local-exec" {
    command = <<-EOT
      cat <<'MANIFEST' | kubectl --kubeconfig '${local.kubeconfig_path}' apply -f -
      apiVersion: gateway.networking.k8s.io/v1
      kind: Gateway
      metadata:
        name: ${local.gateway_name}
        namespace: ${var.kong_namespace}
      spec:
        gatewayClassName: kong
        listeners:
          - name: http
            protocol: HTTP
            port: 80
            allowedRoutes:
              namespaces:
                from: All
      MANIFEST
    EOT
  }

  # See gateway_api_crds' destroy provisioner comment.
  provisioner "local-exec" {
    when    = destroy
    command = "kubectl --kubeconfig '${self.triggers.kubeconfig}' delete gateway '${self.triggers.name}' -n '${self.triggers.namespace}' --ignore-not-found=true || true"
  }
}

locals {
  gateway_name = "warehouse-gateway"
}

output "gateway_api_installed" {
  description = "Whether the Gateway API CRDs/GatewayClass/Gateway are installed."
  value       = var.deploy_gateway_api
}
