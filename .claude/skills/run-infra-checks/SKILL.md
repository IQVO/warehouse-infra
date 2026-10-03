---
name: run-infra-checks
description: Run and interpret warehouse-infra's quality gate (terraform fmt and validate, helm lint, shellcheck, chart selector conformance, guide-lint, hook tests) and know what each one guards. Use when you changed Terraform, a helm-values file, scripts/*.sh, the Makefile or CI, before saying done, or when a CI job (terraform, helm-lint, shellcheck, chart-selector-check, guide-lint) fails.
---

# Run the fast checks

Every CI job in `.github/workflows/ci.yml` is one Makefile target in `Makefile`, so a local run reproduces CI.

| Command | What it guards | Typical failure |
|---|---|---|
| `make tf-fmt-check` | `terraform fmt -check -recursive -diff` from `terraform/` | whitespace/alignment. Fix with `terraform -chdir=terraform fmt -recursive` |
| `make tf-validate` | `terraform init -backend=false` then `terraform validate` | "Inconsistent conditional result types" = the two ternary branches in `terraform/services.tf` have different key sets; add the missing key with an inert value (`enabled = false`, `extraEnv = []`) to the other branch. Also a missing `helm-values/<svc>.yaml` |
| `make helm-lint` | `helm lint` on every chart in `CHARTS` (sibling repos' charts) | needs `helm`; workforce-management needs a dummy `database.url`, already wired in the Makefile |
| `make shellcheck` | `shellcheck --severity=warning scripts/*.sh` | needs `shellcheck` on PATH |
| `make chart-selector-check` | `scripts/check-chart-selectors.py` renders every chart with analytics, frontend and MCP enabled and asserts each Service selects EXACTLY ONE Deployment | `Service <ctx> selects N Deployments`: a component template lacks `app.kubernetes.io/component` in its selector. Needs `helm` and PyYAML |
| `make check-fast` | the agent Stop-hook gate: `tf-fmt-check`, `shellcheck`, `chart-selector-check` (no `tf-validate`, no `helm-lint`) | run this after every edit |
| `make check` / `make check-all` | full bundle (`check-all` is an alias): fmt, validate, helm-lint, shellcheck, selector check | run before "done" when Terraform changed |
| `make guide-lint` | `scripts/harness/guide_lint.py`: skills load, cited paths and make targets exist, CLAUDE.md budget | a stale path in CLAUDE.md or `.claude/**` |
| `make harness-test` | `scripts/harness/test_hook.py`: unit tests of the agent hooks | do not edit `scripts/harness/*` (managed) |

## Gotchas

- Chart-dependent checks (`helm-lint`, `chart-selector-check`, `tf-validate`) resolve `../../<repo>/charts/<repo>` relative to `terraform/`, so the sibling repos must sit next to the checkout. In a worktree under `.worktrees/` they are symlinked there; if not, symlink each referenced sibling (`ln -s ~/warehouse-systems/<repo> <repo>` in `.worktrees/`) or run from the real checkout. Without them you get `filesha256(...): no such file`.
- Conformance scripts assume the Makefile's cwd (`cd terraform`), not the repo root; use the Makefile target rather than invoking the script from the root.
- A missing tool (`helm`, `shellcheck`, `terraform`, PyYAML) fails the target with an install hint; that is an environment gap, not a code failure. Say so rather than skipping silently.
- The CHARTS list is hand-maintained in two places (`Makefile`, `scripts/check-chart-selectors.py`). When a service is added, update both, or the check silently skips its chart.
- Cluster-dependent checks are NOT part of `make check`: `scripts/test-exposure-policy.sh` (localhost edge policy, run it after any edge change) and `scripts/smoke-test.sh` need a live kind cluster.
- `scripts/test-exposure-policy.sh` asserts on content-type and upstream identity, not bare HTTP status: the gateway's catch-all legitimately returns `200 text/html` for unknown `/api/**` paths. Do not "fix" that into a status-code check.
- To prove a selector fix works, deliberately break a selector and watch the script report `selects N Deployments`, then restore it.
