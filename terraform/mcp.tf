# ---------------------------------------------------------------------------
# MCP servers (each context's ADR-0008 "MCP inbound adapter"). Each of the
# five contexts warehouse-ops-agent consumes ships a `cmd/mcp` binary in its
# image and an `mcp.*` block in its chart (mcp-deployment/-service, Service
# `<release>-mcp` on port 8090, Streamable HTTP at `/` and `/mcp`, open
# `/healthz` for the probes). Until 2026-09-07 none of this was deployed
# anywhere -- see the header comment that used to live in ops-agent.tf -- so
# the agent's MCP upstreams were all empty.
#
# Static-bearer MCP auth (read/read-write keys) was removed fleet-wide (the
# nine backend repos' MCP servers are now unauthenticated) -- see each
# repo's "remove REST OIDC and MCP static bearer auth" PR. This file now
# only computes which contexts have an MCP server and where it lives;
# `var.deploy_mcp_servers` still gates whether the MCP *server* itself is
# deployed, a separate, still-valid concern from auth.
# ---------------------------------------------------------------------------

locals {
  mcp_services = toset([
    "fulfillment-execution",
    "wes-work-planning",
    "inventory-storage",
    "workforce-management",
    "facility-layout",
    # Added 2026-09-11 (fleet-wide bounded-context wiring plan, Phase 1):
    # order-management and labor-performance already shipped a `cmd/mcp`
    # binary but had no chart templates to deploy it (mcp_cmd=1,
    # chart_mcp=0 in the wiring audit); process-path-management had no MCP
    # server at all until this same wiring pass built one (two read-only
    # tools: get_process_path, list_process_paths). All three now carry
    # identical mcp-deployment/-service chart templates to the five
    # contexts above, so `services.tf`'s existing
    # `contains(local.mcp_services, each.key)` gate picks them up with no
    # further change needed there.
    "order-management",
    "labor-performance",
    "process-path-management",
  ])

  mcp_endpoint = {
    for name in local.mcp_services :
    name => "http://${name}-mcp.${var.apps_namespace}.svc.cluster.local:8090/mcp"
  }
}
