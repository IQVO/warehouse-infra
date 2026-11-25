# ---------------------------------------------------------------------------
# Agent Router (Envoy AI Gateway) — unified access to generative AI services.
#
# Three Helm releases, exactly the upstream install order
# (https://theagentrouter.ai/docs/getting-started/installation, pinned to
# the v1.3.0 GitHub release per ADR 0011 — every deploy uses a version that
# exists as a release/tag on GitHub):
#
#   1. Envoy Gateway (oci://docker.io/envoyproxy/gateway-helm, v1.10.0) —
#      the data plane Agent Router builds on. Its values come from the
#      upstream manifests/envoy-gateway-values.yaml: the Backend API and the
#      xdsTranslator extension-manager hooks pointed at the
#      ai-gateway-controller extension server are REQUIRED, without them the
#      controller cannot fine-tune the xDS resources.
#   2. ai-gateway-crds-helm — every CRD (AIGatewayRoute, AIServiceBackend,
#      BackendSecurityPolicy, MCPRoute, QuotaPolicy, ...). Split into its own
#      chart upstream so CRD lifecycle is independent of the controller's.
#   3. ai-gateway-helm — the controller + extproc filter.
#
# Coexistence with Kong: Envoy Gateway reconciles only GatewayClasses whose
# controllerName is io.envoyproxy.gatewayclass/gatewayclass-controller; the
# Kong GatewayClass (gateway-api.tf) keeps its own controller. The two data
# planes never touch each other's Gateways or HTTPRoutes. Nothing is exposed
# north-south by this file: creating a Gateway of the eg class, the
# AIGatewayRoutes and the provider credentials are application configuration,
# done later per use case (same split as kong.tf vs the services' HTTPRoutes).
#
# The cluster's vendored Gateway API bundle (gateway-api.tf, v1.6.2) already
# satisfies the v1.6.1 the v1.3.0 release notes require.
# ---------------------------------------------------------------------------

resource "kubernetes_namespace" "envoy_gateway_system" {
  metadata {
    name = var.envoy_gateway_namespace
    labels = {
      "warehouse.local/tier" = "platform"
    }
  }
}

resource "kubernetes_namespace" "agent_router" {
  metadata {
    name = var.agent_router_namespace
    labels = {
      "warehouse.local/tier" = "platform"
    }
  }
}

resource "helm_release" "envoy_gateway" {
  depends_on = [kubernetes_namespace.envoy_gateway_system]

  name       = "eg"
  repository = "oci://docker.io/envoyproxy"
  chart      = "gateway-helm"
  version    = var.envoy_gateway_chart_version
  namespace  = var.envoy_gateway_namespace

  timeout = 600
  wait    = true

  # Values mirrored from upstream manifests/envoy-gateway-values.yaml @
  # v1.3.0. The extension-server FQDN must match the namespace and Service
  # name the ai-gateway-helm release creates below.
  values = [yamlencode({
    config = {
      envoyGateway = {
        gateway = {
          controllerName = "gateway.envoyproxy.io/gatewayclass-controller"
        }
        logging = {
          level = {
            default = "info"
          }
        }
        provider = {
          type = "Kubernetes"
        }
        extensionApis = {
          # Not strictly required, but recommended by upstream for
          # backward/future compatibility.
          enableEnvoyPatchPolicy = true
          # Required: enable the Backend API for AI service backends.
          enableBackend = true
        }
        # Required: Agent Router needs to fine-tune the xDS resources
        # Envoy Gateway generates.
        extensionManager = {
          hooks = {
            xdsTranslator = {
              translation = {
                listener = { includeAll = true }
                route    = { includeAll = true }
                cluster  = { includeAll = true }
                secret   = { includeAll = true }
              }
              post = ["Translation", "Cluster", "Route"]
            }
          }
          service = {
            fqdn = {
              hostname = "ai-gateway-controller.${var.agent_router_namespace}.svc.cluster.local"
              port     = 1063
            }
          }
        }
      }
    }
  })]
}

resource "helm_release" "agent_router_crds" {
  depends_on = [kubernetes_namespace.agent_router]

  name       = "aieg-crd"
  repository = "oci://docker.io/envoyproxy"
  chart      = "ai-gateway-crds-helm"
  version    = var.agent_router_chart_version
  namespace  = var.agent_router_namespace

  timeout = 600
  wait    = true
}

resource "helm_release" "agent_router" {
  depends_on = [helm_release.envoy_gateway, helm_release.agent_router_crds]

  name       = "aieg"
  repository = "oci://docker.io/envoyproxy"
  chart      = "ai-gateway-helm"
  version    = var.agent_router_chart_version
  namespace  = var.agent_router_namespace

  timeout = 600
  wait    = true
}
