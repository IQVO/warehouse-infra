# Project: warehouse-infra

Terraform + Helm deployment of the entire `warehouse-systems` fleet onto a
local `kind` cluster named `warehouse`. This repo owns the cluster's
existence, not any bounded context's business logic — it is infrastructure
glue, one Terraform root module plus one Helm chart per deployed service
(sourced from that service's own repo).

> **Study project.** Personal DDD/hexagonal-architecture/Kubernetes learning
> exercise. Not a production system; no uptime or support guarantee.

## What this repo actually deploys

`terraform/locals.tf`'s `local.services` map is the **single source of
truth** for what gets deployed. It does NOT auto-discover sibling repos — a
new bounded-context repo must be added here by hand, and its own chart
under `charts/<repo>/` must already exist, or it is never deployed no
matter how complete the service's own code is. Before answering "is
everything running" or "what does the cluster know about", read this file
first — it directly answers "what does Terraform even know about."

Layout:
```
terraform/          Root Terraform config: helm_release per service, Kafka,
                     Postgres instances, MCP servers, ArgoCD, dashboards,
                     the Nginx/Kong localhost edge
helm-values/         Per-service Helm values files (the STATIC layer — see
                     the computed-extraEnv pitfall below)
config/process-paths/  Process-path seed data consumed by seed-process-paths.py
scripts/             Cluster lifecycle (up/down), smoke tests, exposure
                     policy assertions, dashboard generation, chart
                     selector conformance
docs/                Analytics envelope/governance, observability, the
                     localhost edge topology decision record
.github/workflows/ci.yml  terraform fmt/validate, helm-lint,
                          chart-selector-check, shellcheck (added Phase 2
                          of the harness-coverage-expansion plan)
Makefile              make check / make check-all — mirrors ci.yml 1:1
```

Each deployed service's chart actually lives in **that service's own
repo** (`<repo>/charts/<repo>/`), not here — this repo only references it
via a relative path (`../../<repo>/charts/<repo>`) from `terraform/`. A
`terraform validate`/`plan` run from a worktree under `.worktrees/` will
fail with `filesha256(...): no such file` unless the sibling repos are
symlinked alongside the worktree — see the pitfall below.

## Non-negotiables (read before touching Terraform or a chart)

1. **`terraform apply` does NOT pick up chart-template changes.**
   `local.services`' `service_source_hash` covers each service's Go source
   + migrations, NOT its `charts/<svc>/templates/*.yaml`. Editing a chart
   template changes nothing Terraform can see — `apply` reports `0
   changed` and the Helm release keeps its OLD render. Force it with
   `terraform taint 'helm_release.service["<svc>"]'` then re-apply (destroy
   +recreate, which is fine for this local cluster).

2. **Terraform builds images from the LOCAL sibling checkout, not
   `origin/develop`.** Merging a PR on GitHub changes nothing `apply`
   builds until `~/warehouse-systems/<repo>` itself is pulled to that
   commit. Always `git -C ~/warehouse-systems/<repo> pull --ff-only origin
   develop` before applying, and verify the new code is actually present
   in the working tree before assuming a fresh apply will pick it up.

3. **A rebuilt image alone does not roll a running Deployment.** Every
   service chart pins `image.tag: "local"` with `pullPolicy: IfNotPresent`
   — Kubernetes sees a byte-identical pod spec and does nothing, even
   after Terraform rebuilds and reloads a new image into kind. After any
   apply whose only change is a rebuilt image, manually `kubectl rollout
   restart deployment/<name> -n warehouse-systems` for every affected
   service, then confirm with `kubectl rollout status` — never trust
   "apply succeeded" + "pod is Running" as proof the new code is live;
   check the binary's mtime inside the container if in doubt.

4. **Frontend images are content-addressed** (`local-<hash>` spanning the
   remote AND `warehouse-ui-kit`). Never "simplify" them back to a fixed
   `local` tag — that reintroduces the documented defect where a rebuilt
   image never rolls.

5. **Adding a service to `analytics_services` or `mcp_services` on a
   Postgres that already has data does nothing on its own.** Bitnami's
   Postgres chart only runs `primary.initdb.scripts` once, against an
   EMPTY data directory. A new entry renders correctly into
   `init-databases.sql.tftpl` but that render never re-executes against a
   live cluster — the new projector CrashLoopBackOffs with `password
   authentication failed`. After `apply`, fetch the generated password via
   a throwaway `terraform output -raw` block, then manually run the
   equivalent `CREATE ROLE`/`CREATE DATABASE` SQL against the live
   `postgres-postgresql-0` pod (mirror `init-databases.sql.tftpl`'s loop
   body exactly), THEN `helm rollback` the crashed release before
   re-applying — doing the SQL fix before the rollback leaves the release
   stuck `pending-upgrade`.

6. **`terraform validate`: keep BOTH branches of a ternary the same
   key-set**, even when one side's key is a structural no-op
   (`enabled = false`, `extraEnv = []`). An inconsistent key set between a
   ternary's true/false object results fails with "Inconsistent
   conditional result types" — the fix is always to add the missing key
   with an inert value to the other branch, never to make the branches
   structurally different.

7. **`services.tf`'s computed `extraEnv` OVERRIDES `helm-values/*.yaml`.**
   `helm_release.service` merges the static values file with a computed
   `yamlencode(merge(...))` layer that wins. Per-service env with no
   dedicated chart value must go in `local.sync_edge_env`
   (terraform/locals.tf) — an `extraEnv` list written directly into a
   `helm-values/<svc>.yaml` file is silently dropped and `terraform plan`
   shows no change at all.

8. **Every `*_MODE` env var defaults to `permissive` (no network) if
   unset.** A new sync edge between two services needs its `MODE` +
   `BASE_URL` wired in `local.sync_edge_env` in the SAME PR that adds the
   integration, or it silently runs permissive in the cluster. Grep the
   pod's startup log for `mode":"http"` after apply to confirm the mode a
   binary actually chose.

9. **Every chart's `selectorLabels` helper must scope by
   `app.kubernetes.io/component`, not just name+instance.** Those two
   labels are identical across a service's OLTP/MCP/projector/reports
   pods, so an OLTP `Service` without a component selector matches ALL of
   them — verified live: a request to a service's OLTP endpoint was
   answered by its reports pod instead. `scripts/check-chart-selectors.py`
   (wired into CI's `chart-selector-check` job) renders every chart with
   every optional component enabled and asserts each Service selects
   exactly one Deployment; run it locally (`make chart-selector-check`)
   before touching any chart's selector/label wiring, and prove a fix by
   deliberately breaking a selector and watching the script report `Service
   <ctx> selects N Deployments`.

10. **`terraform destroy` leaves ~60 phantom resources in Terraform state.**
    The API server dies before Helm releases are removed, the safety net
    deletes the kind cluster, and every release stays in state pointing at
    nothing — the next `apply` then fails trying to upgrade releases that
    don't exist. Fix: back up `terraform.tfstate`, then `terraform state
    list | while read r; do terraform state rm "$r"; done` before
    re-applying. Confirm `kind get clusters` shows none first.

11. **Deleting a tracked file: use `git rm -r <path>`, never a bare `rm
    -rf`.** The terminal approval guard here permanently blocks destructive
    `rm -rf` on tracked paths; `git rm -r` stages the deletion cleanly and
    is never blocked.

## The localhost edge (Nginx :80 assets, Kong :8000 APIs)

`terraform output product_endpoints` prints both edges. They are
INDEPENDENT — neither proxies to the other, and that split is a
deliberate, reviewed decision (`docs/exposure/localhost-edge-topology.md`),
not a gap to "simplify" by chaining one through the other. CORS is a
`KongClusterPlugin` labelled `global: "true"` (KIC selects global plugins
by that label plus a matching ingress class), not a per-route annotation —
none of the charts' `httproute.yaml` templates render an annotations block,
so per-route CORS attachment would need N chart PRs, not one infra change.
`scripts/test-exposure-policy.sh` (30 checks) is the policy conformance
gate for this edge; run it after any change here. Its own assertions match
on content-type/upstream identity, never bare HTTP status — the gateway's
catch-all legitimately returns `200 text/html` for unknown `/api/**` paths
(SPA fallback), and a naive status-code check reads that as a violation
when it is the policy working correctly.

## Worktree gotcha

`terraform validate`/`plan` run from `.worktrees/<name>/` fails with
`filesha256(...): no such file` because `service_source_hash` paths assume
sibling repos exist next to the checkout. Symlink every referenced sibling
repo into the worktree (`ln -s ~/warehouse-systems/<repo> <repo>`), or run
Terraform from the real checkout instead of a worktree.

## Key commands

```bash
make check              # tf-fmt-check + tf-validate + helm-lint + shellcheck
                         # + chart-selector-check (mirrors ci.yml)
make check-all          # same as check today (no coverage/arch-test dimension
                         # here — this repo is infra, not a Go/TS module)
terraform -chdir=terraform init
terraform -chdir=terraform plan
terraform -chdir=terraform apply
bash scripts/up.sh              # bring the whole cluster up
bash scripts/down.sh            # tear it down (see the phantom-state pitfall)
bash scripts/smoke-test.sh      # post-apply smoke check
bash scripts/test-exposure-policy.sh   # the 30-check localhost-edge policy gate
python3 scripts/check-chart-selectors.py   # selector-collision conformance
```

## Where the rest of the detail lives

Full pitfalls corpus (istio native-sidecar restart-on-first-connect, MCP
server deployment shape, ArgoCD rollout, observability dashboards-as-code)
lives in the `warehouse-systems-fleet-ops` Hermes skill's `references/`
directory — load that skill before any non-trivial infra change here
rather than re-deriving cluster behaviour from scratch.
