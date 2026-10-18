---
paths:
  - "terraform/**/*.tf"
  - "terraform/templates/**"
  - "helm-values/**"
---

# Terraform wiring and values (loaded when you touch terraform/ or helm-values/)

Step-by-step recipes are in the skills `add-or-change-a-service` and `deploy-local-checkout`. These are the rules behind them.

- `local.applications` in `terraform/applications.tf` is the single registry (every `local.services` context plus `local.other_applications`); nothing is auto-discovered. A new repo must be added by hand and its chart must already exist in its own repo.
- `terraform apply` does not see chart-template changes (the image hash in `terraform/modules/application` covers Go source, migrations, Dockerfile, go.mod and go.sum only). Charts are installed by ArgoCD from the service repo's GitHub `develop` (the module's `kubectl_manifest.application`); there is no `helm_release.service` any more. A chart edit reaches the cluster via merge to that repo's `develop` plus an ArgoCD sync.
- Images come from the LOCAL sibling checkout, not `origin/develop`. Pull the checkout (`git -C ~/warehouse-systems/<repo> pull --ff-only origin develop`) before an apply, and verify the code is in the tree.
- Image tags are content-derived (`local-<hash12>`, set by `terraform/modules/application`; frontend hashes come from `local.frontend_source_hash` in `terraform/frontends.tf`). Never simplify back to a fixed `local` tag: a rebuilt image would not roll. After an apply that only rebuilt an image, still confirm with `kubectl rollout status` and the live image tag; "apply succeeded" plus "Running" is not proof the new code is live.
- Application configuration is NOT Terraform (ADR 0002 D2): each Application reads `helm-values/_platform.yaml`, `helm-values/<app>.yaml` and `helm-values/kind-resources/<app>.yaml` from this repo's GitHub `develop`, and its `valuesObject` carries only image tags (plus the ops agent's image from tfvars). A values change deploys on merge through an ArgoCD sync; `terraform apply` never sees it. Check one with `helm template` against the sibling chart before merging (`helm-values/_README.md`). Never write a credential or an image tag in a values file.
- Platform facts the charts read (Gateway parentRefs, Kafka brokers, Kong traces endpoint, CORS origin) live only in `helm-values/_platform.yaml`; Terraform reads them through `local.platform`, and preconditions on the Gateway, Kafka, Collector and web gateway fail the plan when a variable disagrees.
- Never set an env var twice: `extraEnv` is only for env with no dedicated chart value. A duplicate env entry breaks ArgoCD's three-way diff (ComparisonError "doesn't match $setElementOrder list").
- Every `*_MODE` env var defaults to `permissive` (no network) if unset. A new sync edge needs its `MODE` and `BASE_URL` in the consumer's values file in the SAME PR. Confirm with the pod's startup log (`mode":"http"`).
- Adding to `local.services` or `analytics_services` on a Postgres that already has data does nothing on its own: Bitnami runs `primary.initdb.scripts` once on an empty data dir, and `terraform/templates/init-databases.sql.tftpl` never re-executes. Create the role and database by hand (mirror the template loop body), with the user's go-ahead. See `add-or-change-a-service` section 5 for ordering.
- Applications outside `local.services` (network-inventory-planning, network-fulfillment, ops-agent, console, EventCatalog) have an explicit entry in `local.other_applications`; every application, these included, has its values file in `helm-values/`. Never add network-fulfillment to `local.analytics_services`: `analytics_db_info` would KeyError at plan time.
- Every application gets its passwords, Secrets, image builds and `Application` from `terraform/modules/application` (ADR 0002 D3, `docs/adr/0004-one-application-registry.md`); no root resource creates any of them. The module sets `image.tag` itself, so values passed to it never read the module's outputs (that is a cycle). Reference its outputs with a literal key (`module.application["order-management"].db_password`), never `module.application[name]` in a for expression: a computed key depends on `module.application (close)`, i.e. every build and Application (`terraform graph` shows it). A new database-backed application needs its literal line in `local.app_passwords`.
- Moving a resource into or out of the module ships a `moved` block in `terraform/moved-applications.tf` and a plan-parity check (same actions and values at the new address).
- `terraform destroy` leaves about 60 phantom resources in state: back up the tfstate, confirm `kind get clusters` shows none, then `terraform state rm` each. Details in `deploy-local-checkout`.
- Never add an `EVENT_ENVELOPE_MODE` or similar toggle (see the events rule).
