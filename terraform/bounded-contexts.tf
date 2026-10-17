# ---------------------------------------------------------------------------
# Applications registered through modules/bounded-context (ADR 0002, phase 1
# pilot: docs/adr/0002-application-delivery-boundary.md).
#
# Two deliberately different shapes prove the module before the rest of the
# fleet moves (phase 2):
#   - order-management, an entry of local.services: it stays in that map
#     (its values, MCP, analytics and frontend wiring still derive from it);
#     only its platform-contract resources moved here, so the for_each
#     resources in postgres.tf, services.tf, frontends.tf and argocd-apps.tf
#     skip every name in local.bounded_context_names.
#   - network-inventory-planning, which was hand-copied in its own file.
#
# The moved blocks at the bottom map every pre-module address onto the
# module, so applying this change only rewrites state addresses: no password
# is regenerated, no Secret, image or Application is replaced.
# ---------------------------------------------------------------------------

locals {
  bounded_contexts = {
    "order-management" = {
      chart = {
        repo_url = "https://github.com/${lookup(local.argocd_repo_owner, "order-management", "claudioed")}/order-management.git"
        path     = "charts/order-management"
      }
      image    = {}
      frontend = contains(keys(local.frontend_remotes), "order-management") ? { source_hash = local.frontend_source_hash["order-management"] } : null
      database = {
        name        = local.services["order-management"].db
        user        = local.services["order-management"].user
        pooled_host = local.pgbouncer_host
        pooled_port = local.pgbouncer_port
        direct_host = local.postgres_host
        direct_port = local.postgres_port
      }
      # Its chart still takes the analytics DSN as a value
      # (analytics.database.projectorUrl, set by services.tf), so the analytics
      # password stays in postgres.tf until ADR 0002 phase 3 moves the DSN
      # into a Secret.
      analytics_database = null
    }

    "network-inventory-planning" = {
      chart = {
        repo_url = "https://github.com/IQVO/network-inventory-planning.git"
        path     = "charts/network-inventory-planning"
      }
      # Exactly the globs network-inventory-planning.tf hashed before the
      # module. NOTE: the repo also keeps analytics/migrations/, which this
      # list does not hash, so an analytics-migration-only change does not
      # rebuild the image. Kept as-is here so this refactor changes nothing;
      # the module default (which hashes it) replaces this list in phase 2.
      image = {
        hash_globs = ["**/*.go", "internal/**/migrations/**"]
      }
      frontend = contains(keys(local.frontend_remotes), "network-inventory-planning") ? { source_hash = local.frontend_source_hash["network-inventory-planning"] } : null
      database = {
        name        = local.network_inventory_planning_db_name
        user        = local.network_inventory_planning_db_user
        pooled_host = local.pgbouncer_host
        pooled_port = local.pgbouncer_port
        direct_host = local.postgres_host
        direct_port = local.postgres_port
      }
      analytics_database = {
        name = local.network_inventory_planning_analytics_db_name
        user = local.network_inventory_planning_analytics_db_user
        host = local.postgres_host
        port = local.postgres_port
      }
    }
  }

  bounded_context_names = toset(keys(local.bounded_contexts))

  # The chart values, still computed by the root (ADR 0002 phase 3 moves them
  # to value files). Without image tags: the module adds the tags of the
  # images it builds, so these values never depend on the module's outputs.
  bounded_context_helm_values = {
    "order-management"           = local.argocd_service_values["order-management"]
    "network-inventory-planning" = local.argocd_network_inventory_planning_values
  }
}

module "bounded_context" {
  source   = "./modules/bounded-context"
  for_each = local.bounded_context_names

  name   = each.key
  deploy = var.deploy_services

  # Resource attributes rather than variables: they carry the ordering the
  # pre-module resources declared with depends_on (namespace before Secrets,
  # ArgoCD before Applications, cluster before image loads).
  apps_namespace   = kubernetes_namespace.apps.metadata[0].name
  argocd_namespace = helm_release.argocd.namespace
  cluster_name     = kind_cluster.warehouse.name

  repos_root  = "${path.module}/../.."
  scripts_dir = "${path.module}/../scripts"

  chart              = local.bounded_contexts[each.key].chart
  image              = local.bounded_contexts[each.key].image
  frontend           = local.bounded_contexts[each.key].frontend
  database           = local.bounded_contexts[each.key].database
  analytics_database = local.bounded_contexts[each.key].analytics_database
  helm_values        = local.bounded_context_helm_values[each.key]
}

# --- state moves (ADR 0002, decision D3) ------------------------------------

moved {
  from = random_password.service_db["order-management"]
  to   = module.bounded_context["order-management"].random_password.db[0]
}

moved {
  from = kubernetes_secret.service_db["order-management"]
  to   = module.bounded_context["order-management"].kubernetes_secret.db[0]
}

moved {
  from = null_resource.build_and_load["order-management"]
  to   = module.bounded_context["order-management"].null_resource.build_and_load[0]
}

moved {
  from = null_resource.build_and_load_frontend["order-management"]
  to   = module.bounded_context["order-management"].null_resource.build_and_load_frontend[0]
}

moved {
  from = kubectl_manifest.application["order-management"]
  to   = module.bounded_context["order-management"].kubectl_manifest.application[0]
}

moved {
  from = random_password.network_inventory_planning_db
  to   = module.bounded_context["network-inventory-planning"].random_password.db[0]
}

moved {
  from = random_password.network_inventory_planning_analytics_db
  to   = module.bounded_context["network-inventory-planning"].random_password.analytics_db[0]
}

moved {
  from = kubernetes_secret.network_inventory_planning_db[0]
  to   = module.bounded_context["network-inventory-planning"].kubernetes_secret.db[0]
}

moved {
  from = kubernetes_secret.network_inventory_planning_analytics_db[0]
  to   = module.bounded_context["network-inventory-planning"].kubernetes_secret.analytics_db[0]
}

moved {
  from = null_resource.build_and_load_network_inventory_planning[0]
  to   = module.bounded_context["network-inventory-planning"].null_resource.build_and_load[0]
}

moved {
  from = null_resource.build_and_load_frontend["network-inventory-planning"]
  to   = module.bounded_context["network-inventory-planning"].null_resource.build_and_load_frontend[0]
}

moved {
  from = kubectl_manifest.network_inventory_planning_application[0]
  to   = module.bounded_context["network-inventory-planning"].kubectl_manifest.application[0]
}
