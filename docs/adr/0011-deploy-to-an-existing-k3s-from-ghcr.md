# ADR 0011: deploy to an existing k3s cluster, with images from ghcr.io

## Status

Proposed (2026-11-08). Extends [ADR 0007](0007-state-split-in-four-steps.md) (the layers) and
[ADR 0002](0002-application-delivery-boundary.md) (the application boundary). The kind environment is unchanged
and stays the default.

## Context

Until now this repo meant one thing: create a `kind` cluster on the local Docker daemon, build every image from the
sibling checkouts and `kind load` it. A second environment exists: a two-node k3s cluster (a multipass server and
agent, context `k3s-multipass`, linux/arm64). Constraints:

- **The machine is not ours to change.** No SSH, no `registries.yaml`, no apiserver flags, no firewall or port
  mappings. Terraform may only talk to its Kubernetes API.
- **Nothing is built or loaded locally.** The images come from ghcr.io.
- The fleet is unauthenticated (REST and MCP), so nothing may be published to the LAN.

What kind gave us for free and k3s does not:

| kind | k3s |
|---|---|
| this repo creates the cluster | the cluster exists; its credentials are in a kubeconfig |
| `kind load docker-image` | no way to side-load without touching the nodes |
| `extraPortMappings` on 127.0.0.1 | none; a NodePort answers on the node's LAN address (192.168.15.30) |
| apiserver `--service-node-port-range` widened for Kafka's NodePort 9092 | fixed 30000-32767 |
| nothing else installed | Traefik, metrics-server, and Gateway API CRDs (v1.6.3, Helm-owned) preinstalled |

The images already published to ghcr.io by each application's `docker-publish` job do not fit: they are
`linux/amd64` only (the nodes are arm64), pushed only on a merge to `main` (ArgoCD installs the charts from
`develop`), and most of the 41 applications (31) have never published one.

## Decision

1. **A target is a tfvars file plus its own state.** `scripts/tf.sh --target k3s <layer> ...` (or
   `WAREHOUSE_TARGET=k3s`) adds `terraform/targets/k3s.tfvars.json` after the shared `terraform.tfvars`, writes
   `terraform.tfstate.k3s` (applications: `terraform.tfstate.d.k3s/<app>/`) and keeps its plugins in
   `.terraform.k3s`. The layers find each other's state through `var.state_suffix`. Under a target `tf.sh` refuses
   any command that would fall back to `terraform.tfstate`, so a k3s command can never touch the kind state.
   (A `.tfvars.json` because `check-no-secret-files.sh` bans tracked `*.tfvars`; the file holds no secret.)
2. **00-cluster can describe a cluster it does not own.** `cluster_provider = "existing"` creates nothing; it
   reads `kube_context` out of `kubeconfig_file` (certificate or token auth) and publishes it as the same
   `connection` output, plus a `token` field. `kind_cluster` and the kubeconfig `null_resource` gained a
   `count`, with `moved` blocks, so the kind state plans no change.
3. **Edges are ClusterIP; `scripts/k3s-edges.sh` bridges them.** `expose_node_ports = false` turns Kong and the
   Nginx web gateway into ClusterIP Services, drops the observability/Kiali NodePort Services and Kafka's
   EXTERNAL listener. The script runs `kubectl port-forward` bound to `127.0.0.1` on the kind environment's
   ports, so every URL and the fixed CORS origin (`http://localhost`) hold. Port 80 needs root on macOS for
   a loopback bind; the script re-runs itself under `sudo` rather than bind `0.0.0.0`.
4. **Use what k3s ships.** `manage_gateway_api_crds = false` (the vendored v1.6.2 bundle would be refused by the
   cluster's v1.6.3 safe-upgrades policy, and two owners of one CRD set fight) and `deploy_metrics_server = false`.
   Traefik stays; it does not collide (nothing here uses a host port).
   Two more things learned on the first apply: (a) **no Istio sidecars** (`istio_injection_enabled = false`): on
   a stock node `fs.inotify.max_user_instances` is 128, a host setting we may not raise, and the sidecars die with
   "couldn't initialize inotify: too many open files" at about 50 pods. The mesh has no PeerAuthentication or
   AuthorizationPolicy, so nothing else changes; Kiali just has no traffic to draw. (b) **Kong Manager is ClusterIP**:
   the chart makes it a NodePort, which on kind is unreachable from outside Docker but on k3s would be published
   on the LAN.
5. **Images: one workflow builds, a lock file pins, Terraform pulls.**
   - `.github/workflows/publish-images.yml` (manual) builds the 70 images of `apps.yaml` (39 services, 29 frontends,
     2 sites) from one ref of every repository, on native arm64 runners, and pushes
     `ghcr.io/iqvo/warehouse-infra/<name>:<commit>[-<ui-kit commit>]-arm64`. It is idempotent: an existing tag is
     not rebuilt. It lives here, not in 40 repositories, so the images and the charts come from one commit and
     no application pipeline changes.
   - `scripts/k3s-pin-images.sh <run-id>` writes the tags to `terraform/targets/k3s.images.yaml`.
   - `image_source = "registry"` makes `modules/application` build and load nothing, set `image.repository`,
     `frontend.image.repository`, the tag and `imagePullSecrets` in the Application's `valuesObject` (which wins
     over the value files shared with kind), and fail the plan for an application with no pinned tag.
     
6. **No pull credential by default.** The images are published by a workflow of this (public) repository, so the
   packages are public and a pull needs none. `warehouse-ops-agent`, whose own package is private, is rebuilt here
   too (`publish_image: true` in `apps.yaml`) for that reason and for its arm64 image. Should a package turn
   private, `TF_VAR_ghcr_token` (or `WAREHOUSE_GHCR_AUTH=gh`) makes the platform layer create a `ghcr-pull` Secret
   that every chart gets as `imagePullSecrets`; it is never written to a file.

## Consequences

- `scripts/up.sh --target k3s` is the same three layers; `down.sh --target k3s --yes` destroys the applications and
  the platform and leaves the machine alone.
- The k3s environment runs the images of one `develop` snapshot. Moving it forward is: run `publish-images`, run
  `k3s-pin-images.sh`, commit the lock file, `tf.sh --target k3s apps apply`. A chart change still reaches the
  cluster through ArgoCD on merge; an image change does not, without the pin.
- The two environments share `terraform/10-platform` code; a variable's default is the kind behaviour.
- `kind` and `k3s` cannot both hold `localhost:80`/`:8000` at once.
- A k3s node allows 110 pods (kubelet `maxPods`, also not ours to change). The platform plus the fleet needs more
  than one node (ArgoCD runs without Dex, notifications and the ApplicationSet controller there: `argocd_lean`): with the agent down the applications that do not fit stay `Pending` until it returns.

## Alternatives rejected

- **Per-repository arm64 publishing** (amd64+arm64 in each `docker-publish`, promote each `develop` to `main`):
  40 pull requests and 40 releases, and the images would still lag the charts ArgoCD installs.
- **A registry in the cluster / `ctr images import` / `registries.yaml`**: all of them change the nodes or add
  infrastructure that exists only to work around the constraint.
- **NodePort edges with a firewall**: the firewall is on the machine.
