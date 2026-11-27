# ADR 0015: MCP traffic is exposed through the Agent Router, not Kong

## Status

Accepted (2026-11-26, decided by the owner). Amends ADR 0014 decision 4 (the MCP
routes no longer stay on Kong)

## Context

ADR 0014 moved the A2A routes to the Agent Router (Envoy Gateway) and left the
API, MCP and analytics reports routes on Kong. The owner has now fixed the split
for the whole fleet: every MCP and every A2A service is exposed by the Agent
Router, every REST API by Kong. In-cluster consumers (warehouse-ops-agent and the
other contexts' MCP/A2A clients) reach the servers through the `<ctx>-mcp` and
`<ctx>-a2a` Service DNS and are untouched; this decision only concerns the
gateway edge the `mcp.route.parentRefs` attach to.

## Decision

1. `helm-values/_platform.yaml`: the `mcp.route.parentRefs` anchor now points at
   the shared `agent-router` Gateway (`envoy-gateway-system`, listener `http`),
   the same `*agentRouterGateway` alias the `a2a` anchor uses. The API and
   analytics reports anchors stay on `warehouse-gateway` (Kong).
2. Terraform checks the split on both Gateways: `gateway-api.tf` requires the
   `gatewayApi` and `analytics.reports` parentRefs to name the Kong Gateway (the
   MCP refs left that list); `agent-router.tf` requires the `a2a` and `mcp`
   parentRefs to name the Agent Router Gateway.
3. Every application chart's `mcp-route.yaml` and `a2a-route.yaml` drops the
   Kong-only `konghq.com/plugins` annotation (inert on Envoy Gateway) and
   renders an optional `timeouts.request` (`mcp.route.timeouts` /
   `a2a.route.timeouts`, default `"0s"`): Envoy's 15 s default route timeout
   would cut MCP Streamable HTTP responses that stream over SSE and long A2A
   calls. The chart tests (`test_kong_config.py`) now enforce the split: no
   Kong annotation and an `agent-router` parent on MCP/A2A routes, the Kong
   plugin contract on api/reports routes only. The public path contract
   `/api/mcp/<context>` rewritten to `/mcp` is unchanged.
4. `scripts/k3s-edges.sh` serves MCP and A2A on the one Agent Router edge,
   `localhost:8010`. The MCP host edge leaves `localhost:8000`.
5. Ordering (ADR 0014 decision 5, unchanged): the `agent-router` Gateway is
   applied and Programmed BEFORE the `_platform.yaml` flip merges, and the charts
   carrying the new route templates are released and pinned before or with it, so
   no MCP HTTPRoute ever sits detached. Rollback is reverting the anchor.

## Consequences

- Kong no longer serves MCP traffic. The `warehouse-cors`/prometheus/
  opentelemetry KongPlugins no longer apply to the MCP routes: MCP clients are
  agents, not browsers, so CORS is not needed; the per-route RED metrics and
  Kong spans of the MCP routes (and the Kong 5xx alert rows built on them) are
  replaced by Envoy's own metrics and the services' OTel spans — dashboards and
  alert rules for the Agent Router edge are a separate follow-up.
- The Agent Router data plane now carries MCP and A2A, one more reason to keep
  its Service ClusterIP (ADR 0011 exposure rule) and bound to 127.0.0.1 on the
  workstation.
- External MCP probes (`scripts/mcp-conformance-2026-07-28.py --base`) use
  `http://localhost:8010/api/mcp`.
