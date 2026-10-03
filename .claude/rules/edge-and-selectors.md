---
paths:
  - "terraform/kong*.tf"
  - "terraform/exposure.tf"
  - "terraform/gateway-api.tf"
  - "terraform/templates/web-gateway.conf.tftpl"
  - "terraform/frontends.tf"
  - "scripts/test-exposure-policy.sh"
  - "scripts/check-chart-selectors.py"
  - "docs/exposure/**"
---

# Localhost edge and chart selectors (loaded when you touch the gateways, exposure scripts or selector check)

## Edge: Nginx :80 for assets, Kong :8000 for APIs

- `terraform output product_endpoints` prints both edges. They are INDEPENDENT: neither proxies to the other. That split is a reviewed decision (`docs/exposure/localhost-edge-topology.md`); never chain one through the other and never add a `location /api` to the web gateway template.
- CORS is a `KongClusterPlugin` labelled `global: "true"` (`terraform/kong-cors.tf`; KIC selects global plugins by that label plus a matching ingress class), not a per-route annotation. The charts' `httproute.yaml` templates render no annotations block, so per-route CORS would need N chart PRs.
- ArgoCD is deliberately on neither edge; access is `kubectl port-forward` only.
- `scripts/test-exposure-policy.sh` (30 checks, needs a live cluster) is the conformance gate; run it after any edge change. Its assertions match on content-type and upstream identity, never bare HTTP status, because the gateway's catch-all returns `200 text/html` for unknown `/api/**` paths (SPA fallback).
- The reports Service of each analytics context is routed by `kubernetes_ingress_v1.service_reports` and `null_resource.service_reports_httproute` in `terraform/services.tf`, not by a chart template; keep routing decisions here.

## Selectors: each Service selects exactly ONE Deployment

- Every chart's `selectorLabels` helper must scope by `app.kubernetes.io/component`, not just name plus instance: those two labels are identical across a service's OLTP, MCP, projector, reports and frontend pods, so an unscoped Service matches all of them (verified live: an OLTP request was answered by the reports pod).
- `scripts/check-chart-selectors.py` (CI job `chart-selector-check`, `make chart-selector-check`) renders every chart with every optional component enabled and asserts the invariant. Run it before touching any selector or label wiring, and prove a fix by deliberately breaking a selector and watching `Service <ctx> selects N Deployments`.
- Its chart list is hand-maintained (like `CHARTS` in the `Makefile`); update both when a service is added.
