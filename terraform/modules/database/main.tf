# Creates one PostgreSQL role, and optionally the database it owns, with a
# Kubernetes Job that runs psql inside the cluster (ADR 0005).
#
# Why a Job: it needs no host-reachable Postgres port, no provider that
# connects during plan, and no cluster change. Terraform waits for the Job, so
# whatever depends on this module sees the role and the database in place.
#
# Idempotent by construction: provision.sql creates what is missing and
# converges what exists. A Job runs once, so the Job is replaced whenever its
# input Secret (the password, the SQL) changes, which re-runs the script with
# the new values. Removing the module leaves the role and the database alone
# on purpose: data is never dropped by a plan.

locals {
  # The SQL travels in a Secret volume, never in the container's command or
  # env: the kubelet expands $(VAR) and turns $$ into $ in both, which breaks
  # dollar-quoted function bodies.
  sql = join("\n", compact([file("${path.module}/provision.sql"), var.extra_sql]))
}

resource "kubernetes_secret" "password" {
  metadata {
    name      = "${var.name}-provision"
    namespace = var.postgres.namespace
  }

  # Both keys are inputs of one provisioning run: the password is secret, the
  # SQL is not, and one object keeps the pair together.
  data = {
    password        = var.password
    "provision.sql" = local.sql
  }
}

resource "kubernetes_job_v1" "provision" {
  metadata {
    name      = "provision-${var.name}"
    namespace = var.postgres.namespace
    labels = {
      "app.kubernetes.io/name"      = "provision-${var.name}"
      "app.kubernetes.io/component" = "database-provisioning"
      "warehouse.local/tier"        = "data"
    }
  }

  spec {
    backoff_limit = 6

    template {
      metadata {
        labels = {
          "app.kubernetes.io/name"      = "provision-${var.name}"
          "app.kubernetes.io/component" = "database-provisioning"
        }
      }

      spec {
        restart_policy = "OnFailure"

        security_context {
          run_as_non_root = true
          run_as_user     = 1001
        }

        container {
          name    = "psql"
          image   = var.postgres.image
          command = ["psql", "-X", "-f", "/provision/provision.sql"]

          env {
            name  = "PGHOST"
            value = var.postgres.host
          }
          env {
            name  = "PGPORT"
            value = tostring(var.postgres.port)
          }
          env {
            name  = "PGUSER"
            value = "postgres"
          }
          env {
            name  = "PGDATABASE"
            value = "postgres"
          }
          env {
            name = "PGPASSWORD"
            value_from {
              secret_key_ref {
                name = var.postgres.admin_secret_name
                key  = var.postgres.admin_secret_key
              }
            }
          }
          env {
            name  = "DB_ROLE"
            value = var.role
          }
          env {
            name  = "DB_NAME"
            value = (var.database == null ? "" : var.database)
          }
          env {
            name = "DB_PASSWORD"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.password.metadata[0].name
                key  = "password"
              }
            }
          }

          volume_mount {
            name       = "provision"
            mount_path = "/provision"
            read_only  = true
          }

          resources {
            requests = { cpu = "10m", memory = "32Mi" }
            limits   = { cpu = "200m", memory = "128Mi" }
          }
        }

        volume {
          name = "provision"
          secret {
            secret_name = kubernetes_secret.password.metadata[0].name
          }
        }
      }
    }
  }

  wait_for_completion = true

  lifecycle {
    replace_triggered_by = [kubernetes_secret.password]
  }

  timeouts {
    create = "5m"
    update = "5m"
  }
}
