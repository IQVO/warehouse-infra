# ADR 0006: The Gateway API objects are kubectl_manifest resources, and the CRD bundle is vendored

## Status

Accepted (2026-10-18). Implements [ADR 0002](0002-application-delivery-boundary.md)
D5 (phase 5) and chooses between the two mechanisms D5 named.

## Context

The Gateway API CRDs, the `GatewayClass` and the `Gateway` are three
`null_resource` blocks that run `kubectl apply` in a `local-exec`
(`terraform/gateway-api.tf`). Four problems follow:

1. **Terraform never looks at the objects again.** A `local-exec` reruns only
   when its `triggers` change. A deleted or edited object is not a diff. This
   is how the KongClusterPlugins and the reports routes disappeared from the
   cluster before 2026-10-13, and it can happen to the Gateway.
2. **Applications race the CRDs.** Nothing orders an `Application` after the
   CRDs, so ArgoCD can sync an `HTTPRoute` before its CRD exists and exhaust
   its retries. The cluster rebuild on 2026-10-18 needed a staged
   `terraform apply -target=null_resource.gateway -target=helm_release.argocd`
   first.
3. **The apply needs the network.** `kubectl apply -f https://github.com/...`
   fetches the bundle at apply time. The only pin is a version string.
4. **Destroy is hand-written.** Each resource carries a `when = destroy`
   provisioner, because `count = 0` would otherwise orphan the object.

ADR 0002 D5 says to move them to declarative resources, "a `helm_release` of
a local chart or `kubectl_manifest`", and leaves the choice open.

## Decision

1. **`kubectl_manifest` for every object.** One resource per document of the
   CRD bundle, one for the `GatewayClass`, one for the `Gateway`. The
   provider reads the live object on every plan, so a deleted or edited
   object is a diff and the next apply repairs it. `kubectl_manifest` and not
   `kubernetes_manifest`, because the latter needs the CRD's schema at plan
   time and the CRD is created in the same apply. The CRD resources use
   server-side apply with forced conflicts (the HTTPRoute CRD alone is about
   250 KB), and the provider retries (`apply_retry_count = 5`) the moment
   between a CRD being created and the API server serving it.
2. **The CRD bundle is vendored.** `terraform/gateway-api/standard-install-<tag>.yaml`
   is the release's standard-channel bundle, one file per tag, added by
   `scripts/vendor-gateway-api.sh <tag>`. `var.gateway_api_version` selects
   the file; a missing file fails the plan with the command to run. A plan
   needs no network, and a version bump is a reviewable diff.
3. **Applications wait for the platform.** `local.gateway_ready` is the
   Gateway's UID. It is passed to `modules/application` as `platform_ready`
   and read by the `Application`'s precondition, which orders every
   `Application` after the CRDs, the class and the Gateway. A plain
   `terraform apply` works on an empty cluster; no `-target` stage.
4. **Adoption needs no state surgery.** The first apply creates the 14
   `kubectl_manifest` resources, which adopt the existing objects with
   apply semantics, and destroys the three `null_resource` entries. Terraform
   does not run a removed resource's destroy provisioner (checked on
   Terraform 1.5.7), so nothing deletes a CRD.
5. **Destroying a manifest deletes the object.** For a CRD that includes every
   object of the kind. `deploy_gateway_api = false`, `terraform destroy` and a
   bundle that drops a document do this, as the old destroy provisioners did.

The mechanism was rehearsed before it went into the repo, on a scratch kind
cluster. The old resources were applied, an `HTTPRoute` was created, and the
new configuration was swapped in with the same state:

- the plan was 14 to add and 3 to destroy, and the apply took a few seconds;
- the HTTPRoute CRD and the route kept their UIDs, so nothing was recreated;
- the next plan was empty;
- a deleted Gateway, a removed GatewayClass annotation and a deleted CRD were
  each planned as a diff and repaired by one apply.

## Consequences

Positive:

- Drift on the Gateway API objects is visible in every plan and repaired by
  the next apply. This is the property the `null_resource` lacked.
- One `terraform apply` brings up an empty cluster in order.
- Plans need no network, and the installed bundle is pinned by the file.
- No `when = destroy` provisioners, and no `kubeconfig` file in this part of
  the configuration.

Negative:

- The Terraform state grows by about 5 MB: `kubectl_manifest` keeps the body
  and the live copy of every document (1.2 MB of YAML). The first apply and a
  version bump print those bodies in the plan.
- The repository carries 1.2 MB per vendored version. Old versions can be
  deleted once no environment pins them.
- A bundle that no longer carries a document deletes its CRD and every route
  of it. The comment on `var.gateway_api_version` says to read the diff first.
- `kubectl_manifest` has no wait for a CRD to be Established, so ordering
  inside one apply relies on the provider's retries.

## Alternatives considered

- **A `helm_release` of a local chart.** Helm does not detect drift, which
  is the failure this ADR fixes. Objects in `crds/` are never upgraded, and
  objects in `templates/` cannot adopt the 14 existing ones without first
  annotating each with Helm's ownership.
- **`data "http"` to fetch the bundle.** It adds a provider, makes every plan
  need the network, and pins by tag only.
- **A trimmed bundle (only the kinds the fleet uses).** It departs from the
  supported install, and Kong's controller watches the optional kinds when
  their CRDs exist.
- **Leaving the CRDs outside Terraform.** ArgoCD cannot own them, because
  ADR 0002 D1 keeps platform objects in Terraform.
