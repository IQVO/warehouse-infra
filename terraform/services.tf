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

        # Kong route. `host: ""` makes the rule host-agnostic, so it matches
        # requests to http://localhost/<prefix> regardless of the Host header.
        # konghq.com/strip-path drops the /<service> prefix before proxying, so
        # the pod still sees the paths its router actually registers
        # (GET /healthz, not GET /inventory-storage/healthz).
        ingress = {
          enabled   = true
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
