# ---------------------------------------------------------------------------
# State moves onto modules/application (ADR 0002 decision D3, ADR 0004).
# Each block maps a pre-module address onto the module, so applying them
# only rewrites state addresses: no password is regenerated, no Secret, image
# or ArgoCD Application is replaced. A block whose `from` address is not in the state
# does nothing, so they are safe on a fresh cluster too.
#
# The phase 1 blocks keep the addresses that were recorded
# (module.bounded_context, the module's name before ADR 0004) and reach
# module.application through the rename block below: Terraform follows
# chained moves.
#
# Keep them until every state that predates them has been applied once; then
# they can go (https://developer.hashicorp.com/terraform/language/modules/develop/refactoring).
# ---------------------------------------------------------------------------

# --- phase 1 pilot (#98; recorded on the kind cluster's state 2026-10-17) ---
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

# --- ADR 0004: modules/bounded-context renamed to modules/application ---
moved {
  from = module.bounded_context
  to   = module.application
}

# --- phase 2: the rest of the fleet (ADR 0004) ---
moved {
  from = random_password.service_db["inventory-storage"]
  to   = module.application["inventory-storage"].random_password.db[0]
}

moved {
  from = kubernetes_secret.service_db["inventory-storage"]
  to   = module.application["inventory-storage"].kubernetes_secret.db[0]
}

moved {
  from = null_resource.build_and_load["inventory-storage"]
  to   = module.application["inventory-storage"].null_resource.build_and_load[0]
}

moved {
  from = null_resource.build_and_load_frontend["inventory-storage"]
  to   = module.application["inventory-storage"].null_resource.build_and_load_frontend[0]
}

moved {
  from = kubectl_manifest.application["inventory-storage"]
  to   = module.application["inventory-storage"].kubectl_manifest.application[0]
}

moved {
  from = random_password.service_db["wes-work-planning"]
  to   = module.application["wes-work-planning"].random_password.db[0]
}

moved {
  from = kubernetes_secret.service_db["wes-work-planning"]
  to   = module.application["wes-work-planning"].kubernetes_secret.db[0]
}

moved {
  from = null_resource.build_and_load["wes-work-planning"]
  to   = module.application["wes-work-planning"].null_resource.build_and_load[0]
}

moved {
  from = null_resource.build_and_load_frontend["wes-work-planning"]
  to   = module.application["wes-work-planning"].null_resource.build_and_load_frontend[0]
}

moved {
  from = kubectl_manifest.application["wes-work-planning"]
  to   = module.application["wes-work-planning"].kubectl_manifest.application[0]
}

moved {
  from = random_password.service_db["workforce-management"]
  to   = module.application["workforce-management"].random_password.db[0]
}

moved {
  from = kubernetes_secret.service_db["workforce-management"]
  to   = module.application["workforce-management"].kubernetes_secret.db[0]
}

moved {
  from = null_resource.build_and_load["workforce-management"]
  to   = module.application["workforce-management"].null_resource.build_and_load[0]
}

moved {
  from = null_resource.build_and_load_frontend["workforce-management"]
  to   = module.application["workforce-management"].null_resource.build_and_load_frontend[0]
}

moved {
  from = kubectl_manifest.application["workforce-management"]
  to   = module.application["workforce-management"].kubectl_manifest.application[0]
}

moved {
  from = random_password.service_db["fulfillment-execution"]
  to   = module.application["fulfillment-execution"].random_password.db[0]
}

moved {
  from = kubernetes_secret.service_db["fulfillment-execution"]
  to   = module.application["fulfillment-execution"].kubernetes_secret.db[0]
}

moved {
  from = null_resource.build_and_load["fulfillment-execution"]
  to   = module.application["fulfillment-execution"].null_resource.build_and_load[0]
}

moved {
  from = null_resource.build_and_load_frontend["fulfillment-execution"]
  to   = module.application["fulfillment-execution"].null_resource.build_and_load_frontend[0]
}

moved {
  from = kubectl_manifest.application["fulfillment-execution"]
  to   = module.application["fulfillment-execution"].kubectl_manifest.application[0]
}

moved {
  from = random_password.service_db["facility-layout"]
  to   = module.application["facility-layout"].random_password.db[0]
}

moved {
  from = kubernetes_secret.service_db["facility-layout"]
  to   = module.application["facility-layout"].kubernetes_secret.db[0]
}

moved {
  from = null_resource.build_and_load["facility-layout"]
  to   = module.application["facility-layout"].null_resource.build_and_load[0]
}

moved {
  from = null_resource.build_and_load_frontend["facility-layout"]
  to   = module.application["facility-layout"].null_resource.build_and_load_frontend[0]
}

moved {
  from = kubectl_manifest.application["facility-layout"]
  to   = module.application["facility-layout"].kubectl_manifest.application[0]
}

moved {
  from = random_password.service_db["labor-performance"]
  to   = module.application["labor-performance"].random_password.db[0]
}

moved {
  from = kubernetes_secret.service_db["labor-performance"]
  to   = module.application["labor-performance"].kubernetes_secret.db[0]
}

moved {
  from = null_resource.build_and_load["labor-performance"]
  to   = module.application["labor-performance"].null_resource.build_and_load[0]
}

moved {
  from = null_resource.build_and_load_frontend["labor-performance"]
  to   = module.application["labor-performance"].null_resource.build_and_load_frontend[0]
}

moved {
  from = kubectl_manifest.application["labor-performance"]
  to   = module.application["labor-performance"].kubectl_manifest.application[0]
}

moved {
  from = random_password.service_db["process-path-management"]
  to   = module.application["process-path-management"].random_password.db[0]
}

moved {
  from = kubernetes_secret.service_db["process-path-management"]
  to   = module.application["process-path-management"].kubernetes_secret.db[0]
}

moved {
  from = null_resource.build_and_load["process-path-management"]
  to   = module.application["process-path-management"].null_resource.build_and_load[0]
}

moved {
  from = null_resource.build_and_load_frontend["process-path-management"]
  to   = module.application["process-path-management"].null_resource.build_and_load_frontend[0]
}

moved {
  from = kubectl_manifest.application["process-path-management"]
  to   = module.application["process-path-management"].kubectl_manifest.application[0]
}

moved {
  from = random_password.service_db["warehouse-planning"]
  to   = module.application["warehouse-planning"].random_password.db[0]
}

moved {
  from = kubernetes_secret.service_db["warehouse-planning"]
  to   = module.application["warehouse-planning"].kubernetes_secret.db[0]
}

moved {
  from = null_resource.build_and_load["warehouse-planning"]
  to   = module.application["warehouse-planning"].null_resource.build_and_load[0]
}

moved {
  from = null_resource.build_and_load_frontend["warehouse-planning"]
  to   = module.application["warehouse-planning"].null_resource.build_and_load_frontend[0]
}

moved {
  from = kubectl_manifest.application["warehouse-planning"]
  to   = module.application["warehouse-planning"].kubectl_manifest.application[0]
}

moved {
  from = random_password.service_db["product-master"]
  to   = module.application["product-master"].random_password.db[0]
}

moved {
  from = kubernetes_secret.service_db["product-master"]
  to   = module.application["product-master"].kubernetes_secret.db[0]
}

moved {
  from = null_resource.build_and_load["product-master"]
  to   = module.application["product-master"].null_resource.build_and_load[0]
}

moved {
  from = null_resource.build_and_load_frontend["product-master"]
  to   = module.application["product-master"].null_resource.build_and_load_frontend[0]
}

moved {
  from = kubectl_manifest.application["product-master"]
  to   = module.application["product-master"].kubectl_manifest.application[0]
}

moved {
  from = random_password.service_db["inbound-receiving"]
  to   = module.application["inbound-receiving"].random_password.db[0]
}

moved {
  from = kubernetes_secret.service_db["inbound-receiving"]
  to   = module.application["inbound-receiving"].kubernetes_secret.db[0]
}

moved {
  from = null_resource.build_and_load["inbound-receiving"]
  to   = module.application["inbound-receiving"].null_resource.build_and_load[0]
}

moved {
  from = null_resource.build_and_load_frontend["inbound-receiving"]
  to   = module.application["inbound-receiving"].null_resource.build_and_load_frontend[0]
}

moved {
  from = kubectl_manifest.application["inbound-receiving"]
  to   = module.application["inbound-receiving"].kubectl_manifest.application[0]
}

moved {
  from = random_password.service_db["slotting-optimization"]
  to   = module.application["slotting-optimization"].random_password.db[0]
}

moved {
  from = kubernetes_secret.service_db["slotting-optimization"]
  to   = module.application["slotting-optimization"].kubernetes_secret.db[0]
}

moved {
  from = null_resource.build_and_load["slotting-optimization"]
  to   = module.application["slotting-optimization"].null_resource.build_and_load[0]
}

moved {
  from = kubectl_manifest.application["slotting-optimization"]
  to   = module.application["slotting-optimization"].kubectl_manifest.application[0]
}

moved {
  from = random_password.network_fulfillment_db
  to   = module.application["network-fulfillment"].random_password.db[0]
}

moved {
  from = random_password.network_fulfillment_analytics_db
  to   = module.application["network-fulfillment"].random_password.analytics_db[0]
}

moved {
  from = kubernetes_secret.network_fulfillment_db[0]
  to   = module.application["network-fulfillment"].kubernetes_secret.db[0]
}

moved {
  from = kubernetes_secret.network_fulfillment_analytics_db[0]
  to   = module.application["network-fulfillment"].kubernetes_secret.analytics_db[0]
}

moved {
  from = null_resource.build_and_load_network_fulfillment[0]
  to   = module.application["network-fulfillment"].null_resource.build_and_load[0]
}

moved {
  from = null_resource.build_and_load_frontend["network-fulfillment"]
  to   = module.application["network-fulfillment"].null_resource.build_and_load_frontend[0]
}

moved {
  from = kubectl_manifest.network_fulfillment_application[0]
  to   = module.application["network-fulfillment"].kubectl_manifest.application[0]
}

moved {
  from = kubernetes_secret.ops_agent_anthropic[0]
  to   = module.application["warehouse-ops-agent"].kubernetes_secret.extra["anthropic"]
}

moved {
  from = kubectl_manifest.ops_agent_application[0]
  to   = module.application["warehouse-ops-agent"].kubectl_manifest.application[0]
}

moved {
  from = null_resource.build_and_load_console[0]
  to   = module.application["warehouse-console"].null_resource.build_and_load_frontend[0]
}

moved {
  from = kubectl_manifest.console_application[0]
  to   = module.application["warehouse-console"].kubectl_manifest.application[0]
}

moved {
  from = null_resource.build_and_load_ecosystem[0]
  to   = module.application["ecosystem"].null_resource.build_and_load_frontend[0]
}

moved {
  from = kubectl_manifest.ecosystem_application[0]
  to   = module.application["ecosystem"].kubectl_manifest.application[0]
}
