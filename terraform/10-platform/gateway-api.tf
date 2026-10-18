# ---------------------------------------------------------------------------
# Gateway API — Kong fronts every service via HTTPRoute.
#
# Kong originally fronted every service via plain Kubernetes `Ingress`
# objects (see kong.tf's header comment on that original choice). This
# migrates every service in module.registry.services (plus warehouse-ops-agent, see
# ops-agent.tf) from Ingress to the Kubernetes Gateway API's HTTPRoute,
# chart-rendered via each service's own `gatewayApi` values block (its
# helm-values file; the parentRefs come from helm-values/_platform.yaml).
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
# Declarative since ADR 0002 D5 (ADR 0006). Every object below is a
# kubectl_manifest, so Terraform reconciles it: a changed or deleted object is
# a plan diff, where the `kubectl apply` in a null_resource ran once and never
# looked again. That is how the KongClusterPlugins and the reports routes
# silently disappeared from the cluster before 2026-10-13. kubectl_manifest, not
# the `kubernetes_manifest` resource, because the latter needs the CRD's
# OpenAPI schema at PLAN time, which does not exist yet on an apply that
# installs a CRD and a custom resource of it in the same run.
#
# The CRD bundle is vendored under terraform/gateway-api/ (one file per
# release; scripts/vendor-gateway-api.sh adds one), so a plan needs no network
# and an upgrade is a reviewable diff.
# ---------------------------------------------------------------------------

locals {
  gateway_api_bundle = "${path.module}/../gateway-api/standard-install-${var.gateway_api_version}.yaml"
}

data "kubectl_file_documents" "gateway_api_crds" {
  count = var.deploy_gateway_api ? 1 : 0

  lifecycle {
    precondition {
      condition     = fileexists(local.gateway_api_bundle)
      error_message = "No vendored Gateway API bundle for ${var.gateway_api_version}. Run scripts/vendor-gateway-api.sh ${var.gateway_api_version} and commit the file under terraform/gateway-api/."
    }
  }

  content = try(file(local.gateway_api_bundle), "")
}

# The standard-channel bundle: the CRDs, plus the upstream safe-upgrades
# ValidatingAdmissionPolicy and its binding. One resource per document, keyed
# by the object's API path.
#
# Server-side apply with forced conflicts: the HTTPRoute CRD alone is about
# 250 KB, at the edge of the annotation `kubectl apply` would add, and the
# first apply adopts objects that `kubectl apply` created. The provider's
# apply_retry_count (providers.tf) covers the moment between a CRD being
# created and the API server serving it, when the GatewayClass below would
# otherwise fail with "no matches for kind".
resource "kubectl_manifest" "gateway_api_crds" {
  for_each = var.deploy_gateway_api ? data.kubectl_file_documents.gateway_api_crds[0].manifests : {}

  yaml_body         = each.value
  server_side_apply = true
  force_conflicts   = true
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
resource "kubectl_manifest" "gateway_class" {
  count = var.deploy_gateway_api ? 1 : 0

  depends_on = [
    kubectl_manifest.gateway_api_crds,
    helm_release.kong,
  ]

  yaml_body = yamlencode({
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "GatewayClass"
    metadata = {
      name = "kong"
      annotations = {
        "konghq.com/gatewayclass-unmanaged" = "true"
      }
    }
    spec = {
      controllerName = "konghq.com/kic-gateway-controller"
    }
  })
}

# The Gateway: the actual listener KIC programs into the running Kong
# proxy. One shared Gateway for the whole fleet, matching the existing
# "one Kong release fronts every service" topology — HTTPRoutes attach to
# this by name via parentRefs, they do not each get their own Gateway.
resource "kubectl_manifest" "gateway" {
  count = var.deploy_gateway_api ? 1 : 0

  # Every application's routes attach to the parentRefs in
  # helm-values/_platform.yaml: they must name this Gateway's namespace and
  # listener.
  lifecycle {
    precondition {
      condition = alltrue([
        for ref in concat(
          local.platform.gatewayApi.parentRefs,
          local.platform.mcp.route.parentRefs,
          local.platform.analytics.reports.route.parentRefs,
        ) : ref.name == local.gateway_name && ref.namespace == var.kong_namespace && ref.sectionName == "http"
      ])
      error_message = "helm-values/_platform.yaml parentRefs must all point at Gateway ${local.gateway_name} in namespace ${var.kong_namespace}, listener http."
    }
  }

  depends_on = [kubectl_manifest.gateway_class]

  yaml_body = yamlencode({
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "Gateway"
    metadata = {
      name      = local.gateway_name
      namespace = var.kong_namespace
    }
    spec = {
      gatewayClassName = "kong"
      listeners = [{
        name     = "http"
        protocol = "HTTP"
        port     = 80
        allowedRoutes = {
          namespaces = {
            from = "All"
          }
        }
      }]
    }
  })
}

locals {
  # A platform fact the application charts read from
  # helm-values/_platform.yaml (ADR 0002 D2), so it is read from there.
  gateway_name = local.platform.gatewayApi.parentRefs[0].name

  # Known only once the CRDs, the GatewayClass and the Gateway exist. Every
  # Application waits on it (modules/application's platform_ready), so ArgoCD
  # never syncs an HTTPRoute before its CRD: no staged `-target` apply.
  gateway_ready = var.deploy_gateway_api ? kubectl_manifest.gateway[0].uid : "gateway-api-disabled"
}

output "gateway_api_installed" {
  description = "Whether the Gateway API CRDs/GatewayClass/Gateway are installed."
  value       = var.deploy_gateway_api
}
