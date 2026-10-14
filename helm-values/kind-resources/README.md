# kind CPU-request overlays

One file per ArgoCD Application, passed as the Application's `helm.values` **string**
(`terraform/argocd-apps.tf`). The main per-service values are the Application's `helm.valuesObject`.
ArgoCD/Helm layer them as: chart `values.yaml` < `helm.values` (these files) < `helm.valuesObject`.
`valuesObject` never sets `resources`, so these overlays take effect and only override what they list.

Why: the local kind cluster is ONE worker node with the Docker VM's 10 CPUs. The charts request 50-100m CPU
per container (about 10 cores for ~76 app containers) while measured use is ~10% of that. Every Deployment
runs 1 replica with the default RollingUpdate (maxSurge 25% -> 1 extra pod), so an apply that rolls many
services at once left the new pods Pending ("Insufficient cpu") and the rollout stalled (2026-10-14).

What they change: `requests.cpu` -> 25m for every component whose chart default is above that (API, MCP,
analytics projector/reports, frontend, console). Limits and memory keep the chart defaults, so a busy pod can
still burst. Production-like environments use the chart defaults; only this kind environment uses the overlay.

Regenerate after a chart adds a component: every `resources.requests.cpu` above 25m in
`<repo>/charts/<chart>/values.yaml` on develop gets an entry here (the overlay is generated, not hand-written).
