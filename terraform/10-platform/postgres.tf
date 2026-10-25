# ---------------------------------------------------------------------------
# PostgreSQL — ONE release. It knows no application: each application's role
# and database are provisioned by modules/application (ADR 0005).
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
# Database passwords are GENERATED, never committed: each application's OLTP
# and analytics passwords are random_passwords inside modules/application,
# which writes the <name>-db and <name>-analytics-db Secrets the charts read
# (existingSecret) and sets the same password on the role through a
# provisioning Job (modules/database). Nothing here reads them. The values
# live ONLY in Terraform state (gitignored), so warehouse-infra can be a
# public repo.
# ---------------------------------------------------------------------------

resource "helm_release" "postgresql" {
  depends_on = [kubernetes_namespace.data]

  name       = local.postgres_release_name
  repository = "oci://registry-1.docker.io/bitnamicharts"
  chart      = "postgresql"
  version    = var.postgresql_chart_version
  namespace  = var.data_namespace

  # A first boot has to run initdb on an empty volume.
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
      # No auth.username/auth.database here, and no initdb scripts: the
      # application roles and databases are provisioned by Jobs (ADR 0005), so
      # adding an application never touches this release.
      postgresPassword = var.postgres_admin_password
    }

    primary = {
      # Raise Postgres' own max_connections above the pooled server-side
      # worst case (see pgbouncer.tf's budget comment: 14 OLTP databases
      # x pool_size 12 = 168 > the chart's stock max_connections=100).
      # 250 restores real headroom; at this fleet's actual load (24/100
      # observed 2026-10-17) the extra slots stay idle and cost only
      # memory on the 35GiB kind node.
      extendedConfiguration = "max_connections = 250"

      persistence = {
        enabled = var.postgres_persistence_enabled
        # The chart's own default is 8Gi, sized for a real deployment. 3Gi is
        # plenty for four small logical databases on a laptop kind cluster
        # (each holds a handful of MB of demo/e2e data) and keeps the PVC
        # request small on a host that likely has other kind clusters and
        # Docker volumes competing for disk. Bump this if you seed
        # significantly more data than the README's examples produce.
        size = "3Gi"
      }

      resources = {
        requests = { cpu = "100m", memory = "256Mi" }
        limits   = { cpu = "1000m", memory = "1Gi" }
      }
    }
  })]
}

# What the applications need to reach this Postgres, published as one object
# (the contract ADR 0005 names): where it listens, which Secret holds the
# superuser password, and the image whose psql runs the provisioning scripts.
# Referencing the release makes every consumer wait for it.
locals {
  postgres = {
    host              = local.postgres_host
    port              = local.postgres_port
    namespace         = helm_release.postgresql.namespace
    admin_secret_name = "${helm_release.postgresql.name}-postgresql"
    admin_secret_key  = "postgres-password"
    image             = "bitnamilegacy/postgresql:${var.postgresql_image_tag}"
  }
}
