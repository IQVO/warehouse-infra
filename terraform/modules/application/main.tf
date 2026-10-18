# ---------------------------------------------------------------------------
# One application deployed on this platform (ADR 0002 decision D3, ADR 0004):
# the platform contract Terraform owns for it, and nothing else.
#
#   - generated database passwords (never committed; they live only in state)
#   - the <name>-db / <name>-analytics-db Secrets the chart reads through
#     existingSecret, and any other Secret the root supplies (var.secrets)
#   - the local image build(s), tagged by content so ArgoCD sees a new tag on
#     every rebuild
#   - the ArgoCD Application that installs the chart from the application's
#     own repo with its value files from this repo (helm-values/, ADR 0002
#     D2); its valuesObject carries only the image tags
#
# Every Kubernetes object of the application itself (Deployments, Services,
# HTTPRoutes, KongPlugins, ...) comes from that chart, never from here.
# ---------------------------------------------------------------------------

locals {
  source_dir = "${var.repos_root}/${var.name}"

  # The same construction the per-service hashes used before this module
  # existed: every file matched by each glob, in glob order and sorted within
  # a glob, then the Dockerfile and the Go module files.
  source_hash = var.image == null ? "" : sha256(join("", concat(
    flatten([
      for glob in var.image.hash_globs : [
        for f in sort(fileset(local.source_dir, glob)) : filesha256("${local.source_dir}/${f}")
      ]
    ]),
    [
      filesha256("${local.source_dir}/Dockerfile"),
      filesha256("${local.source_dir}/go.mod"),
      filesha256("${local.source_dir}/go.sum"),
    ],
  )))

  image_tag          = var.image == null ? null : "local-${substr(local.source_hash, 0, 12)}"
  frontend_image_tag = var.frontend == null ? null : "local-${var.frontend.source_hash}"

  # The application's configuration lives in value files in this repo
  # (ADR 0002 D2), lowest precedence first: the platform facts, the
  # application's own file, the kind CPU overlay.
  value_files = [
    "$values/${var.values.dir}/_platform.yaml",
    "$values/${var.values.dir}/${var.name}.yaml",
    "$values/${var.values.dir}/kind-resources/${var.name}.yaml",
  ]

  # The valuesObject, which ArgoCD gives precedence over the value files:
  # only what Terraform owns (var.helm_values) plus the tags of the images
  # built here. Setting the tags inside the module keeps the caller's
  # values independent of this module's outputs.
  application_values = merge(
    var.helm_values,
    local.image_tag == null ? {} : {
      image = merge(try(var.helm_values.image, {}), { tag = local.image_tag })
    },
    local.frontend_image_tag == null || try(var.frontend.values_key, "") != "frontend" ? {} : {
      frontend = merge(try(var.helm_values.frontend, {}), {
        image = merge(try(var.helm_values.frontend.image, {}), { tag = local.frontend_image_tag })
      })
    },
    local.frontend_image_tag == null || try(var.frontend.values_key, "") != "image" ? {} : {
      image = merge(try(var.helm_values.image, {}), { tag = local.frontend_image_tag })
    },
  )
}

# --- databases --------------------------------------------------------------

resource "random_password" "db" {
  count = var.database == null ? 0 : 1

  length  = 24
  special = false # URL-safe: no characters that need percent-encoding in a DSN
}

resource "random_password" "analytics_db" {
  count = var.analytics_database == null ? 0 : 1

  length  = 24
  special = false
}

locals {
  db_password           = one(random_password.db[*].result)
  analytics_db_password = one(random_password.analytics_db[*].result)

  database_url = var.database == null ? null : "postgres://${var.database.user}:${local.db_password}@${var.database.pooled_host}:${var.database.pooled_port}/${var.database.name}?sslmode=disable"

  migrations_database_url = var.database == null ? null : "postgres://${var.database.user}:${local.db_password}@${var.database.direct_host}:${var.database.direct_port}/${var.database.name}?sslmode=disable"

  analytics_database_url = var.analytics_database == null ? null : "postgres://${var.analytics_database.user}:${local.analytics_db_password}@${var.analytics_database.host}:${var.analytics_database.port}/${var.analytics_database.name}?sslmode=disable"
}

resource "kubernetes_secret" "db" {
  count = var.deploy && var.database != null ? 1 : 0

  metadata {
    name      = "${var.name}-db"
    namespace = var.apps_namespace
  }

  # DATABASE_URL goes through PgBouncer, which pools in transaction mode.
  # golang-migrate takes a session-scoped pg_advisory_lock at boot, which
  # transaction pooling cannot hold, so migrations get their own direct DSN
  # (docs/scalability/pgbouncer-connection-pooling.md).
  data = {
    DATABASE_URL            = local.database_url
    MIGRATIONS_DATABASE_URL = local.migrations_database_url
  }
}

resource "kubernetes_secret" "extra" {
  for_each = var.deploy ? var.secrets : {}

  metadata {
    name      = "${var.name}-${each.key}"
    namespace = var.apps_namespace
  }

  data = each.value
}

resource "kubernetes_secret" "analytics_db" {
  count = var.deploy && var.analytics_database != null ? 1 : 0

  metadata {
    name      = "${var.name}-analytics-db"
    namespace = var.apps_namespace
  }

  # The projector (writer) and the reports reader share the direct DSN: the
  # documented local baseline; a read-only reports role is the promotion path
  # (docs/analytics/governance-charter.md). Some charts read only the first
  # key, hence analytics_database.secret_keys.
  data = { for key in var.analytics_database.secret_keys : key => local.analytics_database_url }
}

# --- images -----------------------------------------------------------------

resource "null_resource" "build_and_load" {
  count = var.deploy && var.image != null ? 1 : 0

  triggers = {
    source_hash = local.source_hash
    image       = "warehouse/${var.name}:${local.image_tag}"
    cluster     = var.cluster_name
  }

  provisioner "local-exec" {
    command = "${var.scripts_dir}/build-and-load.sh '${var.name}' '${local.image_tag}' '${var.cluster_name}'"
  }
}

# Built whenever a frontend is declared, independent of var.deploy: the root
# only declares one while var.deploy_frontends is on, which is the switch the
# frontend builds have always followed. A Module Federation remote builds from
# web/; the console shell and the EventCatalog build from the repo root.
resource "null_resource" "build_and_load_frontend" {
  count = var.frontend == null ? 0 : 1

  triggers = {
    source_hash = var.frontend.source_hash
    image       = "warehouse/${var.name}-frontend:${local.frontend_image_tag}"
    cluster     = var.cluster_name
  }

  provisioner "local-exec" {
    command = "${var.scripts_dir}/build-and-load-frontend.sh '${var.name}' '${var.frontend.dir}' '${local.frontend_image_tag}' '${var.cluster_name}'"
  }
}

# --- delivery ---------------------------------------------------------------

resource "kubectl_manifest" "application" {
  count = var.deploy ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "argoproj.io/v1alpha1"
    kind       = "Application"
    metadata = {
      name      = var.name
      namespace = var.argocd_namespace
    }
    spec = {
      project = "default"
      sources = [
        {
          repoURL        = var.chart.repo_url
          targetRevision = var.chart.target_revision
          path           = var.chart.path
          helm = {
            valueFiles   = local.value_files
            valuesObject = local.application_values
          }
        },
        {
          repoURL        = var.values.repo_url
          targetRevision = var.values.target_revision
          ref            = "values"
        },
      ]
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

  # ArgoCD reads the value files from GitHub, so a missing one would only
  # surface as a failed sync. Fail the plan instead.
  lifecycle {
    precondition {
      condition = alltrue([
        for f in ["_platform.yaml", "${var.name}.yaml", "kind-resources/${var.name}.yaml"] :
        fileexists("${var.values.local_dir}/${f}")
      ])
      error_message = "${var.name}: every value file must exist in ${var.values.dir}/ (_platform.yaml, ${var.name}.yaml, kind-resources/${var.name}.yaml)."
    }
  }

  # The chart's pods mount these Secrets; create them first.
  depends_on = [
    kubernetes_secret.db,
    kubernetes_secret.analytics_db,
    kubernetes_secret.extra,
  ]
}
