# ---------------------------------------------------------------------------
# The four bounded-context services.
#
# Each is installed from the Helm chart that already ships in its OWN repo
# (see locals.tf `chart_path`). warehouse-infra contributes only the
# environment: a values file per service in ../helm-values/ for the static
# bits, plus the values computed here (image tag, database URL, Kong route).
# Terraform-computed values are appended last, so they win over the file.
#
# Images are built and side-loaded into kind rather than pushed to a registry;
# `docker build` + `kind load docker-image` is the whole supply chain. The
# hash below re-triggers that build whenever Go source, migrations, the
# Dockerfile or the module files change.
# ---------------------------------------------------------------------------

locals {
  service_source_hash = {
    for name, svc in local.services :
    name => sha256(join("", concat(
      [for f in sort(fileset("${path.module}/../../${name}", "**/*.go")) : filesha256("${path.module}/../../${name}/${f}")],
      [for f in sort(fileset("${path.module}/../../${name}", "migrations/**")) : filesha256("${path.module}/../../${name}/${f}")],
      [
        filesha256("${path.module}/../../${name}/Dockerfile"),
        filesha256("${path.module}/../../${name}/go.mod"),
        filesha256("${path.module}/../../${name}/go.sum"),
      ],
    )))
  }

  # Gateway API (gateway-api.tf): every service in local.services now
  # migrates from Ingress to HTTPRoute, chart-rendered via each service's
  # own `gatewayApi` values block (added to all 7 charts in the fan-out
  # that followed the fulfillment-execution pilot -- see gateway-api.tf's
  # header for the pilot history and the real KIC bug/fix it uncovered).
  # A service in this set gets NO `ingress` block in its Helm values below
  # (Kong would otherwise route the same path twice, once via each
  # mechanism) and instead gets `gatewayApi.enabled=true` with the shared
  # Gateway as its parentRef.
  gateway_api_pilot_services = var.deploy_gateway_api ? toset(keys(local.services)) : toset([])

  # Content-derived image tag (ArgoCD rollout, Task 6). `var.image_tag`
  # ("local", fixed) previously left a rebuilt image's pod spec
  # byte-identical, which is exactly the documented "rebuilt image alone
  # does not roll a running Deployment" pitfall -- and under ArgoCD it is
  # no longer just an inconvenience: Argo's diffing IS what triggers a
  # sync, so a tag that never changes gives Argo nothing to detect on a
  # rebuild. Mirrors local.frontend_source_hash's existing pattern exactly.
  service_image_tags = {
    for name, hash in local.service_source_hash :
    name => "local-${substr(hash, 0, 12)}"
  }
}


resource "null_resource" "build_and_load" {
  for_each = var.deploy_services ? local.services : {}

  depends_on = [kind_cluster.warehouse]

  triggers = {
    source_hash = local.service_source_hash[each.key]
    image       = "warehouse/${each.key}:${local.service_image_tags[each.key]}"
    cluster     = var.cluster_name
  }

  provisioner "local-exec" {
    command = "${path.module}/../scripts/build-and-load.sh '${each.key}' '${local.service_image_tags[each.key]}' '${var.cluster_name}'"
  }
}

# ---------------------------------------------------------------------------
# NOTE: there is deliberately NO `helm_release.service` resource here
# anymore. ArgoCD (argocd-apps.tf's `kubectl_manifest.application`, one per
# service) is now the SOLE owner of these 8 Helm releases' lifecycle --
# removed from Terraform state via `terraform state rm` on 2026-09-12 after
# verifying every Application was already Synced/Healthy (never a `helm
# uninstall`; the running release was simply handed off). Re-adding a
# `helm_release.service` resource here would fight ArgoCD for ownership of
# the exact same release name+namespace. `null_resource.build_and_load`
# above still builds and side-loads each service's image -- that part of
# the supply chain is unrelated to which controller applies the chart.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# The full computed Helm values per service — extracted from helm_release.
# service's `values` argument (unchanged content, pure refactor) so both the
# Terraform-owned helm_release above AND the ArgoCD Application resources in
# argocd-apps.tf read from exactly one computation. This is what makes "add a
# service to local.services, get an ArgoCD Application with full parity" true
# without re-implementing any of the 9 conditional blocks below in a second
# place (e.g. an ApplicationSet Go-template).
#
# NOTE: `database` changed from a plaintext `url` to `existingSecret`
# (Phase 3 of the ArgoCD rollout) -- kubernetes_secret.service_db in
# postgres.tf creates "<service>-db" directly, so an Application CR's
# Git/cluster-visible values never carry a plaintext DSN.
# ---------------------------------------------------------------------------
locals {
  service_helm_values = {
    for name, svc in local.services :
    name => merge(
      {
        image = {
          repository = "warehouse/${name}"
          tag        = local.service_image_tags[name]
          # The image only ever exists in the kind nodes' containerd store, put
          # there by `kind load docker-image`. IfNotPresent stops the kubelet
          # trying to pull it from Docker Hub and ImagePullBackOff-ing.
          pullPolicy = "IfNotPresent"
        }

        service = {
          type       = "ClusterIP"
          port       = 80
          targetPort = svc.port
        }

        # Pre-created directly by Terraform (postgres.tf kubernetes_secret.
        # service_db) instead of a plaintext url the chart would otherwise
        # turn into its own Secret -- see this local's header comment.
        database = {
          existingSecret = "${name}-db"
        }

        # Kong route. `host: "" ` makes the rule host-agnostic, so it matches
        # requests to http://localhost/<prefix> regardless of the Host header.
        # konghq.com/strip-path drops the /<service> prefix before proxying, so
        # the pod still sees the paths its router actually registers
        # (GET /healthz, not GET /inventory-storage/healthz).
        #
        # A service in local.gateway_api_pilot_services gets NO Ingress at
        # all -- its routing is the chart's own `gatewayApi` block instead
        # (below), so this block is entirely skipped for it rather than
        # disabled-but-present, which would otherwise still create a Kong
        # route object nothing removes.
        ingress = {
          enabled   = !contains(local.gateway_api_pilot_services, name)
          className = "kong"
          annotations = {
            "konghq.com/strip-path" = "true"
          }
          hosts = [{
            host = ""
            paths = [{
              path     = svc.path
              pathType = "Prefix"
            }]
          }]
        }
      },
      # The "analytics report part" (ADR-0010): a projector (only writer)
      # + reports (read-only HTTP reader) pair, gated behind
      # analytics.enabled in each of these six charts. A single generated
      # role/database is used as both projectorUrl and reportsUrl for now
      # (see locals.tf's analytics_database_urls comment on the promotion
      # path to a distinct read-only role) -- every chart's own
      # values.yaml already documents reportsUrl falling back to
      # projectorUrl when left empty, so this is exactly that documented
      # local/dev baseline, not a workaround.
      contains(local.analytics_services, name) ? {
        analytics = {
          enabled = true
          database = {
            projectorUrl = local.analytics_database_urls[name]
            reportsUrl   = local.analytics_database_urls[name]
          }
        }
      } : {},
      # Process-path catalogue (ADR-0017 in fulfillment-execution / ADR-0012
      # in wes-work-planning / ADR-0013 in workforce-management): these three
      # services fail fast at boot without it. config/process-paths/sortable-fc.yaml
      # is the fleet's single published-language source of truth (see that
      # file's own header comment) -- fed to every consuming chart's
      # pathCatalogue.content verbatim so all three always agree.
      #
      # var.deploy_process_path_kafka_source=false (default): unchanged,
      # exactly as before this variable existed.
      #
      # var.deploy_process_path_kafka_source=true: the file mount is
      # disabled instead (pathCatalogue.enabled=false -- no ConfigMap
      # volume/mount rendered at all) and PATH_CATALOGUE_SOURCE=kafka is
      # injected via extraEnv. KAFKA_BROKERS needs no separate wiring:
      # every one of these three charts already sets it unconditionally
      # (it also feeds each chart's own EVENT_PUBLISHER/consumer wiring).
      # See variables.tf's full rollout-order rationale.
      # Process-path catalogue source, either the static file (default) or
      # process-path-management's Kafka topic (var.deploy_process_path_kafka_source).
      # A single ternary whose two branches share the SAME top-level key
      # set (pathCatalogue, extraEnv) is used deliberately: Terraform's
      # object-type unification for a ternary's two results is far more
      # forgiving when both sides declare the same keys (even if a
      # nested value differs, e.g. enabled=true+content=... vs
      # enabled=false) than when one side omits a key outright -- an
      # earlier version of this block that varied WHICH keys were
      # present between the true/false cases failed
      # `terraform validate` with "Inconsistent conditional result
      # types" for exactly that reason.
      contains(local.path_catalogue_services, name) ? {
        pathCatalogue = {
          enabled = !var.deploy_process_path_kafka_source
          content = var.deploy_process_path_kafka_source ? "" : local.path_catalogue_content
        }
        # Synchronous HTTP edge config (local.sync_edge_env) rides along in
        # the same extraEnv list, since a chart's extraEnv is one flat
        # list and a second merge entry would replace, not append.
        extraEnv = concat(var.deploy_process_path_kafka_source ? [
          {
            name  = "PATH_CATALOGUE_SOURCE"
            value = "kafka"
          },
        ] : [], lookup(local.sync_edge_env, name, []))
        } : {
        pathCatalogue = { enabled = false, content = "" }
        extraEnv      = lookup(local.sync_edge_env, name, [])
      },
      # process-path-management's own event publisher: the chart defaults
      # config.eventPublisher to "log" (never touches Kafka) so a plain
      # `terraform apply` with the default var.deploy_process_path_kafka_source
      # = false deploys a fully working REST API that just doesn't publish
      # anywhere yet -- correct, since nothing is consuming that topic in
      # that case either. Flipping the shared toggle to true switches BOTH
      # sides of the integration together: this publisher AND the three
      # consumers above, so they can never end up half-wired (a publisher
      # with no live consumer, or a consumer expecting Kafka data that
      # never arrives).
      name == "process-path-management" && var.deploy_process_path_kafka_source ? {
        config = {
          eventPublisher = "kafka"
        }
        kafka = {
          enabled = true
        }
      } : {},
      # MCP server per context (terraform/mcp.tf). Auth removed fleet-wide
      # (2026-09-09): MCP servers are unauthenticated now, so the chart's
      # mcp.enabled flag alone controls whether the MCP Deployment exists --
      # no keys needed.
      contains(local.mcp_services, name) ? {
        mcp = {
          enabled = var.deploy_mcp_servers
        }
      } : {},
      # facility-layout -> inventory-storage location-classification
      # integration (inventory-storage ADR-0013). Same "flip both sides
      # together" shape as the process-path block above, for the same
      # reason: a publisher with no consumer, or a consumer whose topic is
      # never written, are both silently broken states.
      #
      # var.deploy_facility_events_integration=false (default): unchanged.
      # facility-layout keeps the chart's "log" default (Postgres outbox
      # only, nothing reaches Kafka) and inventory-storage keeps its
      # default LOCATION_LOOKUP_MODE.
      #
      # true: facility-layout publishes its Published Language to
      # warehouse.facility.events, and inventory-storage maintains a local
      # cache from that topic instead of calling facility-layout over HTTP
      # on every stow. NOTE this only makes the CONSUMER stop depending on
      # facility-layout at runtime -- see variables.tf for the replay
      # caveat about events that predate the publisher flip.
      name == "facility-layout" && var.deploy_facility_events_integration ? {
        config = {
          eventPublisher = "kafka"
        }
        kafka = {
          enabled = true
        }
      } : {},
      # inventory-storage's side of that same integration. Kept as its own
      # merge entry (rather than folded into the block above) because the
      # two services need DIFFERENT keys: facility-layout needs a publisher
      # switch, inventory-storage needs a consumer-mode env var. Note both
      # branches of this ternary declare the SAME key set -- see the
      # process-path block's comment for the "Inconsistent conditional
      # result types" failure that rule exists to avoid.
      name == "inventory-storage" ? (var.deploy_facility_events_integration ? {
        extraEnv = [
          {
            name  = "LOCATION_LOOKUP_MODE"
            value = "kafka"
          },
        ]
        } : {
        extraEnv = []
      }) : {},
      # order-management's process-path catalogue validation
      # (order-management ADR-0013). Independent of the
      # var.deploy_process_path_kafka_source block above -- OM is a NEW
      # consumer of this topic, not a file-to-kafka cutover -- so this is
      # its own single-service ternary, same "both branches declare the
      # SAME key set" shape as the inventory-storage block directly
      # above, for the same "Inconsistent conditional result types"
      # reason. KAFKA_BROKERS needs no separate wiring here: OM's
      # helm-values already sets config.eventPublisher=kafka
      # unconditionally (it already publishes integration/analytics
      # events), so the chart always renders KAFKA_BROKERS regardless of
      # this flag.
      name == "order-management" ? (var.deploy_order_management_path_catalogue_kafka ? {
        extraEnv = [
          {
            name  = "PATH_CATALOGUE_SOURCE"
            value = "kafka"
          },
        ]
        } : {
        extraEnv = []
      }) : {},
      # The context's own Module Federation remote, served by its own nginx
      # pod (frontends.tf builds the image; the chart owns the workload
      # shape). Deliberately NO ingress/httproute here: frontend routing
      # belongs to the Nginx web gateway, and routing it through Kong is
      # exactly what ADR-0005 forbids. The Service stays ClusterIP so the
      # gateway remains the single host-facing frontend endpoint.
      contains(keys(local.frontend_remotes), name) ? {
        frontend = {
          enabled = true
          image = {
            repository = "warehouse/${name}-frontend"
            # Content-addressed, NOT the fixed "local" tag this file uses for
            # the Go image above. See frontends.tf's comment: a fixed tag
            # leaves the pod template identical after a rebuild, so the old
            # bundle keeps serving until something else changes the spec.
            tag        = "local-${local.frontend_source_hash[name]}"
            pullPolicy = "IfNotPresent"
          }
        }
      } : {},
      # Gateway API routing (see local.gateway_api_pilot_services above and
      # gateway-api.tf's header for the full pilot history). Mirrors
      # exactly what the `ingress` block above would have expressed for
      # this service -- same path prefix, same strip-prefix behavior via
      # HTTPRoute's own `filters` block -- so this is a like-for-like
      # routing swap, not a behavior change. `sectionName: "http"` matches
      # the shared Gateway's one listener name (gateway-api.tf); Kong's
      # KIC only reconciles a parentRef whose sectionName resolves to a
      # real listener on that Gateway.
      contains(local.gateway_api_pilot_services, name) ? {
        gatewayApi = {
          enabled = true
          parentRefs = [{
            name        = local.gateway_name
            namespace   = var.kong_namespace
            sectionName = "http"
          }]
          hosts = [{
            path     = svc.path
            pathType = "PathPrefix"
          }]
          stripPath = true
        }
      } : {}
    )
  }

  # ---------------------------------------------------------------------
  # Full per-service values, static file + computed layer PRE-MERGED into
  # one object. helm_release.service (above) doesn't need this -- Helm's
  # own engine deep-merges the `values = [file(...), yamlencode(...)]`
  # list at install/upgrade time. ArgoCD's Application `helm.valuesObject`
  # (argocd-apps.tf) accepts only ONE values object per source, so this is
  # the one place that merge has to happen ahead of time, in Terraform.
  #
  # A plain top-level `merge()` (computed wins) is correct for every key
  # EXCEPT the two that appear in BOTH layers with nested sub-keys neither
  # side fully owns: `config` (static sets httpAddr/eventPublisher; the
  # computed layer conditionally ALSO sets eventPublisher for
  # process-path-management/facility-layout's Kafka-source flags) and
  # `analytics` (static sets `enabled: true`; the computed layer adds
  # `database.projectorUrl/reportsUrl` alongside it). Those two get an
  # explicit nested merge so neither layer's keys are silently dropped --
  # verified against every chart's helm-values file: no other top-level
  # key is set by both layers (see the ArgoCD rollout plan's Phase 4 audit).
  # ---------------------------------------------------------------------
  static_helm_values = {
    for name, svc in local.services :
    name => yamldecode(file("${path.module}/../helm-values/${name}.yaml"))
  }

  service_full_values = {
    for name, svc in local.services :
    name => merge(
      local.static_helm_values[name],
      local.service_helm_values[name],
      {
        config    = merge(lookup(local.static_helm_values[name], "config", {}), lookup(local.service_helm_values[name], "config", {}))
        analytics = merge(lookup(local.static_helm_values[name], "analytics", {}), lookup(local.service_helm_values[name], "analytics", {}))
      }
    )
  }
}

# ---------------------------------------------------------------------------
# Deliberately NO dependency on the observability stack.
#
# helm_release.service above depends on the namespace, Postgres, Kong and the
# image build -- and on nothing in observability.tf. That is the wiring, and it
# is a decision rather than an oversight:
#
#   * The services' OTLP exporters are non-blocking. A service whose collector
#     is absent buffers, fails the export, and keeps serving; it does not fail
#     to start. Making the app releases wait on a Collector would invent a
#     startup dependency the application code specifically avoids having.
#   * `terraform apply -var=deploy_observability=false` therefore leaves a
#     fully working cluster, and bringing the stack up later needs no restart
#     of anything in warehouse-systems.
#
# The one thing that IS a contract between the two halves is the DNS name
# `otel-collector.observability.svc.cluster.local:4317` (local.otlp_grpc_endpoint,
# `terraform output otlp_endpoint`), which each service repo points its own Helm
# values at. That wiring lives in the service repos, not here.
