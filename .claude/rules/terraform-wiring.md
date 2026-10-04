---
paths:
  - "terraform/**/*.tf"
  - "terraform/templates/**"
  - "helm-values/**"
---

# Terraform wiring and values (loaded when you touch terraform/ or helm-values/)

Step-by-step recipes are in the skills `add-or-change-a-service` and `deploy-local-checkout`. These are the rules behind them.

- `local.services` in `terraform/locals.tf` is the single registry; nothing is auto-discovered. A new repo must be added by hand and its chart must already exist in its own repo.
- `terraform apply` does not see chart-template changes (`service_source_hash` in `terraform/services.tf` hashes Go source, migrations, Dockerfile, go.mod and go.sum only). Charts are installed by ArgoCD from the service repo's GitHub `develop` (`terraform/argocd-apps.tf`); there is no `helm_release.service` any more. A chart edit reaches the cluster via merge to that repo's `develop` plus an ArgoCD sync.
- Images come from the LOCAL sibling checkout, not `origin/develop`. Pull the checkout (`git -C ~/warehouse-systems/<repo> pull --ff-only origin develop`) before an apply, and verify the code is in the tree.
- Image tags are content-derived (`local-<hash12>`, `local.service_image_tags`; frontends via `local.frontend_source_hash` in `terraform/frontends.tf`). Never simplify back to a fixed `local` tag: a rebuilt image would not roll. After an apply that only rebuilt an image, still confirm with `kubectl rollout status` and the live image tag; "apply succeeded" plus "Running" is not proof the new code is live.
- Both branches of a ternary must declare the same key set, even if one is inert (`enabled = false`, `extraEnv = []`), or `terraform validate` fails with "Inconsistent conditional result types".
- The computed layer (`local.service_helm_values` merged into `local.service_full_values` in `terraform/services.tf`) overrides `helm-values/*.yaml`. An `extraEnv` in a helm-values file is silently dropped; put per-service env in `local.sync_edge_env`.
- Every `*_MODE` env var defaults to `permissive` (no network) if unset. A new sync edge needs its `MODE` and `BASE_URL` in `local.sync_edge_env` in the SAME PR. Confirm with the pod's startup log (`mode":"http"`).
- Adding to `analytics_services` or `mcp_services` on a Postgres that already has data does nothing on its own: Bitnami runs `primary.initdb.scripts` once on an empty data dir, and `terraform/templates/init-databases.sql.tftpl` never re-executes. Create the role and database by hand (mirror the template loop body), with the user's go-ahead. See `add-or-change-a-service` section 5 for ordering.
- Services outside `local.services` (network-fulfillment, ops-agent, console) have their own files. Never add network-fulfillment to `local.analytics_services`: `analytics_db_info` would KeyError at plan time.
- `terraform destroy` leaves about 60 phantom resources in state: back up the tfstate, confirm `kind get clusters` shows none, then `terraform state rm` each. Details in `deploy-local-checkout`.
- Never add an `EVENT_ENVELOPE_MODE` or similar toggle (see the events rule).
