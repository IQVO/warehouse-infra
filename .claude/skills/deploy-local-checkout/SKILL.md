---
name: deploy-local-checkout
description: Apply this repo's Terraform to the k3s cluster safely (kind is banned; images come from GitHub), from the real checkout or a worktree, and recover from a bad destroy. Use when running terraform plan or apply, scripts/up.sh or scripts/down.sh, deploying a sibling repo's local changes, working from a .worktrees/ checkout, verifying a rollout, or deleting tracked files.
---

# Deploy to the k3s cluster (kind is banned)

Apply, destroy and any `kubectl`/SQL against the live cluster mutate the user's environment. Do them only when the user asked for it; an infra PR normally stops at `make check` plus a clean `terraform plan`.

## What gets deployed from where

- Rule: every deploy targets k3s (`--target k3s`), and every image already exists on GitHub. Nothing is built or loaded locally (ADR 0011).
- Images come from `.github/workflows/publish-images.yml` (manual; builds every image of `apps.yaml` on arm64 from one ref of every repo, pushes `ghcr.io/iqvo/warehouse-infra/<name>:<commit>[-<ui-kit commit>]-arm64`). To ship a merged change: run the workflow on `develop`, `scripts/k3s-pin-images.sh <run-id>` (or `--latest`), commit `terraform/targets/k3s.images.yaml` through a PR, then apply. A merged PR on a sibling repo changes nothing in the cluster until that pin moves.
- Charts are NOT built here: ArgoCD installs them from each service repo's GitHub `develop` (the `Application` each `terraform/modules/application` instance creates). See the `add-or-change-a-service` skill for what that means for chart edits.
- `terraform apply` reports `0 added, 0 changed` when only docs, CI or chart templates changed; that is a legitimate result. Proof the cluster runs the pinned source: the live image tag equals the tag in `k3s.images.yaml` for that app.

## Layers and live state (worktrees under `.worktrees/`)

Terraform is three layers with three kinds of state (ADR 0007), all plain local files, gitignored, no remote backend: `terraform/00-cluster/terraform.tfstate.k3s`, `terraform/10-platform/terraform.tfstate.k3s` and `terraform/20-apps/terraform.tfstate.d.k3s/<app>/` (one per application; plugins in `.terraform.k3s`). Run Terraform through `scripts/tf.sh --target k3s` (or `make cluster-plan|platform-plan|app-plan APP=<name>|apps-plan`, and the `-apply` twins): it passes `terraform/terraform.tfvars`, sets `TF_WORKSPACE` for that one command, rejects a name that is not in `terraform/apps.yaml`, and queues behind a held lock for five minutes. Never `terraform workspace select`: the choice is stored in a file two sessions would share.

A worktree has no state, so a bare plan proposes creating everything. To plan from one:

1. Copy the layer states you need in (`00-cluster` and `10-platform` for a platform change; also the application's workspace directory for an application change). Copy the gitignored `terraform.tfvars` (next to `apps.yaml`) too.
2. `scripts/tf.sh --target k3s <layer> plan -refresh=false -lock=false` on the copies when another session may hold the real lock.
3. An application change is planned and applied alone: `scripts/tf.sh --target k3s app inventory-storage plan`. There is no `-target=` any more; an untargeted `apps` run walks every application.
4. Before an apply, check `kubectl get nodes`: the agent node flaps NotReady for hours and a provisioning Job that cannot schedule hangs the apply. Do not apply through an outage. Check every app you apply has a pinned tag.
5. After an apply that changed real state, copy the layer's state BACK to the real checkout (reverse of step 1). Skipping this orphans resources; the next apply from the main checkout fails with `<kind> "<name>" already exists`. Recover with `terraform import <addr> "<namespace>/<name>"` per resource (check `terraform state list` after a timeout before retrying).
6. `terraform validate`/`plan` in a worktree may need the sibling repos symlinked next to it (`filesha256(...): no such file` otherwise).
7. Never apply from a checkout older than the layered layout: its root `terraform/` has no state any more and would plan to create every resource again. Fast-forward first.

## Running it

- Plan/apply can outlast a foreground tool timeout, and Terraform treats the resulting SIGINT as a real abort. Run them with `terminal(background=true, notify=true)` and wait on the process; check the output for `Apply complete!`.
- `bash scripts/up.sh --target k3s` (the three layers in order), `bash scripts/down.sh --target k3s --yes` (removes applications and platform; the machines stay), `scripts/k3s-edges.sh` (port-forwards the ClusterIP edges to 127.0.0.1; run it as a tracked background process), `bash scripts/smoke-test.sh` after apply, `bash scripts/test-exposure-policy.sh` after any edge change.
- Before claiming a rollout is live: `kubectl get pods -A`, `kubectl -n argocd get applications`, compare the pod image tag to the app's tag in `terraform/targets/k3s.images.yaml`. 2/2 containers is the Istio native sidecar (an init container with `restartPolicy: Always`, not in `.spec.containers`); check container names, not the ready count.
- Kafka CLI tools inside `kafka-controller-0` must be prefixed `env KAFKA_HEAP_OPTS=-Xmx128m`: they share the broker container's memory limit (`terraform/10-platform/kafka.tf`) and `--describe --all-groups` has OOMKilled the broker.

## Never `terraform destroy` the cluster

Never run `terraform destroy` on `00-cluster`, and never one big destroy of everything: a half-finished destroy leaves resources in state pointing at nothing, and the next apply fails upgrading things that do not exist. `scripts/down.sh --target k3s --yes` therefore removes the applications and the platform in order and drops the layers' k3s state; `scripts/up.sh --target k3s` rebuilds. The k3s machines are never ours to delete or reconfigure. Only with the user's go-ahead, and after backing the states up:

1. `kubectl get ns` must show the platform namespaces gone after the down.
2. Back up `terraform/{00-cluster,10-platform}/terraform.tfstate.k3s` and the `terraform.tfstate.d.k3s` directory of `20-apps` (they hold every secret in clear text: keep them out of Git and empty the copies afterwards).
3. Re-apply the layers in order.

## Deleting tracked files

Use `git rm -r <path>`, never bare `rm -rf`: the hooks (`scripts/harness/hook.py`) and the environment block `rm -rf` on tracked paths, and `git rm -r` stages the deletion cleanly. Never push to `develop` or `main`; use a `feature/*` branch and a PR.
