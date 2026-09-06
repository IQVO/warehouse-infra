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
}


resource "null_resource" "build_and_load" {
  for_each = var.deploy_services ? local.services : {}

  depends_on = [kind_cluster.warehouse]

  triggers = {
    source_hash = local.service_source_hash[each.key]
    image       = "warehouse/${each.key}:${var.image_tag}"
    cluster     = var.cluster_name
  }

  provisioner "local-exec" {
    command = "${path.module}/../scripts/build-and-load.sh '${each.key}' '${var.image_tag}' '${var.cluster_name}'"
  }
}

resource "helm_release" "service" {
  for_each = var.deploy_services ? local.services : {}

  depends_on = [
    kubernetes_namespace.apps,
    helm_release.postgresql,
    helm_release.kong,
    null_resource.build_and_load,
  ]

  name      = each.key
  chart     = each.value.chart_path
  namespace = var.apps_namespace

  timeout = 600
  wait    = true

  values = [
    # Static, human-editable environment config.
    file("${path.module}/../helm-values/${each.key}.yaml"),

    # Computed config. Appended last so it takes precedence.
    yamlencode(merge(
      {
        image = {
          repository = "warehouse/${each.key}"
          tag        = var.image_tag
          # The image only ever exists in the kind nodes' containerd store, put
          # there by `kind load docker-image`. IfNotPresent stops the kubelet
          # trying to pull it from Docker Hub and ImagePullBackOff-ing.
          pullPolicy = "IfNotPresent"
        }

        service = {
          type       = "ClusterIP"
          port       = 80
          targetPort = each.value.port
        }

        # The chart turns this into a Secret and mounts it as DATABASE_URL.
        database = {
          url = local.database_urls[each.key]
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
          enabled   = !contains(local.gateway_api_pilot_services, each.key)
          className = "kong"
          annotations = {
            "konghq.com/strip-path" = "true"
          }
          hosts = [{
            host = ""
            paths = [{
              path     = each.value.path
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
      contains(local.analytics_services, each.key) ? {
        analytics = {
          enabled = true
          database = {
            projectorUrl = local.analytics_database_urls[each.key]
            reportsUrl   = local.analytics_database_urls[each.key]
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
      contains(local.path_catalogue_services, each.key) ? {
        pathCatalogue = {
          enabled = !var.deploy_process_path_kafka_source
          content = var.deploy_process_path_kafka_source ? "" : local.path_catalogue_content
        }
        extraEnv = var.deploy_process_path_kafka_source ? [
          {
            name  = "PATH_CATALOGUE_SOURCE"
            value = "kafka"
          },
        ] : []
        } : {
        pathCatalogue = { enabled = false, content = "" }
        extraEnv      = []
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
      each.key == "process-path-management" && var.deploy_process_path_kafka_source ? {
        config = {
          eventPublisher = "kafka"
        }
        kafka = {
          enabled = true
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
      contains(local.gateway_api_pilot_services, each.key) ? {
        gatewayApi = {
          enabled = true
          parentRefs = [{
            name        = local.gateway_name
            namespace   = var.kong_namespace
            sectionName = "http"
          }]
          hosts = [{
            path     = each.value.path
            pathType = "PathPrefix"
          }]
          stripPath = true
        }
      } : {}
    )),
  ]
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
