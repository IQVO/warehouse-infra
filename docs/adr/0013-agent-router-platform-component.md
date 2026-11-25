# ADR 0013: Agent Router (Envoy AI Gateway) is a Terraform-managed platform component

## Status

Accepted (2026-11-25)

## Context

The fleet needs unified access to generative AI services. Agent Router
(formerly Envoy AI Gateway, <https://github.com/theagentrouter/agent-router>)
provides exactly that: an `AIGatewayRoute`/`AIServiceBackend` API built on
Envoy Gateway, with provider translation (OpenAI, Anthropic, AWS Bedrock,
Gemini, ...), token quotas and MCP routing.

It is platform infrastructure, not an application of `terraform/apps.yaml`:
it owns no database, no image build and no ArgoCD `Application`, exactly
like Kong, Kafka or the observability stack. It therefore belongs in the
`10-platform` layer, not in the per-application registry of ADR 0004.

Its data plane is Envoy Gateway, a second Gateway API controller next to
the Kong Ingress Controller. The two must coexist: Kong keeps fronting the
fleet's north-south HTTP traffic (ADR 0006), Agent Router's Envoy Gateway
serves only AI traffic once a `Gateway` of its class is created.

## Decision

1. Agent Router is installed by three `helm_release` resources in
   `terraform/10-platform/agent-router.tf`, in upstream order: Envoy
   Gateway (`oci://docker.io/envoyproxy/gateway-helm`), then
   `ai-gateway-crds-helm`, then `ai-gateway-helm` into their own
   namespaces (`envoy-gateway-system`, `envoy-ai-gateway-system`).
2. Versions are pinned variables following ADR 0011: `v1.3.0` for both
   Agent Router charts and `v1.10.0` for Envoy Gateway, the dependency
   versions the v1.3.0 GitHub release declares.
3. The Envoy Gateway values mirror the upstream
   `manifests/envoy-gateway-values.yaml`: the Backend API and the
   xdsTranslator extension-manager hooks pointed at
   `ai-gateway-controller.envoy-ai-gateway-system.svc.cluster.local:1063`
   are mandatory for the controller to fine-tune the generated xDS.
4. Coexistence with Kong is by GatewayClass: Envoy Gateway reconciles only
   classes whose controllerName is `gateway.envoyproxy.io/
   gatewayclass-controller`; Kong's class keeps its own controller. No
   existing Gateway, HTTPRoute or Ingress changes.
5. Creating `Gateway` objects of the Envoy Gateway class, the
   `AIGatewayRoute`s and the provider credentials is application
   configuration decided per use case later, the same split as
   `kong.tf` (platform) versus the services' HTTPRoutes (applications).
   Nothing is exposed north-south by this ADR.

## Consequences

- `scripts/tf.sh platform apply` installs the whole stack; the two new
  namespaces carry the `warehouse.local/tier: platform` label.
- The cluster's vendored Gateway API bundle (v1.6.2, ADR 0006) already
  satisfies the v1.6.1 the release requires; no CRD work is needed.
- Upgrades bump `agent_router_chart_version` /
  `envoy_gateway_chart_version` together, to a pair a GitHub release of
  `theagentrouter/agent-router` declares.
- A future removal is one `terraform destroy -target` away; no
  application state depends on these releases.
