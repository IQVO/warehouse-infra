# ADR 0014: A2A traffic is exposed through the Agent Router, not Kong

## Status

Accepted (2026-11-26, decided by the owner). Decision 4 amended by ADR 0015: the MCP routes
also moved to the Agent Router

## Context

ADR 0013 installed Agent Router (Envoy AI Gateway on Envoy Gateway) as a
platform component. Until now every application route — API, MCP, A2A and
analytics reports — attached to the one shared Kong Gateway
(`warehouse-gateway`, namespace `kong`; the `*gateway` anchor in
`helm-values/_platform.yaml`), a fleet decision recorded 2026-10-13 in the
chart templates' comments.

The owner has now decided that the A2A agents' exposure moves to the Agent
Router data plane. In-cluster consumers (the ops-agent, other contexts' A2A
clients) already reach the agents through the `<ctx>-a2a` Service DNS and
are untouched; this decision is only about the gateway edge the
`a2a.route.parentRefs` attach to.

## Decision

1. A `GatewayClass` `eg` (controllerName
   `gateway.envoyproxy.io/gatewayclass-controller`) and a shared `Gateway`
   `agent-router` in the Envoy Gateway namespace are declared in
   `terraform/10-platform/agent-router.tf` as `kubectl_manifest`s, the same
   declarative pattern as ADR 0006. Envoy Gateway's chart creates neither
   object.
2. The `agent-router` listener `http` allows routes from all namespaces:
   the application charts render their A2A HTTPRoutes in the apps namespace
   and attach cross-namespace.
3. `helm-values/_platform.yaml` points the `a2a.route.parentRefs` anchor at
   `agent-router` / `envoy-gateway-system` / `http`. Every application
   chart keeps its generic HTTPRoute template; only the anchor moves the
   whole fleet's A2A edge at once. The public path contract
   `/api/a2a/<context>` rewritten to `/` is unchanged — Envoy Gateway
   supports the same URLRewrite filter.
4. The API, MCP and analytics reports routes stay on Kong. The A2A host
   edge leaves `localhost:8000` (Kong) and gets its own port-forward in
   `scripts/k3s-edges.sh` against the Envoy service Envoy Gateway
   provisions for the `agent-router` Gateway.
5. Ordering: the Gateway ships and is applied (Programmed, data-plane pod
   running) BEFORE the `_platform.yaml` flip merges, so no A2A HTTPRoute
   ever sits detached. Rollback is reverting the anchor.

## Consequences

- Kong no longer serves A2A traffic; the `konghq.com/plugins` annotation on
  a2a routes becomes inert (Envoy Gateway ignores unknown annotations) and
  the CORS plugin no longer applies to A2A — acceptable: A2A consumers are
  agents, not browsers. A2A observability comes from Envoy's own metrics
  and the services' OTel instrumentation instead of the Kong plugins.
- One more data-plane pod per cluster (the Gateway's Envoy deployment),
  counted against the 110-pod node budget of ADR 0012.
- The chart-side fleet decision comment of 2026-10-13 ("A2A exposure
  through Kong") is superseded for the a2a routes by this ADR; api/mcp/
  reports routes keep it.
