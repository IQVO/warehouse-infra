---
name: add-or-change-a-service
description: Register a new bounded context, or change how an existing one is wired, in the warehouse-infra Terraform (services map, analytics and MCP lists, sync-edge env, helm-values, ArgoCD Application). Use when adding a service to local.services, analytics_services or mcp_services, adding per-service env or a *_MODE/BASE_URL pair, or editing a ternary in services.tf.
---

# Add or change a service in warehouse-infra

This repo owns the environment, not the workload: each service's chart lives in that service's own repo. Read `terraform/locals.tf` first; the `local.services` map is the only registry (nothing is auto-discovered).

## 1. Register a new service (database-backed bounded context)

1. Add an entry to `local.services` in `terraform/locals.tf` (`db`, `user`, `port`, `path`, `chart_path`, copy a neighbour). That one entry feeds `terraform/postgres.tf` (role, DB, `<svc>-db` Secret), `terraform/services.tf` (`null_resource.build_and_load`, image tag, `local.service_full_values`), `terraform/argocd-apps.tf` (the `Application`), `terraform/pgbouncer.tf` and `terraform/outputs.tf`.
2. Add `helm-values/<svc>.yaml` (static overlay; see `helm-values/_README.md`). `services.tf` does `yamldecode(file(...))` of it, so a missing file fails `terraform validate`.
3. Opt-in lists: add the name to `local.analytics_services` (`terraform/locals.tf`) if it has a projector/reports pair, and to `local.mcp_services` (`terraform/mcp.tf`) if its repo ships an MCP binary (cmd/mcp there). Both gates (`contains(...)` in `services.tf`) pick it up with no other edit.
4. Keep the hand-maintained chart lists in sync (they are NOT auto-discovered): `CHARTS` in the `Makefile` and `CHARTS` in `scripts/check-chart-selectors.py`.
5. The service's chart must already exist in its own repo at `charts/<repo>/`, with every Service selecting by `app.kubernetes.io/component`.

Exceptions that are NOT in `local.services`: network-fulfillment (`terraform/network-fulfillment.tf`), ops-agent (`terraform/ops-agent.tf`) and the console (`terraform/frontends.tf`) have their own files and their own `kubectl_manifest` in `terraform/argocd-apps.tf`. Do not add network-fulfillment to `analytics_services`: `analytics_db_info` indexes `local.services[name]` and throws a plan-time KeyError. `mcp_services` only needs the name, so it is safe there.

## 2. Per-service env: where it must live

`services.tf` computes `local.service_helm_values` and pre-merges it OVER `helm-values/<svc>.yaml` into `local.service_full_values` (computed wins; only `config` and `analytics` are deep-merged). An `extraEnv` list written in a `helm-values/*.yaml` file is silently dropped and `terraform plan` shows nothing. Put per-service env that has no dedicated chart value into `local.sync_edge_env` (`terraform/locals.tf`).

Every `*_MODE` env var defaults to permissive (no network) when unset. A new sync edge needs its `MODE` and `BASE_URL` both in `sync_edge_env`, in the same PR as the integration. After apply, grep the pod's startup log for `mode":"http"` (or `kafka-cache`) to confirm what the binary chose.

## 3. Conditional blocks and `terraform validate`

Both branches of a ternary must declare the SAME key set, even if one side is inert (`enabled = false`, `extraEnv = []`). Otherwise `terraform validate` fails with "Inconsistent conditional result types". Copy the shape of the `inventory-storage` / `order-management` blocks in `terraform/services.tf`. Never make the branches structurally different. Run `make tf-validate` after every edit.

## 4. Images and rollout (the "local" tag trap, as it is today)

- Service images are content-tagged `local-<first 12 of service_source_hash>` (`local.service_image_tags` in `terraform/services.tf`, `pullPolicy: IfNotPresent`). The hash covers Go files, migrations, the Dockerfile, go.mod and go.sum of the LOCAL sibling checkout, so a Go change makes the tag change and the pod rolls. Never replace it with a fixed `local` tag (frontends are content-tagged the same way, `local.frontend_source_hash` in `terraform/frontends.tf`).
- The hash does NOT cover chart templates, and Terraform no longer installs releases: there is no `helm_release.service`. ArgoCD (`terraform/argocd-apps.tf`, `targetRevision = "develop"`, from GitHub) owns each release with automated prune and selfHeal. A chart template change reaches the cluster only after it is merged to that service repo's `develop` on GitHub and ArgoCD syncs; `terraform apply` will say `0 changed`. Check with `kubectl -n argocd get applications` and `argocd app diff <svc>`.
- The CLAUDE.md older recipe (`terraform taint helm_release.service[...]`, `rollout restart`) predates the ArgoCD hand-off; trust the code. If a pod still runs old code, compare `local.service_image_tags` with the live image, and only then `kubectl rollout restart deployment/<name> -n warehouse-systems`.

## 5. Adding to analytics/mcp on a Postgres that already has data

Bitnami runs `primary.initdb.scripts` once, on an empty data directory. A new entry renders into `terraform/templates/init-databases.sql.tftpl` but never executes on a live cluster, so the projector CrashLoopBackOffs with `password authentication failed`. After apply:

1. Read the generated password with a throwaway `terraform output -raw` (see how `terraform/network-fulfillment.tf` documents it).
2. Run the equivalent `CREATE ROLE` / `CREATE DATABASE` / `REVOKE` / `GRANT` SQL against `postgres-postgresql-0`, mirroring the template's loop body exactly.
3. Only THEN recover the crashed release. The original recipe was SQL first, then `helm rollback`, because the reverse order left the release stuck `pending-upgrade`; that predates the ArgoCD hand-off, so on today's setup prefer an ArgoCD resync of the Application and say so if it behaves differently (unverified).

Never run step 2 against the live cluster without the user's go-ahead.

## 6. Verify

`make check-fast` (quick) then `make check`. See the `run-infra-checks` skill. Cluster-dependent verification is in `deploy-local-checkout`.
