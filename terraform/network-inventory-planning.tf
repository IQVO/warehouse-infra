# ---------------------------------------------------------------------------
# network-inventory-planning (NIP) — the fleet's inter-warehouse transfer
# planning context. It publishes TransferAllocationRequested commands and
# WorkDemandReleased facts onto warehouse.network-inventory-planning.events,
# consumed by inventory-storage's site-scoped allocation consumer
# (ADR-0030 there, enabled in ../helm-values/inventory-storage.yaml) and by
# wes-work-planning's inbound integration consumer as its FIFTH topic
# (IQVO/wes-work-planning#150 — no env or chart value there: the topic is a
# hardcoded constant on the existing consumer group). The chart lives in
# NIP's own repo; this file is the environment overlay.
#
# Its platform contract (generated passwords, the network-inventory-planning-db
# and network-inventory-planning-analytics-db Secrets, the API and frontend
# image builds, the ArgoCD Application) is created by modules/application
# (applications.tf, ADR 0002: docs/adr/0002-application-delivery-boundary.md),
# and its configuration lives in helm-values/network-inventory-planning.yaml
# (ADR 0002 D2). This file keeps the database names the platform reads and
# the outputs.
#
# NOT in `local.services`: that map's entries share one chart shape (and
# one database naming rule), which NIP's chart and databases do not.
#
# Kafka topics: NO declaration in this repo is the fleet norm. Every
# business topic (see kafka.tf's overrideConfiguration comment and
# docs/kafka-partition-scaleup.md) is auto-created by its first writer
# with the broker's num.partitions=8 / replication-factor-1 overrides;
# there is no kafka_topic resource and no topic manifest to add.
# warehouse.network-inventory-planning.events and
# warehouse.network-inventory-planning.analytics (NIP's analytics stream
# name follows the warehouse.<context>.analytics convention) take that
# same path, so kafka.tf is untouched by design.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# OLTP database names. The role and database are created by the initdb
# script (postgres.tf) with the module's generated password.
#
# NOTE FOR AN ALREADY-RUNNING CLUSTER: Bitnami executes
# primary.initdb.scripts exactly ONCE, against an empty data directory. On
# a cluster whose Postgres already has data, a new role/database here
# renders the SQL but never runs it. Create them by hand against the live
# primary, mirroring templates/init-databases.sql.tftpl's loop body, using
# the password from
# `terraform output -raw network_inventory_planning_db_password`.
# ---------------------------------------------------------------------------
locals {
  network_inventory_planning_db_user = "network_inventory_planning"
  network_inventory_planning_db_name = "network_inventory_planning"
}

output "network_inventory_planning_db_password" {
  description = "Generated password for the network-inventory-planning OLTP role (needed to create the role by hand on an already-initialized Postgres)."
  value       = module.application["network-inventory-planning"].db_password
  sensitive   = true
}

output "network_inventory_planning_route" {
  description = "Kong/Gateway path this context's REST surface is reachable on."
  value       = "${var.api_path_prefix}/network-inventory-planning"
}

# ---------------------------------------------------------------------------
# Analytics database names (NIP ADR 0009): the saga-health data product's own
# analytical Postgres database. The module generates its password and writes
# the network-inventory-planning-analytics-db Secret (ANALYTICS_DATABASE_URL
# and ANALYTICS_READER_DATABASE_URL, the same DIRECT DSN for both: the
# projector also runs the analytical migrations, which take a session-scoped
# advisory lock PgBouncer's transaction pooling cannot honour).
#
# Same NOTE as the OLTP database above: on an already-initialized Postgres,
# create the role/database by hand using
# `terraform output -raw network_inventory_planning_analytics_db_password`
# (README "Network inventory planning (NIP) runbook").
# ---------------------------------------------------------------------------
locals {
  network_inventory_planning_analytics_db_user = "network_inventory_planning_analytics"
  network_inventory_planning_analytics_db_name = "network_inventory_planning_analytics"
}

output "network_inventory_planning_analytics_db_password" {
  description = "Generated password for the network-inventory-planning analytics role (needed to create the role by hand on an already-initialized Postgres)."
  value       = module.application["network-inventory-planning"].analytics_db_password
  sensitive   = true
}

# Reports route: DELETED (fleet decision 2026-10-13) — the chart's own
# reports-route.yaml renders it (/api/<context>/reports -> /reports), switched
# on by the analytics.reports.route values in its helm-values file.
# The old kubectl-applied Ingress/HTTPRoute here silently vanished on cluster
# rebuild; chart-rendered routes are Helm/ArgoCD-reconciled forever.

output "network_inventory_planning_reports_route" {
  description = "Kong/Gateway path this context's analytics reports Service is reachable on."
  value       = "${var.api_path_prefix}/network-inventory-planning/reports"
}
