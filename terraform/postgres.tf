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
# Database passwords are GENERATED, never committed: each application's OLTP
# and analytics passwords are random_passwords inside modules/application,
# which also writes the <name>-db and <name>-analytics-db Secrets the charts
# read (existingSecret). The initdb template below reads them through
# local.app_db_passwords and local.app_analytics_db_passwords
# (applications.tf). The values live ONLY in
# Terraform state (gitignored), so warehouse-infra can be a public repo.
# ---------------------------------------------------------------------------

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

      initdb = {
        scripts = {
          # The template needs each service's generated password to CREATE ROLE.
          # Merge the random_password result into each service object so no
          # credential is ever hardcoded in this repo.
          "00-init-databases.sql" = templatefile(
            "${path.module}/templates/init-databases.sql.tftpl",
            {
              # network-fulfillment is not in local.services (see
              # network-fulfillment.tf's header) but owns an OLTP database on
              # the same least-privilege terms, so it is merged in here rather
              # than given a second loop in the template.
              services = merge(
                {
                  for name, svc in local.services :
                  name => merge(svc, { password = local.service_passwords[name] })
                },
                {
                  # network-inventory-planning is not in local.services
                  # (see network-inventory-planning.tf's header) but owns
                  # an OLTP database on the same least-privilege terms,
                  # merged in exactly like network-fulfillment below.
                  "network-inventory-planning" = {
                    db       = local.network_inventory_planning_db_name
                    user     = local.network_inventory_planning_db_user
                    password = local.app_db_passwords["network-inventory-planning"]
                  }
                },
                {
                  "network-fulfillment" = {
                    db       = local.network_fulfillment_db_name
                    user     = local.network_fulfillment_db_user
                    password = local.app_db_passwords["network-fulfillment"]
                  }
                },
              )
              analytics_services = merge(
                {
                  for name in local.analytics_services :
                  name => merge(local.analytics_db_info[name], { password = local.app_analytics_db_passwords[name] })
                },
                {
                  # network-fulfillment is not in local.analytics_services
                  # (see network-fulfillment.tf's header -- it is not in
                  # local.services at all, and analytics_db_info's
                  # for-comprehension does local.services[name].db/.user,
                  # which would KeyError for a name not in local.services)
                  # but owns an analytics database on the same
                  # least-privilege terms as the eight above, so it is
                  # merged in here rather than given a second loop in the
                  # template -- exactly the same pattern the `services` map
                  # two blocks above already uses for this same context's
                  # OLTP database.
                  "network-fulfillment" = {
                    db       = local.network_fulfillment_analytics_db_name
                    user     = local.network_fulfillment_analytics_db_user
                    password = local.app_analytics_db_passwords["network-fulfillment"]
                  }
                },
                {
                  # network-inventory-planning: same reasoning as
                  # network-fulfillment above (not in local.services, so not
                  # in analytics_db_info); see network-inventory-planning.tf.
                  "network-inventory-planning" = {
                    db       = local.network_inventory_planning_analytics_db_name
                    user     = local.network_inventory_planning_analytics_db_user
                    password = local.app_analytics_db_passwords["network-inventory-planning"]
                  }
                },
              )
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
