# ---------------------------------------------------------------------------
# kind CPU-request overlay, merged INTO each ArgoCD Application's valuesObject.
#
# The overlays in ../helm-values/kind-resources/<app>.yaml lower requests.cpu
# to 25m for every component (API, MCP, analytics projector/reports, frontend,
# console) because the kind cluster is ONE worker with the Docker VM's 10 CPUs:
# the chart defaults requested ~99% of it while real use was ~9%, so rolling
# updates (maxSurge 1 per Deployment) could not schedule.
#
# They are merged here, not passed as helm.values: ArgoCD (v2.13) renders ONLY
# helm.valuesObject when both are set (valuesObject replaces values; they are
# two spellings of one field), so a separate helm.values string is silently
# ignored -- found live on 2026-10-14 (warehouse-infra#81 shipped that form).
#
# Terraform's merge() is shallow, so the merge is explicit at the levels the
# overlays use: top-level resources/mcp/frontend, and analytics.projector /
# analytics.reports. No values file sets resources under those keys (checked
# with terraform console), so the overlay only adds requests.cpu and Helm
# deep-merges it over the chart defaults (limits and memory unchanged).
# ---------------------------------------------------------------------------
locals {
  kind_overlay = {
    for f in fileset("${path.module}/../helm-values/kind-resources", "*.yaml") :
    trimsuffix(f, ".yaml") => yamldecode(file("${path.module}/../helm-values/kind-resources/${f}"))
  }

  argocd_service_values = {
    for name, base in local.service_full_values :
    name => merge(
      base,
      { for k in ["resources", "mcp", "frontend"] : k => merge(try(base[k], {}), local.kind_overlay[name][k]) if can(local.kind_overlay[name][k]) },
      can(local.kind_overlay[name].analytics) ? { analytics = merge(try(base.analytics, {}), { for s in ["projector", "reports"] : s => merge(try(base.analytics[s], {}), local.kind_overlay[name].analytics[s]) if can(local.kind_overlay[name].analytics[s]) }) } : {},
    )
  }

  argocd_ops_agent_values = merge(
    local.ops_agent_helm_values,
    { for k in ["resources", "mcp", "frontend"] : k => merge(try(local.ops_agent_helm_values[k], {}), local.kind_overlay["warehouse-ops-agent"][k]) if can(local.kind_overlay["warehouse-ops-agent"][k]) },
    can(local.kind_overlay["warehouse-ops-agent"].analytics) ? { analytics = merge(try(local.ops_agent_helm_values.analytics, {}), { for s in ["projector", "reports"] : s => merge(try(local.ops_agent_helm_values.analytics[s], {}), local.kind_overlay["warehouse-ops-agent"].analytics[s]) if can(local.kind_overlay["warehouse-ops-agent"].analytics[s]) }) } : {},
  )
  argocd_network_fulfillment_values = merge(
    local.network_fulfillment_helm_values,
    { for k in ["resources", "mcp", "frontend"] : k => merge(try(local.network_fulfillment_helm_values[k], {}), local.kind_overlay["network-fulfillment"][k]) if can(local.kind_overlay["network-fulfillment"][k]) },
    can(local.kind_overlay["network-fulfillment"].analytics) ? { analytics = merge(try(local.network_fulfillment_helm_values.analytics, {}), { for s in ["projector", "reports"] : s => merge(try(local.network_fulfillment_helm_values.analytics[s], {}), local.kind_overlay["network-fulfillment"].analytics[s]) if can(local.kind_overlay["network-fulfillment"].analytics[s]) }) } : {},
  )
  argocd_network_inventory_planning_values = merge(
    local.network_inventory_planning_helm_values,
    { for k in ["resources", "mcp", "frontend"] : k => merge(try(local.network_inventory_planning_helm_values[k], {}), local.kind_overlay["network-inventory-planning"][k]) if can(local.kind_overlay["network-inventory-planning"][k]) },
    can(local.kind_overlay["network-inventory-planning"].analytics) ? { analytics = merge(try(local.network_inventory_planning_helm_values.analytics, {}), { for s in ["projector", "reports"] : s => merge(try(local.network_inventory_planning_helm_values.analytics[s], {}), local.kind_overlay["network-inventory-planning"].analytics[s]) if can(local.kind_overlay["network-inventory-planning"].analytics[s]) }) } : {},
  )
  argocd_ecosystem_values = merge(
    local.ecosystem_helm_values,
    { for k in ["resources", "mcp", "frontend"] : k => merge(try(local.ecosystem_helm_values[k], {}), local.kind_overlay["ecosystem"][k]) if can(local.kind_overlay["ecosystem"][k]) },
  )
  argocd_console_values = merge(
    local.console_helm_values,
    { for k in ["resources", "mcp", "frontend"] : k => merge(try(local.console_helm_values[k], {}), local.kind_overlay["warehouse-console"][k]) if can(local.kind_overlay["warehouse-console"][k]) },
    can(local.kind_overlay["warehouse-console"].analytics) ? { analytics = merge(try(local.console_helm_values.analytics, {}), { for s in ["projector", "reports"] : s => merge(try(local.console_helm_values.analytics[s], {}), local.kind_overlay["warehouse-console"].analytics[s]) if can(local.kind_overlay["warehouse-console"].analytics[s]) }) } : {},
  )
}
