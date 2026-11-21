# ADR 0012: Agent adapters share one pod per context

## Status

Accepted (2026-11-21, decided by the owner). Proposed earlier the same day. Capacity step 3 (plan
`warehouse-systems/.hermes/plans/2026-11-21-capacity-step3-agents-pod.md`). Decisions D1 to D4 below are
**decided**. This ADR itself deploys nothing: each context changes only when its chart ships `agents.colocate` and
`helm-values/<ctx>.yaml` turns it on (pilot asrs-control first). Builds on
[ADR 0011](0011-deploy-to-an-existing-k3s-from-ghcr.md) (the k3s target and its 110-pod node limit) and
[ADR 0002](0002-application-delivery-boundary.md) (charts in the service repos, values here).

## Context

- The k3s cluster is pod-bound, not memory-bound: on 2026-11-21 the server node ran 110/110 pods and the agent
  107/110 (kubelet `maxPods` is 110 and not ours to change, ADR 0011).
- 35 contexts run both an MCP adapter (`cmd/mcp`, :8090) and an A2A adapter (`cmd/a2a`, :8093), each as its own
  single-container Deployment: 70 pods. checkout and customer-payments run only a2a.
- Each service keeps the binaries separate on purpose (fulfillment-execution ADR-0008 "A separate `cmd/mcp`
  binary", and every context's MCP/A2A ADR): Streamable HTTP MCP, the a2a-go server, own dependency rule, own
  blast radius. ADR-0008 also gives "the two scale independently" as a reason. Nothing in that reasoning needs
  the two binaries to be in two **pods**.
- Every fleet chart has the same mcp/a2a shape (`templates/{mcp,a2a}-{deployment,service,route}.yaml`, port
  `http`, Services selecting `name + instance + component`). The mcp and a2a pod specs are identical apart from
  the containers in all 35 charts (checked by rendering).
- ArgoCD (v2.13.2) syncs every Application with `automated {prune: true, selfHeal: true}`. The chart source is
  the service repo's `develop` (module default `chart.target_revision = "develop"`); the value files are this
  repo's `develop`; the image tag is the pin in `terraform/targets/k3s.images.yaml`, carried in `valuesObject`.

## Decision

1. **An optional chart value `agents.colocate`** (default `false`) in every chart that has both components. With
   `agents.colocate`, `mcp.enabled` and `a2a.enabled` all true, the chart renders ONE `<release>-agents`
   Deployment with two containers, `mcp` (:8090) and `a2a` (:8093), instead of the two standalone Deployments.
   With only one of mcp/a2a on, it falls back to the standalone Deployment.
   - The containers are taken verbatim from the standalone templates (image, command, env, probes, resources,
     OTel service names); only the port **name** changes, `http` to `mcp` / `a2a` (probe refs too), because two
     containers of one pod cannot both expose `http` behind a named `targetPort`.
   - The render fails if the mcp and a2a pod specs ever diverge (service account, security context, scheduling,
     pull secrets) instead of silently picking one.
   - The Services `<ctx>-mcp` / `<ctx>-a2a` keep their names and ports and switch selector
     (`component: agents`) and `targetPort` (`mcp` / `a2a`). HTTPRoutes, KongPlugins, `A2A_AGENT_URL`, the
     ops-agent upstream URLs and the dashboards/alerts are unchanged.
   - The reference template, the canonical chart test and the checklist row live in
     `IQVO/warehouse-harness-template` `templates/packaging/charts/`.
2. **Cutover by a new object name, not by patching a selector.** `<ctx>-agents` carries
   `argocd.argoproj.io/sync-wave: "-1"`; the standalone Deployments carry `argocd.argoproj.io/sync-options:
   PruneLast=true`. ArgoCD creates the agents pod and waits for it to be Healthy, re-points the Services, then
   prunes the old two. No immutable `spec.selector` is patched and no live object is replaced.
3. **warehouse-infra turns it on per context**, `agents: {colocate: true}` in `helm-values/<ctx>.yaml`, one
   pilot (asrs-control) and then batches. Rollback is reverting that line.
4. **The conformance check guards it before any chart migrates.** `scripts/check-chart-selectors.py` renders
   every chart with a2a enabled wherever the chart ships it, renders charts with both mcp and a2a a second time
   with `agents.colocate=true`, and asserts that every Service's named `targetPort` resolves to exactly one
   containerPort of the one Deployment it selects.

### Decisions (decided by the owner, 2026-11-21)

- **D1, shared fate: accepted.** One agents pod per context: if either container is unready, both
  the MCP and the A2A endpoint of that context are out of the Service endpoints, and mcp and a2a scale together
  (`replicas` = `mcp.replicaCount`). The api pod stays isolated. This gives up ADR-0008's "scale independently"
  between the two adapters for 35 pod slots; a context that ever needs separate scaling is un-flipped.
- **D2, release every repo: decided.** Every deploy uses a version that exists as a GitHub release/tag, so
  each chart PR ships through the normal develop -> main release (35 releases), even though ArgoCD reads the
  chart from `develop` and the image does not change. The lighter variant (no release for the chart-only change)
  is rejected under that rule.
- **D3, RollingUpdate stays the default: decided** for `<ctx>-agents` after the cutover (no downtime on pin
  rolls); `agents.strategy: {type: Recreate}` is a per-app overlay lever only when no surge slot is free.
- **D4, pin first, then flip: decided.** Within a batch: release, publish, pin and apply the image on the
  still-standalone layout first; flip `agents.colocate` in a separate PR afterwards. Flip-before-pin (the old
  pinned image already holds `/app/mcp` and `/app/a2a`) stays available when capacity is too tight to roll.

## Consequences

- −35 pod slots (70 -> 35 agent pods); a merged pod requests the sum of the two containers' requests, so the
  `helm-values/kind-resources/` per-container overlays keep working.
- Readiness is pod-wide (D1). Liveness stays per container: a crashing a2a container restarts alone.
- Embedded boot migrations of both binaries start together in one pod, serialized by the advisory lock as today
  across pods.
- A cutover needs one free pod slot (and the summed memory) per app in flight, a rollback two; the rollback has a
  gap of seconds because the standalone pods come back in wave 0 with the Service switch.
- Operator tooling that greps pods `<ctx>(-mcp|-a2a)` or label `component=a2a` must also accept `-agents` /
  `component=agents` after the pilot.
- No dashboard or alert change: the Kong rules key on HTTPRoute names, the restart alert on `pod=~"<ctx>-.+"` by
  container, Loki on the `app` label.
