# CPU-request overlays (directory name is a legacy of the retired kind environment)

One file per ArgoCD Application: the LAST of its three value files (ADR 0002 D2,
`docs/adr/0002-application-delivery-boundary.md`):

1. `helm-values/_platform.yaml`
2. `helm-values/<app>.yaml`
3. `helm-values/kind-resources/<app>.yaml` (this directory)

Helm deep-merges value files over the chart's `values.yaml`, so an overlay changes only
`requests.cpu`. ArgoCD reads these files from this repo's GitHub `develop`: an overlay change
deploys on merge, through an ArgoCD sync, with no `terraform apply`. The Terraform plan fails
while an application's overlay file is missing (`terraform/modules/application`).

Why: a k3s node has a few CPUs and a 110-pod cap. The charts request 50-100m CPU
per container (about 10 cores for ~76 app containers) while measured use is ~10% of that. Every Deployment
runs 1 replica with the default RollingUpdate (maxSurge 25% -> 1 extra pod), so an apply that rolls many
services at once left the new pods Pending ("Insufficient cpu") and the rollout stalled (2026-10-14).

What they change: `requests.cpu` -> 25m for every component whose chart default is above that (API, MCP,
analytics projector/reports, frontend, console). Limits and memory keep the chart defaults, so a busy pod can
still burst. Production-like environments use the chart defaults; only this small cluster uses the overlay.

Regenerate after a chart adds a component: every `resources.requests.cpu` above 25m in
`<repo>/charts/<chart>/values.yaml` on develop gets an entry here (the overlay is generated, not hand-written).

## Disclaimer

This project is a domain-driven design study. It is not associated with, endorsed by or affiliated with any company, and it uses no company's code, data, logos or trademarks. All names, figures and examples are illustrative or synthetic.
