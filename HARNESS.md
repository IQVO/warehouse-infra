# HARNESS.md — warehouse-infra

What agent harness this repo has, what each piece runs, and when. Model (from
`warehouse-harness-template`, after Böckeler, "Harness engineering for coding agent users"):
**guides** steer an agent before it acts (feedforward), **sensors** report after it acts (feedback);
each is **computational** (deterministic) or **inferential** (LLM). This repo is Terraform + Helm
values + scripts for the k3s cluster, not a Go bounded context: there is no coverage gate, arch-test,
bdd, mutation, api-lint or docs-api-drift here. CI never runs `terraform apply`; every sensor below is
static or offline. Only what is listed below exists.

harness-template: v4

## Guides (feedforward)

| File | Type | Purpose |
|---|---|---|
| `CLAUDE.md` (`AGENTS.md` is a symlink to it) | computational | Entry point: what the repo deploys, architecture decisions, non-negotiables, CloudEvents, the localhost edge, commands. |
| `.claude/rules/terraform-wiring.md` | computational | Scoped to `terraform/**/*.tf`, templates, `helm-values/**`: layer/state wiring. |
| `.claude/rules/events-cloudevents.md` | computational | Scoped to terraform, helm-values, scripts: the CloudEvents-only cluster contract. |
| `.claude/rules/edge-and-selectors.md` | computational | Scoped to the Kong / gateway / exposure files: edge routes and chart selectors. |
| `.claude/rules/fleet/readme-standard.md` | computational | Fleet README standard (copied from the template). |
| `.claude/skills/*/SKILL.md` | inferential | Add or change a service, run the infra checks, deploy a local checkout. |
| `.claude/agents/*.md` | inferential | `code-review`, `architecture-review`, `domain-review` subagents (template-managed). |
| `.claude/memory/MEMORY.md` | computational | Durable repo heuristics that are not incidents. |
| `INCIDENTS.md` | computational | Fleet incident log: every escape with its fix and the sensor that now guards it. |

## Sensors (feedback)

All jobs below are in `.github/workflows/ci.yml` (PR and push to develop/main) unless named otherwise.

| Sensor | What it runs | Blocking? |
|---|---|---|
| `acceptance-units` | `python3 -m unittest discover -s scripts/tests`; `go test ./...` in `scripts/mcp-probe` | yes |
| `guide-lint` | `guide_lint.py` (skills load, cited paths and `make` targets exist, context budget), `repo_lint.py` (workflow paths, `needs:`, Dependabot, stale owner, placeholders), `scripts/check-no-secret-files.sh` (no tracked plan/state/tfvars/kubeconfig/key: the repo is public), `test_hook.py`, `test_red_issue.py`, `test_repo_lint.py` | yes |
| `terraform` | `make tf-fmt-check`, `make tf-validate` | yes |
| `observability-as-code` | `make observability-check` (generated dashboards/alert rules current, PromQL-safe), `make alert-rules-check` (promtool check + unit tests) | yes |
| `shellcheck` | `make shellcheck` on `scripts/*.sh` | yes |
| `seed-scripts` | `make seed-scripts-test` | yes |
| `mcp-conformance-probe` | `make mcp-conformance-test` | yes |
| `helm-lint` | `make helm-lint` over every chart | yes |
| `chart-selector-check` | `make chart-selector-check` (chart selector conformance) | yes |
| CodeQL | `.github/workflows/codeql.yml` (PR, push, weekly) | yes |
| AI review | `.github/workflows/ai-review.yml` (needs `ANTHROPIC_API_KEY`; path filter `internal/domain`, `apis`, `charts`, none of which exist here, so it does not fire) | no (advisory) |

`.github/workflows/publish-images.yml` (manual) builds and pushes images; it is delivery, not a sensor.

Local gates: `make check-fast` (tf-fmt-check, shellcheck, chart-selector-check, observability-check,
secret-files-check; the agent Stop hook runs it), `make check` / `make check-all` (tf-fmt-check,
tf-validate, helm-lint, shellcheck, chart-selector-check, observability-check, alert-rules-check,
seed-scripts-test, mcp-conformance-test), `make guide-lint`, `make harness-test`.
Plans and applies (`scripts/tf.sh`, `make *-plan` / `*-apply`) touch live state and are never sensors.

## Agent runtime harness

| Piece | Files | Lifecycle |
|---|---|---|
| Guard + feedback hooks | `scripts/harness/hook.py` (`pre` / `post` / `stop`) with adapters `.claude/settings.json`, `.codex/hooks.json`, `.opencode/plugins/harness.ts` | every tool call; end of turn |
| Skills for Codex | `.agents/skills` symlink to `.claude/skills` | on task match |
| Red-sensor helper | `scripts/harness/red_issue.py` (tested; no scheduled job here calls it yet) | n/a |

The hooks block pushes to develop/main, `--no-verify`, force-push, bare `rm -rf` on non-scratch
paths, destructive git, and edits to generated files; the Stop hook runs `make check-fast` when code
changed. `HARNESS_OFF=1` disables them. The `scripts/harness/*.py` files and the three adapters are
template-managed copies: change them in `warehouse-harness-template`, never here.

## Incident protocol

Every failure that was not caught before CI ends with the fix, a sensor or guide that would have
caught it, that sensor rolled out fleet-wide, and a row in [INCIDENTS.md](INCIDENTS.md). A row with
no guard is an open gap and says so.
