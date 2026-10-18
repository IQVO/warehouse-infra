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
# (applications.tf, ADR 0002). The role and database names stay here,
# because the platform's initdb script and PgBouncer userlist read them.
#
# NOTE FOR AN ALREADY-RUNNING CLUSTER: Bitnami executes
# primary.initdb.scripts exactly ONCE, against an empty data directory. On a
# cluster whose Postgres already has data, adding a role/database renders the
# SQL but never runs it, and the pod then CrashLoopBackOffs with `password
# authentication failed`. Create them by hand against the live primary,
# mirroring templates/init-databases.sql.tftpl's loop body, using the
# passwords from `terraform output -raw network_fulfillment_db_password` and
# `terraform output -raw network_fulfillment_analytics_db_password`.
# ---------------------------------------------------------------------------
locals {
  network_fulfillment_db_user = "network_fulfillment"
  network_fulfillment_db_name = "network_fulfillment"

  # The "Network Order Acknowledgement & Translation" data product's own
  # analytical database (PR#18 upstream, ADR 0002 there). Its chart's
  # analytics-secret.yaml reads a single ANALYTICS_DATABASE_URL key (both
  # netfulfil-projector and netfulfil-reports use it), so the module writes
  # only that key for this context.
  network_fulfillment_analytics_db_user = "network_fulfillment_analytics"
  network_fulfillment_analytics_db_name = "network_fulfillment_analytics"
}

output "network_fulfillment_db_password" {
  description = "Generated password for the network-fulfillment OLTP role (needed to create the role by hand on an already-initialized Postgres)."
  value       = module.application["network-fulfillment"].db_password
  sensitive   = true
}

output "network_fulfillment_route" {
  description = "Kong/Gateway path this context's REST surface is reachable on."
  value       = "${var.api_path_prefix}/network-fulfillment"
}

output "network_fulfillment_analytics_db_password" {
  description = "Generated password for the network-fulfillment analytics role (needed to create the role by hand on an already-initialized Postgres)."
  value       = module.application["network-fulfillment"].analytics_db_password
  sensitive   = true
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
