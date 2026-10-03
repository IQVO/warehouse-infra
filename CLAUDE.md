# Project: warehouse-infra

Terraform + Helm deployment of the entire `warehouse-systems` fleet onto a
local `kind` cluster named `warehouse`. This repo owns the cluster's
existence, not any bounded context's business logic: one Terraform root
module plus per-service values; each service's chart lives in that
service's own repo.

> **Study project.** Personal DDD/hexagonal/Kubernetes learning exercise. Not
> a production system; no uptime or support guarantee.

## What this repo deploys

`terraform/locals.tf`'s `local.services` map is the **single source of
truth** for what gets deployed. It does NOT auto-discover sibling repos: a
new bounded-context repo must be added by hand and its own `charts/<repo>/`
must already exist. Read that file before answering "what does the cluster
know about".

```
terraform/             Root module: services, Kafka, Postgres + PgBouncer, MCP, ArgoCD,
                       dashboards, the Nginx/Kong localhost edge
helm-values/           Per-service STATIC values (computed layer in services.tf wins)
config/process-paths/  Seed data for scripts/seed-process-paths.py
scripts/               up/down, smoke test, exposure-policy gate, chart selector check
docs/                  Analytics governance, observability, edge decision, CloudEvents cutover
.github/workflows/ci.yml   terraform, helm-lint, shellcheck, chart-selector-check, guide-lint
Makefile               make check / check-fast / check-all mirror ci.yml 1:1
```

## Non-negotiables (short form; detail loads from `.claude/rules/` when you touch the files)

1. **`terraform apply` does NOT pick up chart-template changes.** The source
   hash covers Go source, migrations, Dockerfile and go.mod/go.sum only.
   ArgoCD (`terraform/argocd-apps.tf`) installs each chart from the service
   repo's GitHub `develop`. NOTE: the older recipe here (`terraform taint
   helm_release.service[...]`) is obsolete; that resource no longer exists.
2. **Images are built from the LOCAL sibling checkout, not `origin/develop`.**
   `git -C ~/warehouse-systems/<repo> pull --ff-only origin develop` before
   applying, and verify the new code is in the tree.
3. **Never trust "apply succeeded" + "pod Running" as proof new code is
   live.** Image tags are content-derived (`local-<hash12>`); never
   simplify them back to a fixed `local` tag (frontends included). Confirm
   with `kubectl rollout status` and the live image tag.
4. **Adding to `analytics_services` / `mcp_services` on a Postgres that
   already has data does nothing alone** (initdb runs once on an empty data
   dir): create the role/DB by hand. See the `add-or-change-a-service` skill.
5. **`terraform validate`: both branches of a ternary must have the same
   key set**, even when one side is inert.
6. **The computed layer in `terraform/services.tf` OVERRIDES
   `helm-values/*.yaml`.** Per-service env with no chart value goes in
   `local.sync_edge_env`; an `extraEnv` in a helm-values file is silently dropped.
7. **Every `*_MODE` env var defaults to `permissive` if unset.** Wire `MODE`
   + `BASE_URL` in `local.sync_edge_env` in the SAME PR as a new sync edge.
8. **Every chart `Service` must select exactly ONE Deployment** (scope
   `selectorLabels` by `app.kubernetes.io/component`). Run
   `make chart-selector-check` before touching selector/label wiring.
9. **`terraform destroy` leaves ~60 phantom resources in state.** Back up
   the tfstate, confirm `kind get clusters` is empty, then `terraform state rm`
   each, before re-applying.
10. **Delete tracked files with `git rm -r <path>`, never bare `rm -rf`.**
11. **Worktrees have no tfstate and no sibling repos.** Copy the real
    `terraform.tfstate` in, scope plan/apply with `-target=`, copy it back
    after an apply, and symlink siblings (see `deploy-local-checkout`). Never
    apply, destroy or run SQL/kubectl mutations against the live cluster
    without the user's go-ahead.

## Events: CloudEvents 1.0 is MANDATORY

Every Kafka message on every topic is a CloudEvents 1.0 event in structured
mode. **Never configure an envelope toggle** (no `EVENT_ENVELOPE_MODE` or any
flat/dual switch) in `terraform/`, `helm-values/` or `scripts/`; adding one is
a defect. `docs/analytics/envelope-v1.md` is SUPERSEDED. Wire format, type
naming and the Kafka-CLI heap prefix: `.claude/rules/events-cloudevents.md`;
topic wipes follow `docs/cloudevents-cutover.md`. The full standard lives in
the warehouse-docs repo and each service repo's own ADRs, not here.

## The localhost edge

Nginx `:80` (assets) and Kong `:8000` (APIs) are INDEPENDENT; never chain
one through the other (`docs/exposure/localhost-edge-topology.md`). Run
`scripts/test-exposure-policy.sh` after any edge change. Detail:
`.claude/rules/edge-and-selectors.md`.

## Key commands

```bash
make check-fast         # tf-fmt-check + shellcheck + chart-selector-check (agent Stop hook)
make check              # + tf-validate + helm-lint (mirrors ci.yml); check-all is an alias
make guide-lint         # agent-guide lint (blocking in CI)
terraform -chdir=terraform plan      # see deploy-local-checkout before apply
bash scripts/up.sh | down.sh | smoke-test.sh | test-exposure-policy.sh
```

## Skills and rules

- Skills (`.claude/skills/`): `add-or-change-a-service`, `run-infra-checks`,
  `deploy-local-checkout`.
- Path-scoped rules (`.claude/rules/`): `terraform-wiring`, `events-cloudevents`,
  `edge-and-selectors`.
- Wider pitfalls corpus (istio native sidecar, MCP deployment shape, ArgoCD
  rollout, dashboards-as-code): the `warehouse-systems-fleet-ops` Hermes skill's `references/`.

<!-- harness:scoped-rules:start (generated by tools/migrate_v3.py in warehouse-harness-template; do not hand-edit) -->
## Scoped rules and harness

Claude Code loads each rule below automatically when you touch the matching paths. OpenCode and Codex do NOT: read the rule BEFORE editing matching files.

Hooks (`scripts/harness/hook.py`, wired for Claude Code, Codex and OpenCode) block pushes to develop/main, `--no-verify`, bare `rm -rf`, and edits to generated files, and feed gofmt/vet findings back after each edit. Before saying "done" run `make check-fast`; the full gate is `make check-all`. `HARNESS_OFF=1` disables the hooks when debugging the harness itself.
<!-- harness:scoped-rules:end -->
