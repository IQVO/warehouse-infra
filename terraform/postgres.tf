# ---------------------------------------------------------------------------
# PostgreSQL — ONE release, FOUR logical databases (one per bounded context).
#
# Chart: oci://registry-1.docker.io/bitnamicharts/postgresql
#
# Why the image is overridden to `bitnamilegacy`:
# Bitnami moved its versioned public images to "Bitnami Secure Images" in 2025.
# The tag this chart ships by default — bitnami/postgresql:17.5.0-debian-12-r3
# — no longer exists in the free catalogue (verified: `docker manifest inspect`
# returns not-found), while the newest charts default to an unpinned
# `bitnami/postgresql:latest`. The frozen, version-pinned images were moved to
# the `bitnamilegacy` Docker Hub org, which still publishes linux/amd64 and
# linux/arm64. Overriding the registry there is what keeps this stack both
# pinned and pullable. `allowInsecureImages` is the chart's own opt-out for its
# image-provenance check, which trips on any non-bitnami repository.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Per-service database passwords — GENERATED, never committed.
#
# Each bounded context's Postgres role gets a random password created at
# `terraform apply` time. The value lives ONLY in Terraform state (which is
# gitignored), never in a .tf file, so warehouse-infra can be a public repo
# without leaking credentials. Rotating a password is `terraform taint` +
# apply. Consumed by locals.service_passwords -> the initdb template and each
# service's DATABASE_URL Secret.
# ---------------------------------------------------------------------------
resource "random_password" "service_db" {
  for_each = local.services

  length  = 24
  special = false # keep it URL-safe: no chars needing percent-encoding in the DSN
}

# ---------------------------------------------------------------------------
# Per-service ANALYTICS database passwords — same generated-never-committed
# posture as service_db above, one extra role per service in
# local.analytics_services (see locals.tf's analytics_* locals). A single
# role per service for now (the chart's own reportsUrl-falls-back-to-
# projectorUrl default), not yet the separate read-only reports role the
# governance charter's promotion path describes.
# ---------------------------------------------------------------------------
resource "random_password" "service_analytics_db" {
  for_each = local.analytics_services

  length  = 24
  special = false
}

resource "helm_release" "postgresql" {
  depends_on = [kubernetes_namespace.data]

  name       = local.postgres_release_name
  repository = "oci://registry-1.docker.io/bitnamicharts"
  chart      = "postgresql"
  version    = var.postgresql_chart_version
  namespace  = var.data_namespace

  # A first boot has to run initdb, create four databases and four roles.
  timeout = 600
  wait    = true

  values = [yamlencode({
    global = {
      security = {
        allowInsecureImages = true
      }
    }

    image = {
      registry   = "docker.io"
      repository = "bitnamilegacy/postgresql"
      tag        = var.postgresql_image_tag
    }

    # Both of these are disabled by default; they are pinned to bitnamilegacy
    # anyway so that flipping either one on does not hit a dead image tag.
    volumePermissions = {
      image = {
        registry   = "docker.io"
        repository = "bitnamilegacy/os-shell"
        tag        = "12-debian-12-r43"
      }
    }
    metrics = {
      image = {
        registry   = "docker.io"
        repository = "bitnamilegacy/postgres-exporter"
        tag        = "0.17.1-debian-12-r7"
      }
    }

    auth = {
      # No auth.username/auth.database here: the four application databases are
      # created by the initdb script below, not by the chart's single-database
      # convenience path.
      postgresPassword = var.postgres_admin_password
    }

    primary = {
      persistence = {
        enabled = var.postgres_persistence_enabled
      }

      initdb = {
        scripts = {
          # The template needs each service's generated password to CREATE ROLE.
          # Merge the random_password result into each service object so no
          # credential is ever hardcoded in this repo.
          "00-init-databases.sql" = templatefile(
            "${path.module}/templates/init-databases.sql.tftpl",
            {
              services = {
                for name, svc in local.services :
                name => merge(svc, { password = local.service_passwords[name] })
              }
              analytics_services = {
                for name in local.analytics_services :
                name => merge(local.analytics_db_info[name], { password = local.analytics_service_passwords[name] })
              }
            }
          )
        }
      }

      resources = {
        requests = { cpu = "100m", memory = "256Mi" }
        limits   = { cpu = "1000m", memory = "1Gi" }
      }
    }
  })]
}
