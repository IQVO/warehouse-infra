# CPU-request overlays (directory name is a legacy of the retired kind environment)

One file per ArgoCD Application: the LAST of its three value files (ADR 0002 D2,
`docs/adr/0002-application-delivery-boundary.md`):

1. `helm-values/_platform.yaml`
2. `helm-values/<app>.yaml`
3. `helm-values/kind-resources/<app>.yaml` (this directory)

Helm deep-merges value files over the chart's `values.yaml`, so an overlay changes only the
requests it sets (`requests.cpu`, and since capacity step 2 `requests.memory`). ArgoCD reads these files from this repo's GitHub `develop`: an overlay change
deploys on merge, through an ArgoCD sync, with no `terraform apply`. The Terraform plan fails
while an application's overlay file is missing (`terraform/modules/application`).

Why: a k3s node has a few CPUs and a 110-pod cap. The charts request 50-100m CPU
per container (about 10 cores for ~76 app containers) while measured use is ~10% of that. Every Deployment
runs 1 replica with the default RollingUpdate (maxSurge 25% -> 1 extra pod), so an apply that rolls many
services at once left the new pods Pending ("Insufficient cpu") and the rollout stalled (2026-10-14).

What they change: `requests.cpu` -> 25m for every component whose chart default is above that (API, MCP,
analytics projector/reports, frontend, console). Limits keep the chart defaults, so a busy pod can
still burst. Production-like environments use the chart defaults; only this small cluster uses the overlay.

Regenerate after a chart adds a component: every `resources.requests.cpu` above 25m in
`<repo>/charts/<chart>/values.yaml` on develop gets an entry here (the overlay is generated, not hand-written).

## Memory requests (capacity step 2, 2026-11-21)

The charts request 64-128Mi per container while the measured working set of most app pods is 4-45Mi, so the
agent node ran out of memory *requests* (98.9% requested, ~19% used) before it ran out of anything real. Every
overlay now also sets `requests.memory` per component:

- `requests.memory = max(32Mi, round_up_16Mi(1.5 x the 24 h max working set))`, measured from Prometheus
  `max_over_time(container_memory_working_set_bytes[24h])` (Prometheus keeps 1 day);
- limits keep the chart defaults (256Mi for most components); a limit is only raised (to 2 x the request) when the
  24 h max exceeds 70% of it, and is never lowered;
- a request below a burst cannot cause an OOM kill (the limit does); under node memory pressure the pod is only
  evicted earlier.

Re-measure before changing a value, and use the same rule. A component a chart adds later gets the chart default
until its line is added here.

## Disclaimer

This project is a domain-driven design study. It is not associated with, endorsed by or affiliated with any company, and it uses no company's code, data, logos or trademarks. All names, figures and examples are illustrative or synthetic.
