---
name: add-or-change-a-service
description: Register a new application, or change how an existing one is configured, in warehouse-infra (application registry, local.services, analytics_services, helm-values files, sync-edge env, rollback switches). Use when adding a service to local.services or local.other_applications, editing helm-values/<app>.yaml or _platform.yaml, or adding per-service env or a *_MODE/BASE_URL pair.
---

# Add or change an application in warehouse-infra

This repo owns the environment, not the workload: each application's chart lives in its own repo. Two places hold everything this repo knows about an application (ADR 0002, `docs/adr/0002-application-delivery-boundary.md`; ADR 0004, `docs/adr/0004-one-application-registry.md`):

- **Terraform** (`terraform/applications.tf`): its platform contract. One `terraform/modules/application` instance creates its generated passwords, `<name>-db`/`<name>-analytics-db` Secrets, any extra Secret (`secrets`, e.g. the ops agent's Anthropic key), its image builds with content-derived tags, and its ArgoCD `Application`.
- **Value files** (`helm-values/`): its whole configuration. The Application reads `_platform.yaml`, then `<app>.yaml`, then `kind-resources/<app>.yaml` from this repo's GitHub `develop`; its `valuesObject` carries only the image tags. See `helm-values/_README.md`.

Nothing is auto-discovered.

## 1. Register a new application

1. Its chart must already exist in its own repo at `charts/<repo>/`, with every Service selecting by `app.kubernetes.io/component`.
2. Registry entry:
   - A database-backed context with the shared database naming: an entry in `local.services` (`terraform/locals.tf`: `db`, `user`, `port`, `path`, `chart_path`; copy a neighbour). `local.service_applications` picks it up. Add its literal line to `local.app_passwords` in `terraform/applications.tf` (`"<svc>" = module.application["<svc>"].passwords`); the plan fails with an invalid-index error until you do. Never replace that map with a for expression: a computed module key makes Postgres wait for every image build.
   - Anything else: an explicit entry in `local.other_applications` (`terraform/applications.tf`). Static sites declare `frontend = { dir = ".", values_key = "image" }`; an image pulled from a registry is `image = null`.
3. If it has a projector/reports pair: add it to `local.analytics_services` (`terraform/locals.tf`), which gives it an analytics database and the `<svc>-analytics-db` Secret. Do not add network-fulfillment there: `analytics_db_info` indexes `local.services[name]` and throws a plan-time KeyError.
4. If its repo ships a frontend remote: add it to `local.frontend_remotes` (`terraform/frontends.tf`) for the image build and the web gateway route.
5. Values: create `helm-values/<app>.yaml` (its complete configuration: copy a sibling's routes, MCP, analytics, Kong plugin blocks) and `helm-values/kind-resources/<app>.yaml` (generated CPU overlay; see that directory's README). The plan fails while either is missing. Credentials come from `existingSecret` (`<app>-db`, `<app>-analytics-db`), never a value; image tags never appear here.
6. Keep the hand-maintained chart lists in sync: `CHARTS` in the `Makefile` and `CHARTS` in `scripts/check-chart-selectors.py`.

## 2. Change an application's configuration

- Edit `helm-values/<app>.yaml` (or `_platform.yaml` for a platform fact every chart reads). Check it renders before merging:
  `helm template <app> ../<app>/charts/<app> -n warehouse-systems -f helm-values/_platform.yaml -f helm-values/<app>.yaml -f helm-values/kind-resources/<app>.yaml`
- It deploys on merge to `develop`: ArgoCD re-renders and rolls what changed. `terraform apply` never sees it; a revert is a Git revert.
- A platform fact in `_platform.yaml` (Gateway parentRefs, Kafka brokers, Kong traces endpoint, CORS origin) is also read by Terraform (`local.platform`); a precondition fails the plan if the platform Terraform installs disagrees.

## 3. Per-service env and sync edges

- Use the chart's dedicated value when it has one. `extraEnv` in `helm-values/<app>.yaml` is only for env the chart does not render: setting a variable both ways renders a duplicate env entry, which breaks ArgoCD's three-way diff (ComparisonError "doesn't match $setElementOrder list").
- Helm replaces lists: `extraEnv` in the values file replaces the chart default's list whole.
- Every `*_MODE` env var defaults to permissive (no network) when unset. A new sync edge needs its `MODE` and `BASE_URL` both in the consumer's values file, in the same PR as the integration. After the sync, grep the pod's startup log for `mode":"http"` (or `kafka-cache`) to confirm what the binary chose.
- Rollback switches (edges built but off) are listed with their exact flip in `docs/rollback-switches.md`.

## 4. Images and rollout (the "local" tag trap, as it is today)

- Images are content-tagged `local-<first 12 of the source hash>` (computed in `terraform/modules/application`, `pullPolicy: IfNotPresent`). The hash covers every file the Dockerfile copies in: Go files, migrations, the Dockerfile, go.mod and go.sum of the LOCAL sibling checkout, so a Go change makes the tag change and the pod rolls. Never replace it with a fixed `local` tag (frontends are content-tagged the same way, `local.frontend_source_hash` in `terraform/frontends.tf`).
- The hash does NOT cover chart templates, and Terraform installs no releases. ArgoCD (the module's `Application`, chart from the service repo's GitHub `develop`) owns each release with automated prune and selfHeal. A chart template change reaches the cluster only after it is merged to that repo's `develop` and ArgoCD syncs; `terraform apply` will say `0 changed`. Check with `kubectl -n argocd get applications` and `argocd app diff <svc>`.
- If a pod still runs old code, compare `module.application["<svc>"].image_tag` (`terraform console`) with the live image, and only then `kubectl rollout restart deployment/<name> -n warehouse-systems`.

## 5. A new database or analytics database on a Postgres that already has data

Bitnami runs `primary.initdb.scripts` once, on an empty data directory. A new entry renders into `terraform/templates/init-databases.sql.tftpl` but never executes on a live cluster, so the pod CrashLoopBackOffs with `password authentication failed`. After apply:

1. Read the generated password with a throwaway `terraform output -raw` (see how `terraform/network-fulfillment.tf` documents it).
2. Run the equivalent `CREATE ROLE` / `CREATE DATABASE` / `REVOKE` / `GRANT` SQL against `postgres-postgresql-0`, mirroring the template's loop body exactly.
3. Only THEN recover the crashed workload: an ArgoCD resync of the Application.

Never run step 2 against the live cluster without the user's go-ahead.

## 6. Verify

`make check-fast` (quick) then `make check`. See the `run-infra-checks` skill. Cluster-dependent verification is in `deploy-local-checkout`.
