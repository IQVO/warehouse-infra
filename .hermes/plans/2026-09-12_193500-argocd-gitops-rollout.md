# ArgoCD GitOps Rollout — Implementation Plan

> **For Hermes:** Use subagent-driven-development to execute task-by-task,
> one feature branch + PR per phase, GitFlow into `develop` (never direct to
> `main`), CI green before merge, per this user's standing conventions.

**Goal:** Introduce ArgoCD into the `warehouse` kind cluster and make it the
continuous-deployment mechanism for every bounded-context service chart, so
that adding a new service's Helm chart to the fleet automatically gets it an
ArgoCD `Application` with no separate GitOps config to hand-write — Terraform
keeps being the single source of truth for *which services exist*
(`locals.tf`'s `local.services`), ArgoCD takes over *keeping the cluster's
running state in sync with each service's own chart in Git*.

**Architecture:** Terraform still bootstraps the platform (kind, Postgres,
Kafka, Istio, Kong, the Nginx web gateway, and now ArgoCD itself) and still
computes per-service environment values (DB URL, generated secrets, Kong/
Gateway route, image tag). Instead of Terraform calling `helm_release` once
per service at `terraform apply` time, Terraform renders and applies a single
`ApplicationSet` (Argo CD's list-generator CRD) whose entries are generated
directly from `local.services`. The ApplicationSet controller then creates
one `Application` per service, each pointing at that service's **own repo**
and `charts/<service>` path (exactly the `chart_path` convention already in
use today) — and keeps it continuously reconciled, self-healing, and
diff-visible, instead of a one-shot apply.

**Tech Stack:** Argo CD (official `argo-cd` Helm chart from
`https://argoproj.github.io/argo-helm`), Argo CD `ApplicationSet` (list
generator), Terraform `helm_release` + `kubectl_manifest`
(`gavinbunney/kubectl` provider — chosen over the native `kubernetes_manifest`
resource specifically to sidestep its CRD-must-exist-at-plan-time limitation,
see Task 2 below), existing per-service Helm charts (no framework change to
the charts themselves beyond the `existingSecret` audit in Phase 2).

---

## Phase 0 — Decisions this plan makes, and why (read before executing)

These are real trade-offs; flagging them explicitly rather than burying the
choice inside a task.

1. **Scope: application charts only, not platform infra.** ArgoCD manages
   the 8 bounded-context service charts registered in `local.services` (plus
   `warehouse-ops-agent` and the frontend/console chart in Phase 6). Postgres,
   Kafka, Istio, Kong, the Nginx web gateway, and ArgoCD itself stay
   Terraform-managed one-shot infra. This is a standard, defensible GitOps
   boundary (platform via Terraform, workloads via GitOps) and matches how
   this fleet already separates "environment" (warehouse-infra) from "chart
   shape" (each service repo) — recommended default. Full infra-as-GitOps is
   a valid future Phase 9 if the user wants it later, not blocking this plan.

2. **Source of truth stays `local.services`, not a new file.** The
   ApplicationSet's list generator is rendered by Terraform straight from
   `local.services`, so "each new Helm chart deploys an Application"
   literally means: add the service to `local.services` (already required
   today for Terraform to know about it) — nothing else. No new YAML file to
   remember to write per service.

3. **Image tag must actually change per build, or ArgoCD will never see a
   diff and will never roll a pod.** Today `var.image_tag` is a fixed value
   (`"local"`) for every service, which is *already* a documented pitfall in
   this fleet (a rebuilt image doesn't roll the Deployment because the pod
   spec is byte-identical). Under ArgoCD this stops being a manual
   `kubectl rollout restart` inconvenience and becomes a hard requirement:
   Argo's diffing is what triggers the sync, so a tag that never changes
   means Argo has genuinely nothing to do on a rebuild. Task 6 switches the
   tag to `local-<short-source-hash>` (the hash Terraform already computes
   in `service_source_hash`), which fixes the stale-binary pitfall as a
   side effect of adopting GitOps.

4. **ArgoCD keeps its own authentication, as an explicit, deliberate
   exception to the fleet's "everything is unauthenticated" posture.** The
   REST/MCP auth revert (2026-09-11) was about the *application data plane*.
   ArgoCD is *deployment control plane* — anyone who can push to it can
   deploy arbitrary manifests into the cluster. Recommending we do NOT
   disable its built-in admin auth. Flagging this for explicit sign-off since
   it's a new departure from "nothing in this fleet requires a credential."

5. **ArgoCD's UI is not exposed through Kong or the Nginx web gateway.**
   Both existing host edges (`:80` product UI, `:8000` product API) are
   reserved for product traffic per the localhost-edge-topology decision.
   Adding ArgoCD as a third thing behind either edge would violate that
   separation for no reason — recommend `kubectl port-forward` for local
   admin access instead (Task 9).

6. **Secrets are never rendered through an Argo `Application`'s Helm
   values.** Generated passwords (`random_password.service_db`,
   MCP keys, analytics DB creds) continue to be created as Kubernetes
   `Secret` objects by Terraform exactly as today (`kubectl_manifest` or the
   existing Terraform secret resources) — never placed in the
   `Application`'s `helm.valuesObject` (which is a Git-visible / cluster-CR-
   visible field, not a secret store). Charts must accept an
   `existingSecret` reference instead of an inline `database.url`. Task 3
   audits which charts already do this (`workforce-management`'s chart is
   known to require `database.url`/`database.existingSecret` per prior
   fleet-wide-rollout work) and closes gaps.

**DECIDED (2026-09-12):**
- ArgoCD auth: **disabled**, to match the fleet's unauthenticated posture
  (overrides the Phase 0 recommendation above — user's explicit call).
  `server.extraArgs: ["--disable-auth"]` in `helm-values/argocd.yaml`, or
  set `configs.params."server.disable.auth"=true` per the argo-cd chart's
  current values schema — verify exact key against the pinned chart version
  at execution time.
- Image tagging: **`local-<source-hash>`, no registry** (Task 6 as written).
- Scope for this pass: **services only** (Phase 1–5 and 7). Phase 6
  (ops-agent + console) is explicitly deferred to a follow-up, not part of
  this execution.

---

## Phase 1 — Install ArgoCD into the cluster (Terraform-managed bootstrap)

### Task 1: Add the Argo Helm repo and install ArgoCD via `helm_release`

**Objective:** Get ArgoCD itself running in-cluster, Terraform-managed like
every other platform component.

**Files:**
- Create: `warehouse-infra/terraform/argocd.tf`
- Modify: `warehouse-infra/terraform/providers.tf` (add `helm` repo entry if
  repos are tracked there; check existing pattern used for `kong`/`istio`)
- Create: `warehouse-infra/helm-values/argocd.yaml`

**Step 1: Add the namespace and Helm release**

```hcl
# warehouse-infra/terraform/argocd.tf

resource "kubernetes_namespace" "argocd" {
  metadata {
    name = "argocd"
    # Deliberately NOT istio-injection=enabled. ArgoCD talks to the
    # Kubernetes API and to Git/OCI registries over the internet; it does
    # not need to be in the product mesh, mirroring how `kong` is also
    # un-injected.
  }
  depends_on = [kind_cluster.warehouse]
}

resource "helm_release" "argocd" {
  name       = "argocd"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  version    = "7.7.11" # pin explicitly; check `helm search repo argo/argo-cd --versions` for latest at execution time
  namespace  = kubernetes_namespace.argocd.metadata[0].name

  timeout = 600
  wait    = true

  values = [file("${path.module}/../helm-values/argocd.yaml")]

  depends_on = [kubernetes_namespace.argocd]
}
```

**Step 2: `helm-values/argocd.yaml` — minimal local-cluster values**

```yaml
# Single-node kind cluster: no HA needed anywhere.
redis-ha:
  enabled: false
controller:
  replicas: 1
server:
  replicas: 1
  # No Ingress/Route — access is via `kubectl port-forward` only (Phase 0
  # decision 5). Leave insecure: false (keep TLS on the server's own
  # listener; port-forward still works fine against HTTPS).
  service:
    type: ClusterIP
repoServer:
  replicas: 1
applicationSet:
  enabled: true
  replicas: 1
```

**Step 3: Apply and verify**

Run: `cd warehouse-infra && terraform apply -target=helm_release.argocd`
Expected: `helm_release.argocd` created, `kubectl get pods -n argocd` shows
`argocd-server`, `argocd-repo-server`, `argocd-application-controller`,
`argocd-applicationset-controller`, `argocd-redis` all `Running`/`1/1`.

**Step 4: Retrieve the generated admin password and confirm login**

```bash
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d
kubectl -n argocd port-forward svc/argocd-server 8080:443 &
argocd login localhost:8080 --username admin --password '<password>' --insecure
```
Expected: `'admin' logged in successfully`.

**Step 5: Commit**

```bash
git add terraform/argocd.tf helm-values/argocd.yaml
git commit -m "feat(infra): install ArgoCD via Helm"
```

---

## Phase 2 — Chart readiness audit (`existingSecret` support)

### Task 2: Audit all 8 service charts for `existingSecret` support; close gaps

**Objective:** Make sure no chart requires a plaintext DB URL/secret to be
passed through Helm values (which an Argo `Application` CR would otherwise
have to carry) — every chart must accept a pre-created `Secret` name instead.

**Files (per gap found):**
- Modify: `<repo>/charts/<service>/templates/secret.yaml` (render the
  Secret conditionally, only when `existingSecret` is empty)
- Modify: `<repo>/charts/<service>/templates/deployment.yaml` (source
  `DATABASE_URL` from `existingSecret` when set)
- Modify: `<repo>/charts/<service>/values.yaml` (document
  `database.existingSecret`)

**Step 1: Check each chart's current values.yaml shape**

```bash
for svc in order-management inventory-storage wes-work-planning \
           fulfillment-execution workforce-management facility-layout \
           labor-performance process-path-management; do
  echo "== $svc =="
  git -C ~/warehouse-systems/$svc show origin/develop:charts/$svc/values.yaml \
    | grep -A3 '^database:'
done
```
Expected output: each block shows either `existingSecret: ""` already (done,
skip) or only `url: ""` (gap — needs the pattern added). Known from prior
work: `workforce-management` already requires `database.url` or
`database.existingSecret` — use its `secret.yaml`/`deployment.yaml` as the
reference implementation to copy into any chart missing it.

**Step 2: For each gap, patch `secret.yaml`**

```yaml
{{- if not .Values.database.existingSecret }}
apiVersion: v1
kind: Secret
metadata:
  name: {{ include "<service>.fullname" . }}-db
type: Opaque
stringData:
  DATABASE_URL: {{ .Values.database.url | quote }}
{{- end }}
```

**Step 3: Patch `deployment.yaml`'s env block**

```yaml
- name: DATABASE_URL
  valueFrom:
    secretKeyRef:
      name: {{ .Values.database.existingSecret | default (printf "%s-db" (include "<service>.fullname" .)) }}
      key: DATABASE_URL
```

**Step 4: Run each chart's render test**

Run: `helm template <service> charts/<service> --set database.existingSecret=fake-secret`
Expected: renders with no `database.url` needed, no Secret manifest emitted.

**Step 5: PR + merge each repo (feature branch → develop, CI green)**

One PR per repo touched; skip repos that already had the pattern.

---

## Phase 3 — Terraform creates the per-service Secrets directly (no chart-owned Secret in Argo's diff)

### Task 3: Replace the `database.url` computed value with a pre-created Secret + `existingSecret` reference

**Objective:** Terraform still generates the password and still creates the
`Secret`, but the `Application`'s Helm values now pass only the Secret's
*name*, never the connection string.

**Files:**
- Modify: `warehouse-infra/terraform/postgres.tf` (already has
  `random_password.service_db`; add a `kubernetes_secret` resource per
  service)
- Modify: `warehouse-infra/terraform/services.tf` → will be replaced by
  Task 5's ApplicationSet rendering, so hold this value shape in mind but
  don't edit `services.tf`'s `helm_release.service` block itself here (it's
  deleted wholesale in Task 7).

**Step 1: Add the Secret resource**

```hcl
resource "kubernetes_secret" "service_db" {
  for_each = local.services

  metadata {
    name      = "${each.key}-db"
    namespace = var.apps_namespace
  }

  data = {
    DATABASE_URL = local.database_urls[each.key]
  }
}
```

**Step 2: Verify**

Run: `terraform plan -target=kubernetes_secret.service_db`
Expected: 8 secrets to add, one per service, no other diffs.

**Step 3: Commit**

```bash
git add terraform/postgres.tf
git commit -m "feat(infra): create per-service DB secrets directly, ahead of ArgoCD cutover"
```

---

## Phase 4 — Give ArgoCD an Application per service, with full values parity

### Task 4: Add the `gavinbunney/kubectl` provider

**Objective:** Get a Terraform resource type that can apply a CRD instance
(`Application`) without needing that CRD to exist at Terraform's plan
time — the native `kubernetes_manifest` resource validates against the
live OpenAPI schema during `plan`, which fails on a first-ever apply because
the ArgoCD CRDs (installed by `helm_release.argocd` in the SAME apply)
don't exist yet when `plan` runs. `kubectl_manifest` applies via
`kubectl apply` semantics server-side and only needs the CRD to exist by
`apply` time, not `plan` time.

Already satisfied in practice for this rollout: ArgoCD (Task 1) was applied
and verified running BEFORE this task, so the CRDs already exist by the time
`argocd-apps.tf` is planned — the two-stage sequencing this task describes
is what already happened operationally, and `kubectl_manifest` is still the
right resource type going forward for any future from-scratch cluster
bring-up in one `terraform apply` (a fresh clone won't have this luxury).

**Files:**
- Modify: `warehouse-infra/terraform/providers.tf`

**Step 1: Add the provider, `terraform init -upgrade`**

### Task 5 (REVISED — see execution note below): One `kubectl_manifest.application` per service, reusing the EXACT existing values computation

**Objective:** One CR per service, with full parity to what `helm_release.
service` computes today — not a re-implementation.

**Design correction made during execution (superseding the original
ApplicationSet + Go-template sketch below the line):** `services.tf`'s
`helm_release.service` values block has NINE separate conditional merge
entries (analytics enable/database, process-path catalogue content +
Kafka-source flip, MCP enable, facility-events integration on both
publisher and consumer sides, order-management's path-catalogue-kafka flag,
frontend image, Gateway API routing). Re-deriving that logic inside an
ApplicationSet's Go-template `elements` list (as originally sketched) means
maintaining the SAME complex conditional logic in TWO places (HCL and Go
template) — a real risk of silent drift on a live cluster. The corrected
design keeps Terraform as the SOLE place that computes final Helm values
(unchanged from today), and only changes WHICH resource type applies them:

```hcl
# services.tf — extract the existing merge(...) block (unchanged content)
# out of helm_release.service's `values` argument into a plain local so
# both the (soon-to-be-removed) helm_release and the new kubectl_manifest
# can reference the identical computation during the transition.

locals {
  service_helm_values = {
    for name, svc in local.services :
    name => merge(
      {
        image = {
          repository = "warehouse/${name}"
          tag        = local.service_image_tags[name] # Task 6's content-derived tag
          pullPolicy = "IfNotPresent"
        }
        service = {
          type       = "ClusterIP"
          port       = 80
          targetPort = svc.port
        }
        # CHANGED from today: existingSecret, never a plaintext url (Phase 3).
        database = {
          existingSecret = "${name}-db"
        }
        ingress = { ... } # unchanged, same contents as today
      },
      contains(local.analytics_services, name) ? { analytics = { ... } } : {},
      contains(local.path_catalogue_services, name) ? { ... } : { ... },
      name == "process-path-management" && var.deploy_process_path_kafka_source ? { ... } : {},
      contains(local.mcp_services, name) ? { mcp = { enabled = var.deploy_mcp_servers } } : {},
      name == "facility-layout" && var.deploy_facility_events_integration ? { ... } : {},
      name == "inventory-storage" ? ( ... ) : {},
      name == "order-management" ? ( ... ) : {},
      contains(keys(local.frontend_remotes), name) ? { frontend = { ... } } : {},
      contains(local.gateway_api_pilot_services, name) ? { gatewayApi = { ... } } : {},
    )
  }
}
```

Every `...` above is copy-pasted VERBATIM from the current
`helm_release.service` block — this task is a pure refactor (extract to a
named local), not a rewrite. Diff the extracted local's rendered JSON
against the current live `helm get values <service> -n warehouse-systems
--all -o json` for every service before proceeding, to prove zero drift.

**Files:**
- Modify: `warehouse-infra/terraform/services.tf` (extract
  `local.service_helm_values`, keep `helm_release.service` reading from it
  unchanged for now — the resource itself isn't removed until Task 7)
- Create: `warehouse-infra/terraform/argocd-apps.tf`

**Step 1: Extract the local, re-plan, confirm zero diff**

Run: `terraform plan`
Expected: `No changes.` (the extraction must be value-identical; if
Terraform shows ANY diff here, stop — the refactor introduced drift, fix it
before continuing).

**Step 2: Add the per-service `Application` resource**

```hcl
# warehouse-infra/terraform/argocd-apps.tf

resource "kubectl_manifest" "application" {
  for_each = var.deploy_services ? local.services : {}

  yaml_body = yamlencode({
    apiVersion = "argoproj.io/v1alpha1"
    kind       = "Application"
    metadata = {
      name      = each.key
      namespace = "argocd"
    }
    spec = {
      project = "default"
      source = {
        repoURL        = "https://github.com/claudioed/${each.key}.git"
        targetRevision = "develop"
        path           = "charts/${each.key}"
        helm = {
          valuesObject = local.service_helm_values[each.key]
        }
      }
      destination = {
        server    = "https://kubernetes.default.svc"
        namespace = var.apps_namespace
      }
      syncPolicy = {
        automated = {
          prune    = true
          selfHeal = true
        }
      }
    }
  })

  depends_on = [
    helm_release.argocd,
    kubernetes_secret.service_db,
  ]
}
```

Using `for_each` directly over `local.services` (a native Terraform
for_each) rather than ArgoCD's own `ApplicationSet` list-generator CRD is
also a deliberate simplification versus the original sketch: Terraform
already has the authoritative loop (`local.services`); introducing a SECOND
loop construct (the ApplicationSet's own generator) to produce the same set
adds a moving part with no benefit here, since Terraform is already the
place a new service gets registered. (An `ApplicationSet` remains the
right tool when the *generator* itself needs to live outside Terraform,
e.g. a Git-directory generator scanning repos Terraform doesn't enumerate —
not the case here.)

**Step 3: PILOT ONE SERVICE FIRST — do not apply for all 8 at once**

Comment out every key except `"order-management"` in a scratch copy, or use
`-target='kubectl_manifest.application["order-management"]'`:

```bash
terraform plan -target='kubectl_manifest.application["order-management"]'
```
Read the full rendered `yaml_body` in the plan output. Confirm it matches
`helm get values order-management -n warehouse-systems --all -o json`
field-for-field (allow for the `database.url` -> `database.existingSecret`
change, which is intentional).

```bash
terraform apply -target='kubectl_manifest.application["order-management"]'
kubectl get application order-management -n argocd
```
Expected: `SYNC STATUS` shows `OutOfSync` (Argo sees the resources exist
with a different management label, not literally "missing") — this is
EXPECTED at this point per Task 7's note; do not be alarmed by it, and do
NOT yet remove `helm_release.service["order-management"]` from state. Stop
here and inspect `argocd app diff order-management` before Task 7 touches
anything.

**PILOT STATUS (2026-09-12): order-management verified live.** Synced,
Healthy, every managed resource reconciled with zero drift, REST healthz
green, and a live self-heal test confirmed (`kubectl scale --replicas=3`
reverted to 1 within ~1s). A real gap was found and fixed during the pilot
that is NOT in the original task text above: `helm_release.service`'s
`values` list merges a STATIC per-service file
(`helm-values/<service>.yaml`) with the COMPUTED block via Helm's own
multi-file deep-merge at install time — an Application's `helm.valuesObject`
accepts only one values object, so Terraform now pre-merges both layers
into `local.service_full_values` (services.tf) before Task 5's original
`local.service_helm_values` is used for the Application source. See
`services.tf`'s `service_full_values` local for the exact merge and why
`config`/`analytics` need an explicit nested merge (both layers set
different sub-keys under those two).

**DONE (2026-09-12):** fan-out to the remaining 7 services and Task 7's
`helm_release.service` state removal both shipped in
`feat(infra): adopt ArgoCD for GitOps deployment of all 8 service charts (#25)`
(commit `e138aee`). `terraform/argocd-apps.tf`'s `kubectl_manifest.application`
now runs `for_each = var.deploy_services ? local.services : {}`, covering the
full `local.services` set rather than just the "order-management" pilot, and
`terraform/services.tf` (~line 72) carries a comment confirming
`helm_release.service` was removed via `terraform state rm` on 2026-09-12
after verifying every Application was already Synced/Healthy — never a `helm
uninstall`; the running release was simply handed off to ArgoCD.

---

### Superseded sketch (kept for history — do not implement)

The original plan draft proposed rendering a single `ApplicationSet` CR
from a Terraform `templatefile(...)` over a Go-template `list` generator.
That sketch is retained below purely as a record of the design this plan
started with; Task 5 above is what was actually built and is the version to
follow.

```yaml
# (superseded) warehouse-infra/terraform/templates/applicationset.yaml.tftpl
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: warehouse-services
  namespace: argocd
spec:
  generators:
    - list:
        elements:
%{ for name, svc in services ~}
          - name: ${name}
            repoURL: https://github.com/claudioed/${name}.git
            chartPath: charts/${name}
            targetRevision: develop
            existingSecret: ${name}-db
            imageTag: ${image_tags[name]}
            kongPath: ${svc.path}
%{ endfor ~}
  template:
    metadata:
      name: '{{name}}'
      namespace: argocd
    spec:
      project: default
      source:
        repoURL: '{{repoURL}}'
        targetRevision: '{{targetRevision}}'
        path: '{{chartPath}}'
        helm:
          valuesObject:
            image:
              tag: '{{imageTag}}'
              pullPolicy: IfNotPresent
            database:
              existingSecret: '{{existingSecret}}'
            service:
              type: ClusterIP
              port: 80
      destination:
        server: https://kubernetes.default.svc
        namespace: warehouse-systems
      syncPolicy:
        automated:
          prune: true
          selfHeal: true
        syncOptions:
          - CreateNamespace=false
```

This was rejected because it cannot express the 9 conditional value blocks
in `services.tf` without duplicating that logic in Go-template syntax.

---

## Phase 5 — Cut Terraform out of the app-deployment path

### Task 6: Change the image tag to be content-derived (closes the stale-binary pitfall)

Already modeled in Task 5's `local.service_image_tags` — confirm the
`build-and-load.sh` script tags the image with the SAME value before
`kind load docker-image`, not the old fixed `var.image_tag`.

**Files:**
- Modify: `warehouse-infra/scripts/build-and-load.sh`
- Modify: `warehouse-infra/terraform/services.tf` (the `null_resource.build_and_load` trigger/command, to pass the hash-derived tag instead of `var.image_tag`)

**Step 1: Change the tag argument**

```diff
- command = "${path.module}/../scripts/build-and-load.sh '${each.key}' '${var.image_tag}' '${var.cluster_name}'"
+ command = "${path.module}/../scripts/build-and-load.sh '${each.key}' '${local.service_image_tags[each.key]}' '${var.cluster_name}'"
```

**Step 2: Run a rebuild and confirm Argo picks it up without manual restart**

```bash
touch ~/warehouse-systems/order-management/internal/domain/dummy.go # or any real change
terraform apply -target=null_resource.build_and_load\[\"order-management\"\]
argocd app get order-management --refresh
```
Expected: Argo shows `OutOfSync` immediately after refresh (image tag
differs from what's deployed), then after `syncPolicy.automated` fires (or
`argocd app sync order-management`), a new pod rolls with the new tag —
`kubectl get pods -n warehouse-systems -l app.kubernetes.io/name=order-management -o jsonpath='{.items[*].spec.containers[*].image}'`
shows the new hash-suffixed tag.

**Step 3: Commit**

```bash
git add terraform/services.tf scripts/build-and-load.sh
git commit -m "feat(infra): content-derived image tags so ArgoCD detects and rolls rebuilds"
```

### Task 7: Remove `helm_release.service` from Terraform entirely

**Objective:** ArgoCD is now the sole owner of the Helm release lifecycle for
these 8 services. Leaving `helm_release.service` in Terraform would fight
Argo for ownership of the same release (both would think they manage it).

**Files:**
- Modify: `warehouse-infra/terraform/services.tf` (delete the
  `helm_release.service` resource block; keep `null_resource.build_and_load`
  as-is — it still builds/loads images, just no longer also installs Helm)

**Step 1: Remove Terraform's Helm ownership without deleting the running release out from under Argo**

Since Argo's `Application` will already be `Synced`/managing the exact same
release name+namespace by this point (Task 5 already created it), removing
the `helm_release.service` resource from Terraform state must NOT trigger a
`helm uninstall`. Use `terraform state rm`, not a destroy:

```bash
for svc in order-management inventory-storage wes-work-planning \
           fulfillment-execution workforce-management facility-layout \
           labor-performance process-path-management; do
  terraform state rm "helm_release.service[\"$svc\"]"
done
```

**Step 2: Delete the resource block from `services.tf`, then confirm a clean plan**

Run: `terraform plan`
Expected: `No changes` for anything Helm-release-related (Terraform no
longer even knows the resource existed); `kubectl get applications -n argocd`
still shows all 8 `Synced`/`Healthy`.

**Step 3: Commit**

```bash
git add terraform/services.tf
git commit -m "feat(infra): ArgoCD is now sole owner of service Helm releases; remove helm_release.service from Terraform"
```

---

## Phase 6 — Extend to `warehouse-ops-agent` and the frontend/console chart

**DONE (2026-09-12).** ops-agent and warehouse-console are NOT in
`local.services` (no database), so they got their own two explicit
`kubectl_manifest` Application resources rather than a `for_each` over that
map — same values-extraction pattern as Task 5
(`local.ops_agent_helm_values`, `local.console_helm_values`), applied to
each release's own existing `helm_release` values block verbatim.

**Verified live:** all 10 Applications (8 services + these 2) Synced/
Healthy. `warehouse-ops-agent` needed a rebuild-and-reload after switching
to a content-derived image tag (same class of fix as Task 6, applied here
too) before it went Healthy — caught via `ImagePullBackOff` on the new pod,
fixed with `terraform apply -target=null_resource.build_and_load_ops_agent`.
`curl http://localhost:8000/api/warehouse-ops-agent/healthz` and
`curl http://localhost/` both 200 after. Both old `helm_release` entries
removed from Terraform state (never a `helm uninstall`) once confirmed.

### Task 8: Add ops-agent and the console/frontend chart to ArgoCD

**Objective:** Cover the two chart-owning apps that live outside
`local.services` (ops-agent has no database; the frontend chart per service
is templated within the same chart already, so it rides along automatically
— only the standalone `warehouse-console` shell needs its own entry).

**Files:**
- Modified: `warehouse-infra/terraform/ops-agent.tf` (extracted
  `local.ops_agent_helm_values` + `local.ops_agent_image_tag`, removed
  `helm_release.ops_agent`)
- Modified: `warehouse-infra/terraform/frontends.tf` (extracted
  `local.console_helm_values`, removed `helm_release.console`, rewired
  `kubernetes_deployment.web_gateway`'s `depends_on`)
- Modified: `warehouse-infra/terraform/argocd-apps.tf` (added
  `kubectl_manifest.ops_agent_application` and
  `kubectl_manifest.console_application`)

---

## Phase 7 — Validation

### Task 9: End-to-end GitOps proof

**Objective:** Prove the property this whole plan exists for: adding a new
service to `local.services` is sufficient to get it deployed, with no other
GitOps file to hand-write.

**Step 1:** Pick a currently-undeployed chart (or a scratch dummy chart) and
add one entry to `local.services`.

**Step 2:** `terraform apply` (only touches `kubectl_manifest.applicationset`
and the new secret — no new `helm_release` needed since that resource type
no longer exists in this file per Task 7).

**Step 3:** `kubectl get applications -n argocd` shows a NEW Application
appeared automatically, `argocd app sync <new-service>` (or wait for
`selfHeal`) brings it `Synced`/`Healthy`.

**Step 4:** Remove the entry from `local.services`, `terraform apply` again,
confirm the ApplicationSet's `list` generator drops the element and the
`Application` (and its Helm release) is pruned automatically
(`syncPolicy.automated.prune: true` — no orphaned release left behind).

### Task 10: Confirm drift correction (the actual value-add over `helm_release`)

**Step 1:** `kubectl scale deployment order-management -n warehouse-systems --replicas=5` (manual drift).

**Step 2:** Within `selfHeal`'s reconcile interval (default ~3 min, or force
with `argocd app sync order-management`), confirm it's reverted to
`replicaCount: 1` automatically — something `helm_release`'s one-shot
`terraform apply` never did.

---

## Phase 8 — Access & operational notes (documentation, no code)

### Task 11: Document the new workflow in `warehouse-infra/README.md`

**Files:**
- Modify: `warehouse-infra/README.md`

Add a section: "Deploying a new bounded context" — update the existing
sentence about `local.services` being the only registration point, note it
now ALSO triggers ArgoCD Application creation with zero extra files, note
`argocd login localhost:8080` (after `kubectl port-forward svc/argocd-server
-n argocd 8080:443`) is the way to inspect sync/health, and note ArgoCD is
NOT behind either of the two product edges (Task 0 decision 5) — deliberate,
not an oversight.

---

## Files likely to change (fleet-wide summary)

- `warehouse-infra/terraform/argocd.tf` (new)
- `warehouse-infra/terraform/argocd-apps.tf` (new)
- `warehouse-infra/terraform/templates/applicationset.yaml.tftpl` (new)
- `warehouse-infra/terraform/providers.tf` (add `kubectl` provider)
- `warehouse-infra/terraform/postgres.tf` (add `kubernetes_secret.service_db`)
- `warehouse-infra/terraform/services.tf` (remove `helm_release.service`;
  change image-tag trigger)
- `warehouse-infra/scripts/build-and-load.sh` (accept a hash-derived tag)
- `warehouse-infra/helm-values/argocd.yaml` (new)
- `warehouse-infra/README.md` (document new workflow)
- Per-service repo (only where the `existingSecret` gap exists):
  `charts/<service>/templates/secret.yaml`,
  `charts/<service>/templates/deployment.yaml`,
  `charts/<service>/values.yaml`

## Risks / tradeoffs

- **Chicken-and-egg on first apply** (ArgoCD CRDs + the `ApplicationSet` CR
  in the same `terraform apply`) — mitigated by using the `kubectl_manifest`
  resource type instead of native `kubernetes_manifest`, per Task 4's
  reasoning; if it still races on a from-scratch cluster, fall back to two
  staged applies (`-target=helm_release.argocd` first) rather than fighting
  the provider.
- **`terraform state rm` in Task 7 is a real "don't delete the running
  release" hazard** — verify the Argo `Application` is already `Synced` for
  every service BEFORE removing any `helm_release.service` state entry, or
  there will be a window with no owner and a real risk of an accidental
  `helm uninstall` if the order is reversed.
- **ArgoCD's own auth is a new, deliberate exception to the fleet's
  unauthenticated posture** — flagged in Phase 0 decision 4, needs explicit
  user sign-off, not something to silently decide either way.
- **This does not, by itself, add a container registry.** Local kind-load
  + content-derived tags is sufficient for Argo to detect and roll changes
  on this local cluster; it is NOT what a real production GitOps pipeline
  looks like (which would push immutable, CI-built tags to a registry and
  possibly use Argo Image Updater). Flagged in Phase 0 as an open question,
  not assumed.

## Open questions for the user (before Task 6 and Task 9 specifically)

1. Keep ArgoCD's own admin authentication ON (recommended) or match the rest
   of the fleet's unauthenticated posture?
2. Is `local-<source-hash>` image tagging acceptable for now, or is a local
   registry + Image Updater wanted as part of this same rollout rather than
   a later phase?
3. **RESOLVED (2026-09-12):** scope was confirmed to include Phase 6.
   `terraform/argocd-apps.tf` now has explicit `kubectl_manifest.ops_agent_application`
   and `kubectl_manifest.console_application` resources alongside the
   per-service `kubectl_manifest.application` for_each, shipped in
   `feat(infra): extend ArgoCD GitOps to warehouse-ops-agent and warehouse-console (#26)`.
   ops-agent and console are gated by their own `var.deploy_services` /
   `var.deploy_frontends` flags respectively, so this is done, not just
   planned.
