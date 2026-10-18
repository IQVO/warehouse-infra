---
name: add-or-change-a-service
description: Register a new application, or change how an existing one is configured, in warehouse-infra (application registry apps.yaml, helm-values files, sync-edge env, rollback switches). Use when adding an application to terraform/apps.yaml, editing helm-values/<app>.yaml or _platform.yaml, or adding per-service env or a *_MODE/BASE_URL pair.
---

# Add or change an application in warehouse-infra

This repo owns the environment, not the workload: each application's chart lives in its own repo. Two places hold everything this repo knows about an application (ADR 0002, `docs/adr/0002-application-delivery-boundary.md`; ADR 0004, `docs/adr/0004-one-application-registry.md`):

- **Terraform** (`terraform/applications.tf`): its platform contract. One `terraform/modules/application` instance creates its generated passwords, `<name>-db`/`<name>-analytics-db` Secrets, any extra Secret (`secrets`, e.g. the ops agent's Anthropic key), its image builds with content-derived tags, and its ArgoCD `Application`.
- **Value files** (`helm-values/`): its whole configuration. The Application reads `_platform.yaml`, then `<app>.yaml`, then `kind-resources/<app>.yaml` from this repo's GitHub `develop`; its `valuesObject` carries only the image tags. See `helm-values/_README.md`.

Nothing is auto-discovered.

## 1. Register a new application

1. Its chart must already exist in its own repo at `charts/<repo>/`, with every Service selecting by `app.kubernetes.io/component`.
2. Registry entry in `terraform/apps.yaml` (its header documents every field). Copy a neighbour:
   - A database-backed context: `kind: service`, `database: true`. Names follow the convention (dashes become underscores); nothing else is registered by hand, the module creates its role and database in Postgres through a Job (ADR 0005).
   - Anything else: `kind: other`. Static sites say `build_image: false` and `site: true`; an image pulled from a registry says `build_image: false`. A secret whose value comes from a Terraform variable goes in `local.application_secrets` (`terraform/applications.tf`).
3. If it has a projector/reports pair: `analytics: true` (or `analytics: { secret_keys: [...] }` when its chart reads fewer keys than the default pair). That gives it the analytics database and the `<svc>-analytics-db` Secret.
4. If its repo ships a frontend remote: `frontend_remote: <module-federation name>` for the image build and the web gateway route.
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

## 5. A new database or analytics database

Nothing to do by hand. `modules/application` runs `modules/database` for the OLTP role and for the analytics role (ADR 0005): a Job creates the role and the database, or brings the role to the generated password, and the `Application` waits for it. This works the same on an empty Postgres and on one that already has data.

- A failed Job fails the apply after six retries. Read it with `kubectl -n warehouse-data logs job/provision-<name>` (`<name>-analytics` for the analytics role).
- Removing an application removes its Job and Secret, never its role or database. Dropping data is a separate step that needs the user's go-ahead.

## 6. Verify

`make check-fast` (quick) then `make check`. See the `run-infra-checks` skill. Cluster-dependent verification is in `deploy-local-checkout`.
