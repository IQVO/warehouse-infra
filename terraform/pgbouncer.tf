# ---------------------------------------------------------------------------
# PgBouncer — transaction-pooling connection pooler in front of the single
# shared Postgres instance (postgres.tf). See
# docs/scalability/pgbouncer-connection-pooling.md for the full design
# record (why this is needed, why transaction-pooling mode, the session-
# level-feature audit, the connection-budget math).
#
# Context in one paragraph: postgres.tf runs ONE Postgres release with the
# Bitnami chart's unmodified `max_connections=100` default, shared by every
# one of this fleet's 10 backend services (each with its own logical
# database/role on that SAME server, see locals.tf's `local.services` +
# network-fulfillment.tf). order-management's ADR-0026 (Phase 3 scalability)
# found that ONE service alone, at its own HPA ceiling, could reach ~80/100
# connections -- rolling the same pgxpool.MaxConns pattern to the other 9
# services would blow the shared ceiling long before any of them reaches
# their own HPA maximum. PgBouncer sits between every service's pgxpool and
# the real Postgres server so the CLIENT side (pgxpool.MaxConns, sized
# generously per service) and the SERVER side (real Postgres connections,
# bounded low and fixed regardless of replica/HPA fan-out) become
# independent numbers.
#
# No Helm chart is used here, deliberately: `oci://registry-1.docker.io/
# bitnamicharts/pgbouncer` returns 401 Unauthorized (verified directly --
# Bitnami's free OCI chart catalog does not include pgbouncer, unlike
# postgresql/kafka which remain free). The `bitnamilegacy/pgbouncer` image
# itself IS still pullable (same override pattern postgres.tf/kafka.tf
# already use for their own images), so this file hand-rolls the
# Deployment/Service/Secret directly in Terraform -- the exact same pattern
# frontends.tf's `kubernetes_deployment.web_gateway` already uses in this
# repo for the Nginx web gateway, a component with no Helm chart of its own
# either. This is "integrates cleanly with the existing Bitnami-chart-heavy
# style" in the sense that matters here: same image vendor/registry
# override pattern, same repo convention for a chart-less platform
# component, not a forced Helm install against a chart that does not exist.
# ---------------------------------------------------------------------------

locals {
  pgbouncer_release_name = "pgbouncer"
  pgbouncer_port         = 6432
  pgbouncer_host         = "${local.pgbouncer_release_name}.${var.data_namespace}.svc.cluster.local"

  # PgBouncer's own admin console user (SHOW POOLS/SHOW SERVERS/SHOW STATS
  # against its built-in `pgbouncer` pseudo-database) doubles as the
  # Postgres superuser already generated in postgres.tf -- no new
  # credential to manage, and it is never used for anything beyond the
  # admin console + the entrypoint's own backend-reachability check.
  pgbouncer_admin_user = "postgres"

  # Conservative per-database REAL Postgres connection ceiling. Sized well
  # under max_connections=100 in aggregate even with every OLTP database
  # active at once: 9 databases (the 8 in local.services plus
  # network-fulfillment) * 12 = 108 in the absolute worst case of every
  # pool simultaneously saturated, which the ADR's "not every service is
  # ever at 100% at the same instant" real-world accounting treats as an
  # acceptable soft ceiling for a laptop cluster -- see the design doc for
  # the full per-database budget table and why 12 (not 15) was chosen as
  # the conservative end of the requested 10-15 range.
  pgbouncer_oltp_pool_size = 12

  # Every OLTP database that should be reached THROUGH PgBouncer rather
  # than directly against Postgres: the 8 services in local.services plus
  # network-fulfillment (not in local.services -- see that file's header --
  # but sharing the same Postgres instance on the same least-privilege
  # terms). Analytics databases are deliberately EXCLUDED from this map and
  # stay wired directly at Postgres (local.analytics_database_urls,
  # postgres.tf/network-fulfillment.tf unchanged) -- see the design doc's
  # "why analytics stays direct" section.
  pgbouncer_oltp_services = merge(
    {
      for name, svc in local.services :
      name => merge(svc, { password = local.service_passwords[name] })
    },
    {
      "network-fulfillment" = {
        db       = local.network_fulfillment_db_name
        user     = local.network_fulfillment_db_user
        password = random_password.network_fulfillment_db.result
      }
    },
  )

  pgbouncer_config = templatefile(
    "${path.module}/templates/pgbouncer.ini.tftpl",
    {
      services       = local.pgbouncer_oltp_services
      postgres_host  = local.postgres_host
      postgres_port  = local.postgres_port
      pgbouncer_port = local.pgbouncer_port
      oltp_pool_size = local.pgbouncer_oltp_pool_size
      admin_user     = local.pgbouncer_admin_user
    }
  )

  pgbouncer_userlist = templatefile(
    "${path.module}/templates/pgbouncer-userlist.txt.tftpl",
    {
      services       = local.pgbouncer_oltp_services
      admin_user     = local.pgbouncer_admin_user
      admin_password = var.postgres_admin_password
    }
  )
}

# Holds both rendered config files as Secret keys (not a ConfigMap: the
# userlist.txt key carries every OLTP role's real plaintext password --
# same "never a plaintext DSN/credential in a non-Secret object" posture
# postgres.tf's own header explains for kubernetes_secret.service_db).
# Mounted as a whole directory at PgBouncer's MOUNTED_CONF_DIR
# (/bitnami/pgbouncer/conf) -- the Bitnami entrypoint's own
# pgbouncer_copy_mounted_config step copies both files into its real config
# dir, and its "is this file mounted externally" check (which gates
# whether it silently overwrites userlist.txt/pgbouncer.ini with its own
# generated defaults) inspects that same mount point, keyed by filename,
# not content -- so both files being present there is what makes it skip
# its own auto-generation for both.
resource "kubernetes_secret" "pgbouncer_config" {
  metadata {
    name      = "${local.pgbouncer_release_name}-config"
    namespace = var.data_namespace
  }

  data = {
    "pgbouncer.ini" = local.pgbouncer_config
    "userlist.txt"  = local.pgbouncer_userlist
  }

  depends_on = [kubernetes_namespace.data]
}

resource "kubernetes_deployment" "pgbouncer" {
  depends_on = [
    kubernetes_secret.pgbouncer_config,
    helm_release.postgresql,
  ]

  metadata {
    name      = local.pgbouncer_release_name
    namespace = var.data_namespace
    labels = {
      "app.kubernetes.io/name"      = local.pgbouncer_release_name
      "app.kubernetes.io/component" = "connection-pooler"
      "warehouse.local/tier"        = "data"
    }
  }

  spec {
    replicas = 1

    selector {
      match_labels = {
        "app.kubernetes.io/name" = local.pgbouncer_release_name
      }
    }

    template {
      metadata {
        labels = {
          "app.kubernetes.io/name"      = local.pgbouncer_release_name
          "app.kubernetes.io/component" = "connection-pooler"
        }
        annotations = {
          # Roll the pod whenever the rendered config or userlist changes
          # (a new service added to local.services, a rotated password) --
          # the Secret is mounted as a real volume (not subPath), so
          # kubelet DOES propagate a content change to the running
          # container, but PgBouncer itself does not re-read pgbouncer.ini
          # on its own; a pod roll is what actually picks up the change.
          "checksum/config" = sha256("${local.pgbouncer_config}${local.pgbouncer_userlist}")
        }
      }

      spec {
        security_context {
          run_as_non_root = true
          run_as_user     = 1001
        }

        container {
          name  = "pgbouncer"
          image = "bitnamilegacy/pgbouncer:${var.pgbouncer_image_tag}"

          port {
            name           = "pgbouncer"
            container_port = local.pgbouncer_port
            protocol       = "TCP"
          }

          env {
            name  = "PGBOUNCER_PORT"
            value = tostring(local.pgbouncer_port)
          }

          # These four are NOT what the real per-database backend
          # connections use (pgbouncer.ini's own [databases] section,
          # mounted below, has its own per-database host=/dbname= entries
          # for that) -- they exist only so the Bitnami entrypoint's
          # startup validation (pgbouncer_validate) and its
          # wait-for-postgres-backend retry loop
          # (PGBOUNCER_INIT_MAX_RETRIES x PGBOUNCER_INIT_SLEEP_TIME) have
          # something real to check before starting pgbouncer, giving a
          # genuine "is Postgres actually up yet" gate at container start
          # instead of pgbouncer starting immediately and failing on its
          # first real client transaction.
          env {
            name  = "POSTGRESQL_HOST"
            value = local.postgres_host
          }

          env {
            name  = "POSTGRESQL_PORT"
            value = tostring(local.postgres_port)
          }

          env {
            name  = "POSTGRESQL_USERNAME"
            value = local.pgbouncer_admin_user
          }

          env {
            name = "POSTGRESQL_PASSWORD"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.pgbouncer_admin_password.metadata[0].name
                key  = "POSTGRESQL_PASSWORD"
              }
            }
          }

          volume_mount {
            name       = "config"
            mount_path = "/bitnami/pgbouncer/conf"
            read_only  = true
          }

          volume_mount {
            name       = "logs"
            mount_path = "/opt/bitnami/pgbouncer/logs"
          }

          volume_mount {
            name       = "tmp"
            mount_path = "/opt/bitnami/pgbouncer/tmp"
          }

          # Discriminating readiness/liveness/startup checks: all three
          # query PgBouncer's own admin console (SHOW POOLS against its
          # built-in `pgbouncer` pseudo-database), not a bare TCP port-open
          # check -- a port can accept a TCP connection well before
          # PgBouncer has finished parsing its mounted config and userlist,
          # and a bare `nc`/socket probe would report ready during that
          # window. SHOW POOLS only answers once the admin console is
          # genuinely serving, which requires config+auth to have loaded
          # successfully.
          startup_probe {
            exec {
              command = ["sh", "-c", "PGPASSWORD=$POSTGRESQL_PASSWORD psql -h 127.0.0.1 -p ${local.pgbouncer_port} -U ${local.pgbouncer_admin_user} -d pgbouncer -tAc 'SHOW POOLS;' >/dev/null"]
            }
            initial_delay_seconds = 5
            period_seconds        = 10
            failure_threshold     = 18 # up to 180s: covers the entrypoint's own PGBOUNCER_INIT_MAX_RETRIES(10) x PGBOUNCER_INIT_SLEEP_TIME(10s) backend-wait loop
          }

          readiness_probe {
            exec {
              command = ["sh", "-c", "PGPASSWORD=$POSTGRESQL_PASSWORD psql -h 127.0.0.1 -p ${local.pgbouncer_port} -U ${local.pgbouncer_admin_user} -d pgbouncer -tAc 'SHOW POOLS;' >/dev/null"]
            }
            period_seconds    = 10
            failure_threshold = 3
          }

          liveness_probe {
            exec {
              command = ["sh", "-c", "PGPASSWORD=$POSTGRESQL_PASSWORD psql -h 127.0.0.1 -p ${local.pgbouncer_port} -U ${local.pgbouncer_admin_user} -d pgbouncer -tAc 'SHOW POOLS;' >/dev/null"]
            }
            period_seconds    = 15
            failure_threshold = 6 # loose on purpose -- do not restart on one transient Postgres blip, same fleet convention every service chart's own livenessProbe already uses
          }

          resources {
            requests = { cpu = "100m", memory = "64Mi" }
            limits   = { cpu = "500m", memory = "256Mi" }
          }
        }

        volume {
          name = "config"
          secret {
            secret_name = kubernetes_secret.pgbouncer_config.metadata[0].name
          }
        }

        volume {
          name = "logs"
          empty_dir {}
        }

        volume {
          name = "tmp"
          empty_dir {}
        }
      }
    }
  }
}

# Kept as its own Secret (rather than folded into pgbouncer_config above)
# because it holds the Postgres SUPERUSER password used only for the
# entrypoint's backend-reachability check -- keeping it separate from the
# per-service userlist.txt/pgbouncer.ini Secret means a future rotation of
# one does not require re-rendering the other.
resource "kubernetes_secret" "pgbouncer_admin_password" {
  metadata {
    name      = "${local.pgbouncer_release_name}-admin"
    namespace = var.data_namespace
  }

  data = {
    POSTGRESQL_PASSWORD = var.postgres_admin_password
  }

  depends_on = [kubernetes_namespace.data]
}

resource "kubernetes_service" "pgbouncer" {
  depends_on = [kubernetes_deployment.pgbouncer]

  metadata {
    name      = local.pgbouncer_release_name
    namespace = var.data_namespace
    labels = {
      "app.kubernetes.io/name" = local.pgbouncer_release_name
      "warehouse.local/tier"   = "data"
    }
  }

  spec {
    type = "ClusterIP"
    selector = {
      "app.kubernetes.io/name" = local.pgbouncer_release_name
    }
    port {
      name        = "pgbouncer"
      port        = local.pgbouncer_port
      target_port = "pgbouncer"
      protocol    = "TCP"
    }
  }
}

output "pgbouncer_host" {
  description = "In-cluster DNS name:port of PgBouncer. Every OLTP DATABASE_URL Secret (local.database_urls) points here instead of directly at Postgres; analytics DSNs stay direct (see the design doc)."
  value       = "${local.pgbouncer_host}:${local.pgbouncer_port}"
}
