# kind CPU-request overlays

One file per ArgoCD Application, merged INTO the Application's `helm.valuesObject` by
`terraform/kind-overlay.tf` (explicit merge at resources/mcp/frontend and analytics.projector/reports).
Helm then deep-merges valuesObject over the chart `values.yaml`, so only `requests.cpu` changes.

Not as a separate `helm.values` string: ArgoCD v2.13 renders ONLY `valuesObject` when both are set, so a
`values` string is silently ignored (warehouse-infra#81 shipped that form; found live 2026-10-14).

Why: the local kind cluster is ONE worker node with the Docker VM's 10 CPUs. The charts request 50-100m CPU
per container (about 10 cores for ~76 app containers) while measured use is ~10% of that. Every Deployment
runs 1 replica with the default RollingUpdate (maxSurge 25% -> 1 extra pod), so an apply that rolls many
services at once left the new pods Pending ("Insufficient cpu") and the rollout stalled (2026-10-14).

What they change: `requests.cpu` -> 25m for every component whose chart default is above that (API, MCP,
analytics projector/reports, frontend, console). Limits and memory keep the chart defaults, so a busy pod can
still burst. Production-like environments use the chart defaults; only this kind environment uses the overlay.

Regenerate after a chart adds a component: every `resources.requests.cpu` above 25m in
`<repo>/charts/<chart>/values.yaml` on develop gets an entry here (the overlay is generated, not hand-written).
