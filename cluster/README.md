# Cluster acceptance (read-only, k3s)

kind is banned (ADR 0011): there is no provisioning mode and no workflow that
builds a cluster. `scripts/run-cluster-acceptance.sh --existing` inspects the
existing k3s cluster (context from `terraform/targets/k3s.tfvars.json`) and only
reads: it waits for Deployments, StatefulSets, Jobs and ArgoCD Applications,
checks every Helm release is `deployed`, runs `smoke-test.sh`,
`test-exposure-policy.sh` and the MCP probe (all eight MCP servers through the
official Go SDK), and writes diagnostics to `artifacts/cluster-acceptance/`.
It does not initialise, plan, apply, remove Terraform state, restart workloads
or delete resources.

Run `scripts/k3s-edges.sh` in another terminal first: the probes reach the
Nginx and Kong edges on 127.0.0.1.

```bash
scripts/run-cluster-acceptance.sh --existing
```

`EXPECTED_FLEET_SHAS` (a JSON map of repository to full commit SHA) makes
`scripts/write_fleet_shas.py` reject missing, extra, dirty or mismatched
checkouts; without it the run only records the checkouts' SHAs.

## Disclaimer

This project is a domain-driven design study. It is not associated with, endorsed by or affiliated with any company, and it uses no company's code, data, logos or trademarks. All names, figures and examples are illustrative or synthetic.
