# ---------------------------------------------------------------------------
# MCP servers (each context's ADR-0008 "MCP inbound adapter"). Each of the
# five contexts warehouse-ops-agent consumes ships a `cmd/mcp` binary in its
# image and an `mcp.*` block in its chart (mcp-deployment/-service/-secret,
# Service `<release>-mcp` on port 8090, Streamable HTTP at `/` and `/mcp`,
# unauthenticated `/healthz` for the probes). Until 2026-09-07 none of this
# was deployed anywhere -- see the header comment that used to live in
# ops-agent.tf -- so the agent's MCP upstreams were all empty.
#
# One read key and one read-write key per context. The read key is what
# warehouse-ops-agent receives (its v1 posture is read-only, per its own
# governance note); the read-write key is provisioned now so a later
# write-capable slice needs no infra change, but is handed to nobody yet.
# ---------------------------------------------------------------------------

locals {
  mcp_services = toset([
    "fulfillment-execution",
    "wes-work-planning",
    "inventory-storage",
    "workforce-management",
    "facility-layout",
  ])

  mcp_endpoint = {
    for name in local.mcp_services :
    name => "http://${name}-mcp.${var.apps_namespace}.svc.cluster.local:8090/mcp"
  }
}

resource "random_password" "mcp_read_key" {
  for_each = var.deploy_mcp_servers ? local.mcp_services : toset([])

  length  = 40
  special = false
}

resource "random_password" "mcp_readwrite_key" {
  for_each = var.deploy_mcp_servers ? local.mcp_services : toset([])

  length  = 40
  special = false
}
