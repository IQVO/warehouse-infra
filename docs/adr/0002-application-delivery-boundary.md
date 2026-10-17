# ADR 0002: Application delivery boundary: Terraform owns the platform, Helm and ArgoCD own the applications

## Status

Accepted (2026-10-17). Amended by [ADR 0003](0003-per-application-terraform-state.md)
(D6: one Terraform state per application). Phase 1 (module pilot:
order-management and network-inventory-planning) merged and its state moves
recorded on the cluster's state (2026-10-17). Phases 2 to 6 open.

## Context

### What already follows the boundary

Every application's Kubernetes objects are rendered by the Helm chart in its
own repo (`charts/<context>/`): Deployments, Services, the HTTPRoutes for
the REST, MCP and reports surfaces, the KongPlugins, CronJobs and HPAs.
ArgoCD installs each chart from the service repo's GitHub `develop`. Kong
configuration moved into the charts on 2026-10-13. Terraform no longer runs
`helm_release` for any application; it creates one ArgoCD `Application` per
application (`terraform/argocd-apps.tf`).

### What does not

**Terraform still writes the application configuration.** For the twelve
contexts in `local.services`, `terraform/services.tf` builds the values with
a twelve-layer `merge()`, five layers of which are `name == "<context>"`
special cases. It then merges the result over `helm-values/<context>.yaml`
with hand-written nested merges for `config`, `analytics` and `kafka`.
`terraform/kind-overlay.tf` hand-writes a second deep merge for
`helm-values/kind-resources/<context>.yaml`, repeated six times. Everything
reaches ArgoCD as one `valuesObject`. Route paths, Gateway `parentRefs`,
consumer group names, broker addresses, the sync-edge env
(`local.sync_edge_env`) and four application feature switches
(`deploy_mcp_servers`, `deploy_facility_events_integration`,
`deploy_process_path_kafka_source`,
`deploy_order_management_path_catalogue_kafka`) are all HCL. The known traps
in `CLAUDE.md` (non-negotiables 5 to 7) come from this second merge
language: ternary branches must share a key set, the computed layer silently
overrides `helm-values/`, an `extraEnv` in a values file is dropped, and the
same env var set in both layers makes ArgoCD fail its diff. The rollback
switches in `docs/rollback-switches.md` need a `terraform apply` for the
same reason.

**Secrets travel inside the Application.** The analytics DSNs, password
included, are passed as `analytics.database.projectorUrl`/`reportsUrl` in
the `valuesObject`, so they are stored in clear text in the `Application`
objects in the `argocd` namespace.

**Applications that do not fit the map are copied by hand.**
network-fulfillment, network-inventory-planning, warehouse-ops-agent,
warehouse-console and ecosystem each live in their own file with their own
build, Secret, values and Application. The repo has six `build_and_load*`
resource blocks, six inline `Application` resources, the source-hash
expression in four files, six copies of the kind-overlay merge and twelve
copies of the Gateway `parentRefs` block. About 3,100 of the roughly 7,000
lines of HCL sit in files that are mostly per-application wiring.

**The platform depends on the applications.** The Postgres initdb script
(`terraform/templates/init-databases.sql.tftpl`) creates every
application's role and database, and only runs on an empty volume, so every
new context needs hand-written SQL on the live database. PgBouncer's
`[databases]` section and `userlist.txt` list every application database and
password. The platform cannot be planned without every application.

**One root module, one state.** The kind cluster, the platform and every
application share one state, so every application change plans the whole
cluster. A plan hashes every sibling checkout (minutes) and prints the
initdb script, with every role password, in the Postgres release diff. The
Kubernetes provider's documentation warns against configuring the provider
from a cluster created in the same configuration. This repo gets a clean
single apply by reading the cluster's credential attributes (`README.md`,
"Design notes"), which works, but ties the cluster, the platform and the
applications to one lifecycle.

**Some platform objects are imperative.** The Gateway API CRDs, the
`GatewayClass` and the `Gateway` are applied by `null_resource` with
`kubectl` in a `local-exec` (`terraform/gateway-api.tf`). That is the
mechanism that made the KongClusterPlugins and the reports routes silently
disappear from the cluster before 2026-10-13: a `local-exec` reruns only
when its triggers change, while the state keeps claiming the object exists.

## Decision

### D1. The boundary

- **Terraform owns** the kind cluster; the platform (Postgres, PgBouncer,
  Kafka, Kong and the Gateway API objects, Istio, Kiali, metrics-server,
  Prometheus, Grafana, Loki and Alloy, Jaeger, the OpenTelemetry Collector,
  ArgoCD, the Nginx web gateway); and, per application, only the platform
  contract: the database role, database and `<context>-db` Secret (and the
  analytics database and its Secret), the image build with its
  content-derived tag, and the ArgoCD `Application`.
- **The application's Helm chart, rendered by ArgoCD, owns** every
  Kubernetes object of the application.
- **Values files in this repo own** every application configuration value.
- Terraform never creates a Kubernetes object that belongs to an
  application's release and never writes application configuration. No
  credential is ever placed in a values file or a `valuesObject`; charts
  read credentials from the platform-contract Secrets (`existingSecret`).

### D2. Application values live in Git and reach ArgoCD as value files

Each `Application` gets two sources: the chart (service repo, `develop`,
`charts/<context>`) and this repo (`ref: values`, `develop`). The value
files, lowest precedence first:

1. `$values/helm-values/_platform.yaml`: facts about the platform that every
   chart needs (the Gateway `parentRef`, Kafka brokers, the OTLP endpoint,
   the web origin, Kong plugin settings);
2. `$values/helm-values/<context>.yaml`: the context's complete
   configuration, including everything `services.tf` computes today
   (routes, MCP, analytics, consumers, sync-edge env, feature switches);
3. `$values/helm-values/kind-resources/<context>.yaml`: the kind CPU-request
   overlay.

Helm deep-merges value files natively, which removes the hand-written merges
in `services.tf` and `kind-overlay.tf`. The `valuesObject` keeps only what
Terraform genuinely computes: the content-derived image tags. ArgoCD gives
`valuesObject` precedence over value files, so that override stays narrow.
Where Terraform installs the platform piece that a fact in `_platform.yaml`
describes, it reads the fact from that file (`yamldecode(file(...))`), so
each platform fact has one source. Charts derive route paths and
`parentRefs` from their own name and the platform file; a context's values
file overrides them only on exception.

### D3. One `bounded-context` module for every application

`terraform/modules/bounded-context` describes one application deployed on
this platform: optional database and analytics database (role, password,
Secret), either a local image build (source directory, content hash,
`kind load`) or a prebuilt image, optional frontend image, and the ArgoCD
`Application`. It is called with `for_each` over a single registry map that
lists every application, the five that are copied by hand today included;
what differs between applications is an optional attribute, not a file.
There is no module per application.

Every refactor that moves resources into the module ships `moved` blocks,
and its acceptance check is a `terraform plan` against the live state that
shows exactly the changes the same plan shows on `develop`. Destroying and
recreating an `Application` would prune the application's workloads, so a
plan that does is a failed refactor.

### D4. The platform stops depending on the applications

The platform's configuration names no application:

- PgBouncer authenticates with `auth_query` through a dedicated lookup role
  and routes through a `*` fallback database entry, so neither its
  `pgbouncer.ini` nor a userlist lists application databases or passwords.
- Creating an application's role and database moves from the initdb script
  to the application layer. The mechanism (the `postgresql` Terraform
  provider through a host-reachable port, or CloudNativePG `Database` and
  `DatabaseRole` resources rendered by each chart) is decided in its own
  ADR before this phase starts.

### D5. Platform objects are declarative

The Gateway API CRDs, `GatewayClass` and `Gateway` move from `null_resource`
`local-exec` to declarative resources that Terraform reconciles (a
`helm_release` of a local chart or `kubectl_manifest`). They stay in
Terraform: they are platform.

### D6. Three states, applied in order

After D2 to D4 have landed, the root module splits into `terraform/00-cluster`
(kind), `terraform/10-platform` and `terraform/20-apps` (the module
instances). Each layer publishes outputs that the layer above reads through
`terraform_remote_state` on the local backend; no layer reads a layer above
it.
The split waits for D4: until then the platform needs the applications'
passwords, which would make the dependency circular.

## Rollout

Each phase is its own pull request, verified as described in D3, and none
applies to the cluster without the maintainer's go-ahead.

1. **Module pilot.** Create `terraform/modules/bounded-context`; move
   order-management (from `local.services`) and network-inventory-planning
   (a hand-copied one) onto it with `moved` blocks.
2. **All applications on the module.** Move the rest; delete the per-app
   files and the six-way kind-overlay merge.
3. **Values in Git.** Two-source Applications, `helm-values/_platform.yaml`,
   the computed values folded into `helm-values/<context>.yaml`. Charts that
   accept the analytics DSN only as a plain value gain `existingSecret` first.
   The four application switches and `local.sync_edge_env` are retired;
   `docs/rollback-switches.md`, the `CLAUDE.md` non-negotiables 5 to 7 and
   the `add-or-change-a-service` skill are rewritten in the same pull request.
4. **Platform independent of applications** (D4), after its database
   provisioning ADR.
5. **Declarative Gateway API objects** (D5). Independent of the others; can
   land at any point.
6. **State split** (D6).

## Consequences

Positive:

- Registering a context is one registry entry plus one values file. No
  per-application `.tf` file, and after phase 4 no hand-written SQL.
- Application configuration is GitOps like the charts already are: a merged
  values change reaches the cluster through an ArgoCD sync, with no
  `terraform apply`, and a revert is a Git revert. This includes the
  rollback switches.
- Values merge with Helm's semantics in one language. The traps listed in
  `CLAUDE.md` non-negotiables 5 to 7 disappear with the code that causes
  them.
- No credential is stored in an `Application` object.
- After phase 6 an application plan no longer reads Postgres, Kafka or the
  observability stack, and no longer prints role passwords.

Accepted costs:

- Values deploy from this repo's GitHub `develop`, not from the local
  working tree. A values edit cannot be tried with a local `terraform
  apply`; it is checked with `helm template` of the sibling chart before
  merge (a make target is added in phase 3). This is the model the charts
  already follow.
- A values key that the chart on `develop` does not know is ignored by Helm
  without an error. A values change that needs a new chart key merges after
  the chart change.
- Image tags stay a Terraform output, because local content-hash builds
  cannot be committed. ApplicationSet is not adopted until images come from
  a registry (a kind local registry plus Argo CD Image Updater), which is
  outside this decision.
- Every phase is a refactor of live state. The plan-parity check in D3 is
  mandatory, not advisory.

Not decided here: the database provisioning mechanism (its own ADR); whether
the per-context Grafana dashboards and alert rules (`terraform/dashboards/`,
`terraform/alerting/`) ship from the charts through the Grafana sidecar or
stay platform files; replacing the `bitnamilegacy` Postgres and Kafka images.

## Alternatives considered

- **One Terraform module per application.** Rejected: seventeen modules
  holding the same resources would move the duplication into new files.
  HashiCorp's module guidance asks a module to raise the level of
  abstraction, which "an application on this platform" does once.
- **Keep the values in HCL and only introduce the module.** Rejected: it
  keeps the second merge language and its traps, and the application
  configuration stays outside Helm.
- **Values files in each service repo, next to the chart.** Rejected: the
  environment's configuration would spread over seventeen repos, and Argo
  CD's best practices keep environment configuration apart from application
  source. This repo is the environment.
- **ApplicationSet with a Git generator.** Deferred: see the image-tag cost
  above.
- **ArgoCD app-of-apps for the platform as well, Terraform only for the
  cluster.** Rejected for now: the platform stays in Terraform by
  requirement. Revisit after phase 6.

## References

- HashiCorp, "Creating modules: when to write a module":
  https://developer.hashicorp.com/terraform/language/modules/develop
- Argo CD, multiple sources for an Application:
  https://argo-cd.readthedocs.io/en/stable/user-guide/multiple_sources/
- Argo CD, Helm value precedence (`parameters > valuesObject > values >
  valueFiles`): https://argo-cd.readthedocs.io/en/stable/user-guide/helm/
- Argo CD best practices, separating configuration from source:
  https://argo-cd.readthedocs.io/en/stable/user-guide/best_practices/
- Terraform Kubernetes provider, credentials from resources in the same
  configuration: https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs
- CloudNativePG declarative database and role management:
  https://cloudnative-pg.io/docs/devel/operator_capability_levels
