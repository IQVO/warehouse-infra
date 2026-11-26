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

# ---------------------------------------------------------------------------
# The Agent Router shared Gateway (ADR 0014) — the data-plane entry point the
# fleet's A2A routes attach to.
#
# Envoy Gateway's chart does NOT create a GatewayClass: it only runs the
# controller, which reconciles GatewayClasses whose controllerName is
# gateway.envoyproxy.io/gatewayclass-controller (verified live after the
# helm_release.envoy_gateway apply: `kubectl get gatewayclass` listed only
# istio/istio-remote/kong). So both objects are declared here, following the
# same kubectl_manifest pattern as the Kong GatewayClass/Gateway in
# gateway-api.tf (declarative: a drift or deletion is a plan diff, not a
# silent absence).
#
# The listener allows routes from EVERY namespace: the application charts
# render their a2a HTTPRoutes in the apps namespace and attach them to this
# Gateway cross-namespace via the parentRefs of helm-values/_platform.yaml
# (the a2a anchor points here since ADR 0014). The Gateway API CRDs are
# already the cluster's own (k3s gateway-api-crd HelmChart, see
# gateway-api.tf's header comment) — nothing to install.
# ---------------------------------------------------------------------------

# The data plane's Service MUST be ClusterIP (ADR 0011's exposure rule:
# NodePort/LoadBalancer answer on the node's LAN address and the fleet is
# unauthenticated). Envoy Gateway's default is LoadBalancer, and on k3s that
# also spawns one klipper svclb pod PER NODE — observed live after the
# gateway landed (two svclb pods on a pod-capped cluster, and :80 published
# on the LAN). This EnvoyProxy config, attached to the GatewayClass via
# parametersRef, is EG's supported way to change the data-plane Service type.
resource "kubectl_manifest" "agent_router_envoyproxy" {
  depends_on = [helm_release.envoy_gateway]

  yaml_body = yamlencode({
    apiVersion = "gateway.envoyproxy.io/v1alpha1"
    kind       = "EnvoyProxy"
    metadata = {
      name      = "agent-router-proxy-config"
      namespace = var.envoy_gateway_namespace
    }
    spec = {
      provider = {
        type = "Kubernetes"
        kubernetes = {
          envoyService = {
            type = "ClusterIP"
          }
        }
      }
    }
  })
}

resource "kubectl_manifest" "agent_router_gateway_class" {
  depends_on = [helm_release.envoy_gateway]

  yaml_body = yamlencode({
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "GatewayClass"
    metadata = {
      name = "eg"
    }
    spec = {
      controllerName = "gateway.envoyproxy.io/gatewayclass-controller"
      parametersRef = {
        group     = "gateway.envoyproxy.io"
        kind      = "EnvoyProxy"
        name      = kubectl_manifest.agent_router_envoyproxy.name
        namespace = var.envoy_gateway_namespace
      }
    }
  })
}

resource "kubectl_manifest" "agent_router_gateway" {
  depends_on = [kubectl_manifest.agent_router_gateway_class]

  yaml_body = yamlencode({
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "Gateway"
    metadata = {
      name      = "agent-router"
      namespace = var.envoy_gateway_namespace
    }
    spec = {
      gatewayClassName = kubectl_manifest.agent_router_gateway_class.name
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
