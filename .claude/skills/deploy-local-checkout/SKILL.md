---
name: deploy-local-checkout
description: Apply this repo's Terraform to the local kind cluster `warehouse` safely, from the real checkout or a worktree, and recover from a bad destroy. Use when running terraform plan or apply, scripts/up.sh or scripts/down.sh, deploying a sibling repo's local changes, working from a .worktrees/ checkout, verifying a rollout, or deleting tracked files.
---

# Deploy local checkouts to the kind cluster

Apply, destroy and any `kubectl`/SQL against the live cluster mutate the user's environment. Do them only when the user asked for it; an infra PR normally stops at `make check` plus a clean `terraform plan`.

## What gets built from where

- Images are built from the LOCAL sibling checkouts (`~/warehouse-systems/<repo>`) by `scripts/build-and-load.sh` (`docker build` then `kind load docker-image`), not from `origin/develop`. Merging a PR on GitHub changes nothing until that checkout is pulled: `git -C ~/warehouse-systems/<repo> pull --ff-only origin develop`, and confirm the new code is in the tree. Whatever branch or uncommitted work is checked out there ships, and it vanishes on the next pull, so land real fixes as PRs first.
- Charts are NOT built from local checkouts: ArgoCD installs them from each service repo's GitHub `develop` (the `Application` each `terraform/modules/application` instance creates). See the `add-or-change-a-service` skill for what that means for chart edits.
- `terraform apply` reports `0 added, 0 changed` when only docs, CI or chart templates changed; that is a legitimate result, not a skipped step. Proof the cluster runs current source: `TF_WORKSPACE=<svc> terraform -chdir=terraform/20-apps console` of `module.application["<svc>"].image_tag`, the module's `null_resource.build_and_load` `image` trigger in state, and the live image tag (`local-<hash12>`) all agree.

## Layers and live state (worktrees under `.worktrees/`)

Terraform is three layers with three kinds of state (ADR 0007), all plain local files, gitignored, no remote backend: `terraform/00-cluster/terraform.tfstate`, `terraform/10-platform/terraform.tfstate` and `terraform/20-apps/terraform.tfstate.d/<app>/terraform.tfstate` (one per application). Run Terraform through `scripts/tf.sh` (or `make cluster-plan|platform-plan|app-plan APP=<name>|apps-plan`, and the `-apply` twins): it passes `terraform/terraform.tfvars`, sets `TF_WORKSPACE` for that one command, rejects a name that is not in `terraform/apps.yaml`, and queues behind a held lock for five minutes. Never `terraform workspace select`: the choice is stored in a file two sessions would share.

A worktree has no state, so a bare plan proposes creating everything. To plan from one:

1. Copy the layer states you need in (`00-cluster` and `10-platform` for a platform change; also the application's workspace directory for an application change). Copy the gitignored `terraform.tfvars` (next to `apps.yaml`) too.
2. `scripts/tf.sh <layer> plan -refresh=false -lock=false` on the copies when another session may hold the real lock.
3. An application change is planned and applied alone: `scripts/tf.sh app inventory-storage plan`. There is no `-target=` any more; an untargeted `apps` run walks every application and rebuilds each sibling whose checkout happens to be stale.
4. Before an apply, check each sibling is on `develop`, fast-forwarded and clean (`git branch --show-current`, `git status --short`). Leave dirty or off-branch repos alone and defer applies touching them.
5. After an apply that changed real state, copy the layer's state BACK to the real checkout (reverse of step 1). Skipping this orphans resources; the next apply from the main checkout fails with `<kind> "<name>" already exists`. Recover with `terraform import <addr> "<namespace>/<name>"` per resource (check `terraform state list` after a timeout before retrying).
6. `terraform validate`/`plan` in a worktree needs the sibling repos symlinked next to the worktree (`filesha256(...): no such file` otherwise).
7. Never apply from a checkout older than the layered layout: its root `terraform/` has no state any more and would plan to create every resource again. Fast-forward first.

## Running it

- Plan/apply can outlast a foreground tool timeout, and Terraform treats the resulting SIGINT as a real abort. Run them with `terminal(background=true, notify=true)` and wait on the process; check the output for `Apply complete!`.
- `bash scripts/up.sh` (the three layers in order), `bash scripts/down.sh` (deletes the cluster, drops the layers' state), `bash scripts/smoke-test.sh` after apply, `bash scripts/test-exposure-policy.sh` after any edge change.
- Before claiming a rollout is live: `kubectl get pods -A`, `kubectl -n argocd get applications`, compare the pod image tag to `module.application["<svc>"].image_tag`. 2/2 containers is the Istio native sidecar (an init container with `restartPolicy: Always`, not in `.spec.containers`); check container names, not the ready count.
- Kafka CLI tools inside `kafka-controller-0` must be prefixed `env KAFKA_HEAP_OPTS=-Xmx128m`: they share the broker container's memory limit (`terraform/10-platform/kafka.tf`) and `--describe --all-groups` has OOMKilled the broker.

## Never `terraform destroy` the cluster

The API server dies before every release is removed, and ~60 resources stay in state pointing at nothing; the next apply fails upgrading things that do not exist. `scripts/down.sh` therefore deletes the kind cluster (`kind delete cluster --name warehouse`) and drops the three layers' state; `scripts/up.sh` rebuilds. Only with the user's go-ahead, and after backing the states up:

1. `kind get clusters` must show no `warehouse` after the delete.
2. Back up `terraform/{00-cluster,10-platform}/terraform.tfstate` and the `terraform.tfstate.d` directory of `20-apps` (they hold every secret in clear text: keep them out of Git and empty the copies afterwards).
3. Re-apply the layers in order.

## Deleting tracked files

Use `git rm -r <path>`, never bare `rm -rf`: the hooks (`scripts/harness/hook.py`) and the environment block `rm -rf` on tracked paths, and `git rm -r` stages the deletion cleanly. Never push to `develop` or `main`; use a `feature/*` branch and a PR.
