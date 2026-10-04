---
name: deploy-local-checkout
description: Apply this repo's Terraform to the local kind cluster `warehouse` safely, from the real checkout or a worktree, and recover from a bad destroy. Use when running terraform plan or apply, scripts/up.sh or scripts/down.sh, deploying a sibling repo's local changes, working from a .worktrees/ checkout, verifying a rollout, or deleting tracked files.
---

# Deploy local checkouts to the kind cluster

Apply, destroy and any `kubectl`/SQL against the live cluster mutate the user's environment. Do them only when the user asked for it; an infra PR normally stops at `make check` plus a clean `terraform plan`.

## What gets built from where

- Images are built from the LOCAL sibling checkouts (`~/warehouse-systems/<repo>`) by `scripts/build-and-load.sh` (`docker build` then `kind load docker-image`), not from `origin/develop`. Merging a PR on GitHub changes nothing until that checkout is pulled: `git -C ~/warehouse-systems/<repo> pull --ff-only origin develop`, and confirm the new code is in the tree. Whatever branch or uncommitted work is checked out there ships, and it vanishes on the next pull, so land real fixes as PRs first.
- Charts are NOT built from local checkouts: ArgoCD installs them from each service repo's GitHub `develop` (`terraform/argocd-apps.tf`). See the `add-or-change-a-service` skill for what that means for chart edits.
- `terraform apply` reports `0 added, 0 changed` when only docs, CI or chart templates changed; that is a legitimate result, not a skipped step. Proof the cluster runs current source: `terraform console` of `local.service_source_hash["<svc>"]`, the `build_and_load` `source_hash` in state, and the live image tag (`local-<hash12>`) all agree.

## Worktree live state (worktrees under `.worktrees/`)

State is a plain local file, terraform.tfstate under the terraform directory (gitignored in `.gitignore`, no remote backend). A worktree has none, so a bare plan proposes destroying and recreating everything.

1. Copy the real state in:
   ```
   cp ~/warehouse-systems/warehouse-infra/terraform/terraform.tfstate <worktree>/terraform/terraform.tfstate
   ```
2. `terraform -chdir=terraform init`, then `make tf-validate`.
3. Scope plan AND apply with `-target=`, e.g. `-target='null_resource.build_and_load["order-management"]'`. An untargeted run walks all of `local.services` and rebuilds every sibling whose checkout happens to be stale.
4. Before a targeted apply, check each sibling is on `develop`, fast-forwarded and clean (`git branch --show-current`, `git status --short`). Leave dirty or off-branch repos alone and defer applies touching them.
5. After an apply that changed real state, copy the tfstate BACK to the real checkout's terraform directory (reverse of step 1). Skipping this orphans resources; the next apply from the main checkout fails with `<kind> "<name>" already exists`. Recover with `terraform import <addr> "<namespace>/<name>"` per resource (check `terraform state list` after a timeout before retrying).
6. `terraform validate`/`plan` in a worktree needs the sibling repos symlinked next to the worktree (`filesha256(...): no such file` otherwise).

## Running it

- Plan/apply can outlast a foreground tool timeout, and Terraform treats the resulting SIGINT as a real abort. Run them with `terminal(background=true, notify=true)` and wait on the process; check the output for `Apply complete!`.
- `bash scripts/up.sh` (init + apply), `bash scripts/down.sh` (destroy), `bash scripts/smoke-test.sh` after apply, `bash scripts/test-exposure-policy.sh` after any edge change.
- Before claiming a rollout is live: `kubectl get pods -A`, `kubectl -n argocd get applications`, compare the pod image tag to `local.service_image_tags`. 2/2 containers is the Istio native sidecar (an init container with `restartPolicy: Always`, not in `.spec.containers`); check container names, not the ready count.
- Kafka CLI tools inside `kafka-controller-0` must be prefixed `env KAFKA_HEAP_OPTS=-Xmx128m`: they share the broker container's memory limit (`terraform/kafka.tf`) and `--describe --all-groups` has OOMKilled the broker.

## `terraform destroy` leaves phantom state

The API server dies before every release is removed, `scripts/down.sh` then deletes the kind cluster as a safety net, and ~60 resources stay in state pointing at nothing; the next apply fails upgrading things that do not exist. Recovery, only with the user's go-ahead:

1. `kind get clusters` must show no `warehouse`.
2. Back up the tfstate file.
3. `terraform state list | while read r; do terraform state rm "$r"; done`.
4. Re-apply.

## Deleting tracked files

Use `git rm -r <path>`, never bare `rm -rf`: the hooks (`scripts/harness/hook.py`) and the environment block `rm -rf` on tracked paths, and `git rm -r` stages the deletion cleanly. Never push to `develop` or `main`; use a `feature/*` branch and a PR.
