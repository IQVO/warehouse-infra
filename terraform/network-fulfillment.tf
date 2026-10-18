# ---------------------------------------------------------------------------
# network-fulfillment — the fleet's Anti-Corruption Layer to an external
# retail network (Amazon Vendor Direct Fulfillment). The chart lives in its
# own repo, its configuration in helm-values/network-fulfillment.yaml (ADR
# 0002 D2, including why config.networkMode stays "stub" on this cluster),
# and its platform contract (image builds, generated passwords, Secrets,
# ArgoCD Application) in modules/application (applications.tf). This file
# keeps the database names the platform reads and the outputs.
# ---------------------------------------------------------------------------



# ---------------------------------------------------------------------------
# Databases. The generated passwords, the network-fulfillment-db Secret
# (DATABASE_URL through PgBouncer, MIGRATIONS_DATABASE_URL direct) and the
# network-fulfillment-analytics-db Secret come from modules/application
# (applications.tf, ADR 0002), which also creates the roles and databases in
# Postgres (ADR 0005). Their names derive from the registry entry (apps.yaml):
# network_fulfillment and network_fulfillment_analytics. Its chart's
# analytics-secret.yaml reads a single ANALYTICS_DATABASE_URL key (netfulfil-
# projector and netfulfil-reports both use it), so the entry says so.
# ---------------------------------------------------------------------------
output "network_fulfillment_route" {
  description = "Kong/Gateway path this context's REST surface is reachable on."
  value       = "${var.api_path_prefix}/network-fulfillment"
}

# Reports route: DELETED (fleet decision 2026-10-13) — the chart's own
# reports-route.yaml renders it (/api/<context>/reports -> /reports), switched
# on by the analytics.reports.route values in its helm-values file.
# The old kubectl-applied Ingress/HTTPRoute here silently vanished on cluster
# rebuild; chart-rendered routes are Helm/ArgoCD-reconciled forever.

output "network_fulfillment_reports_route" {
  description = "Kong/Gateway path this context's analytics reports Service is reachable on."
  value       = "${var.api_path_prefix}/network-fulfillment/reports"
}
