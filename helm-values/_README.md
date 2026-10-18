# Application values

Every application's complete Helm configuration for the local kind cluster lives
here (ADR 0002 D2, `docs/adr/0002-application-delivery-boundary.md`). Each
application's ArgoCD Application has two sources: the chart, from the
application's own repo (`charts/<app>`, `develop`), and this repo
(`ref: values`, `develop`). Its value files, lowest precedence first:

1. `_platform.yaml`: platform facts every chart reads (the Gateway
   `parentRefs`, the Kafka brokers, Kong's traces endpoint and CORS origin).
   Terraform reads them from here and fails the plan if the platform it
   installs disagrees (`terraform/locals.tf`'s `local.platform`).
2. `<app>.yaml`: the application's whole configuration: routes, MCP,
   analytics, consumers, sync-edge env, feature switches.
3. `kind-resources/<app>.yaml`: the kind CPU-request overlay.

The Application's `valuesObject`, which wins over all three, carries only what
Terraform computes: the content-derived image tags (and the ops agent's image,
chosen per machine in `terraform.tfvars`).

Rules:

- **A change here deploys on merge to `develop`**, through an ArgoCD sync, with
  no `terraform apply`; a revert is a Git revert. Check a change before merging
  with `helm template <app> ../../<app>/charts/<app> -f _platform.yaml -f <app>.yaml -f kind-resources/<app>.yaml`.
- **Never a credential.** Charts read credentials from the Secrets Terraform
  creates (`existingSecret`): `<app>-db`, `<app>-analytics-db`,
  `warehouse-ops-agent-anthropic`.
- **Never an image tag.** Terraform sets it (`terraform/modules/application`).
- **Never an env var twice.** `extraEnv` is for env the chart has no dedicated
  value for; setting a variable in both renders a duplicate env entry, which
  breaks ArgoCD's diff (ComparisonError "doesn't match $setElementOrder list").
- Helm deep-merges maps and replaces lists: an `extraEnv` list here replaces the
  chart default's list as a whole.
- Every `*_MODE` env var defaults to `permissive` (no network) when unset; a new
  sync edge needs its `MODE` and `BASE_URL` in the same change. The rollback
  switches are listed in `../docs/rollback-switches.md`.
- `argocd.yaml` is different: the values of Terraform's own ArgoCD
  `helm_release` (`terraform/argocd.tf`), not an application's.
