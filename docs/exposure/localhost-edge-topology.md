# Localhost edge topology: two independent gateways

Status: accepted (2026-09-12)

## Context

The fleet's product surface has two very different kinds of traffic: static
frontend assets (the `warehouse-console` shell plus eight Module Federation
remotes) and REST APIs (eight bounded contexts plus `warehouse-ops-agent`).
Both have to be reachable from a browser on the developer's own machine, from
the local `kind` cluster.

Before this decision the cluster exposed APIs only. Kong owned host port 80 and
routed `/<service>` to each context, and the frontends had no in-cluster
presence at all — they ran as Vite dev servers on `:5173`/`:518x`, outside the
cluster entirely. That left three problems:

1. The product could not actually be *used* from the cluster. Running the UI
   meant starting nine dev servers by hand.
2. The API routes collided with the shell's own client-side routes.
   `/order-management` is simultaneously a Kong route prefix and a page in the
   SPA; both cannot own the same path.
3. Every frontend baked its API base URL in at build time, so one image was
   only ever valid for the environment it was built in.

The hard constraint on any solution: **Kong must never serve HTML, CSS,
JavaScript, fonts or images.** Asset delivery is nginx's job.

## Decision

Two host-facing entrypoints, both loopback-only, with **no proxy relationship
between them**:

```
Browser -> http://localhost         -> Nginx web gateway
  /                                  -> warehouse-console nginx pod
  /mfes/<context>/**                 -> that context's own nginx pod

Browser -> http://localhost:8000    -> Kong
  /api/<context>/**                  -> that context's OLTP REST Service
  /api/warehouse-ops-agent/**        -> the console BFF
```

The rules that follow from it:

- The web gateway contains no `location /api` and no Kong or backend upstream.
- Kong routes to API Services only; no HTTPRoute targets a `-frontend` Service.
- Exactly two NodePorts exist in the product namespace. Every other Service —
  shell, remotes, APIs, analytics, MCP — stays ClusterIP.
- "All APIs through Kong" is a **north-south** rule. Service-to-service calls
  stay on direct ClusterIP/Kafka and never hairpin through either gateway.
- API routes move from `/<service>` to `/api/<context>`, resolving the
  collision with the shell's client-side routes. Kong strips the prefix, so
  each Go router keeps its existing unprefixed contract.
- Kong moves off host port 80 to `:8000`, freeing 80 for the product UI.

`scripts/test-exposure-policy.sh` asserts all of this against the live cluster,
including that the gateway's own access log contains no `/api` request and
Kong's contains no asset request.

## Alternatives rejected

**Kong as the single product edge**, routing `/mfes/**` and `/` onward to nginx
pods. Rejected: it puts asset traffic through Kong even though nginx still
serves the bytes. The constraint is that assets do not traverse Kong at all.

**Nginx on :80 proxying `/api/**` to an internal Kong.** This was attractive
because it keeps one browser origin and therefore needs no CORS. Rejected: it
adds a hop and gives the frontend gateway visibility into API traffic. Strict
traffic separation was judged more valuable than the convenience of a single
origin.

## Consequences

**CORS becomes load-bearing.** Assets come from `http://localhost` and APIs
from `http://localhost:8000` — genuinely different origins, so every call the
console makes is cross-origin. Kong carries a CORS policy granting exactly the
web gateway's origin. Never `*`: these endpoints are unauthenticated, and a
wildcard would let any page on the internet read this warehouse's data through
the user's own browser.

**Frontends cannot bake in their API base.** The console fetches
`/config.json` (mounted from a ConfigMap) before it mounts and publishes
`{ "apiOrigin": ... }` on `window.__WAREHOUSE_CONFIG__`; every remote reads it
from there. Validation is strict and fail-fast — a production build with no
runtime config refuses to start rather than silently falling back to a
developer port.

**This is not a rolling upgrade.** Two immutable fields change:

1. kind's `extraPortMappings` (Kong 80 -> 8000, web gateway added on 80).
2. Each chart's Deployment `selector.matchLabels`, which gained
   `app.kubernetes.io/component` so the new frontend workload is not selected
   by the OLTP Service. (That Service genuinely selected the OLTP, projector,
   reports *and* MCP pods before this change — a live `curl` for an OLTP
   `/healthz` was answered by the analytics reports pod.)

Both require destroying and recreating the cluster. Persistence is disabled by
default, so no data is expected to survive a rebuild regardless.

**Frontend images are content-addressed** (`local-<hash>`) rather than using
the fixed `local` tag the Go services use. With a fixed tag a rebuilt image
leaves the pod template byte-identical, so Kubernetes never rolls it and
`IfNotPresent` stops the kubelet re-pulling — the old bundle keeps serving
silently. Hashing the sources into the tag makes a rollout happen on its own.

**Loopback binding is deliberate.** Both product edges bind `127.0.0.1`, not
`0.0.0.0`, because every REST and MCP endpoint in this fleet is currently
unauthenticated and must not be reachable from the local network.
