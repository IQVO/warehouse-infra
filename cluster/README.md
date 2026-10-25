# Clean-cluster acceptance

`cluster-acceptance.yml` owns an ephemeral kind cluster on a disposable GitHub
Actions runner. It checks out the complete deployable fleet as siblings, records
the exact commit of every checkout, provisions through `scripts/up.sh`, waits for
Terraform/Helm/ArgoCD/Istio convergence, then verifies all API routes, all eight
MFE remotes plus resolved chunks, the shell split-edge policy, and all eight MCP
servers through the official Go SDK. A second Terraform plan must return exit 0.
Diagnostics are uploaded even when acceptance fails.

## Safety boundary

Never run `scripts/run-cluster-acceptance.sh --provision` on a workstation with
the live `warehouse` cluster. Provision mode refuses to continue if the target
kind cluster name already existed when the script started; it has no destroy or
cluster-delete path. Stale Terraform state can be cleared only in provision mode,
only after the target cluster is confirmed absent, and only when
`CLUSTER_ACCEPTANCE_CLEAR_STALE_STATE=1` is explicit.

For a non-mutating inspection of an existing cluster, use:

```bash
scripts/run-cluster-acceptance.sh --existing
```

Existing-cluster mode performs only reads, waits/watches, port-forwards, and
local artifact writes. It does not initialize, plan, apply, remove Terraform
state, restart workloads, or delete resources.

## Exact fleet-SHA release gate

Manual dispatch accepts `fleet_shas`, a JSON object containing every repository
name and its full 40-character commit SHA. Every checkout uses that map, and the
preflight plus acceptance entry point reject missing, extra, dirty, or mismatched
checkouts before provisioning. Passing `{}` intentionally tests the current
`develop` heads and records them, but it is not an exact release gate.

Example shape (all repositories are required for release gating):

```json
{
  "warehouse-infra": "<40-char-sha>",
  "order-management": "<40-char-sha>",
  "inventory-storage": "<40-char-sha>",
  "wes-work-planning": "<40-char-sha>",
  "fulfillment-execution": "<40-char-sha>",
  "workforce-management": "<40-char-sha>",
  "facility-layout": "<40-char-sha>",
  "labor-performance": "<40-char-sha>",
  "process-path-management": "<40-char-sha>",
  "warehouse-ops-agent": "<40-char-sha>",
  "network-fulfillment": "<40-char-sha>",
  "warehouse-console": "<40-char-sha>",
  "warehouse-ui-kit": "<40-char-sha>",
  "warehouse-docs": "<40-char-sha>",
  "e2e-tests": "<40-char-sha>"
}
```
