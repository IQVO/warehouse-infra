# ---------------------------------------------------------------------------
# warehouse-ops-agent — a different shape from the other seven services: NO
# database, NO Kafka. A stateless MCP-client aggregator / console-bff fan-out
# reading the other services over plain REST + (eventually) MCP. See its own
# repo's charts/warehouse-ops-agent for the chart; this file is the
# environment overlay, same division of responsibility as helm-values/*.yaml
# for the database-backed services in services.tf.
#
# MCP upstreams (upstreams.* in its chart) are wired from terraform/mcp.tf
# when var.deploy_mcp_servers is true: each of the five contexts' `<svc>-mcp`
# Service endpoints. This is the agent's actual actuator surface (its
# ADR 0004); before 2026-09-07 no MCP server existed in the cluster and
# every endpoint here was empty. Static-bearer MCP auth (the credentials.*
# ReadKey values that used to ride alongside these endpoints) was removed
# fleet-wide (2026-09-09) -- the upstream chart's own credentials.* ReadKey
# fields and Secret/env wiring were dropped in the same PR, so this
# Terraform side keeps only the endpoints; no keys are needed to call them.
# ---------------------------------------------------------------------------

locals {
  ops_agent_chart_path = "${path.module}/../../warehouse-ops-agent/charts/warehouse-ops-agent"

  ops_agent_source_hash = sha256(join("", concat(
    [for f in sort(fileset("${path.module}/../../warehouse-ops-agent", "**/*.go")) : filesha256("${path.module}/../../warehouse-ops-agent/${f}")],
    [
      filesha256("${path.module}/../../warehouse-ops-agent/Dockerfile"),
      filesha256("${path.module}/../../warehouse-ops-agent/go.mod"),
      filesha256("${path.module}/../../warehouse-ops-agent/go.sum"),
    ],
  )))
}

# ---------------------------------------------------------------------------
# ANTHROPIC_API_KEY — Terraform-managed Kubernetes Secret, generated-value
# posture identical to postgres.tf's kubernetes_secret.service_db /
# network-fulfillment.tf's kubernetes_secret.network_fulfillment_db: created
# directly by Terraform (never a plaintext value inside the ArgoCD
# Application CR's `helm.valuesObject`, which is visible via `kubectl get
# application -o yaml`/the ArgoCD UI), consumed by the chart via
# `credentials.existingSecret` rather than `credentials.anthropicApiKey`.
#
# UNLIKE service_db/network_fulfillment_db, this is NOT a `random_password` --
# there is no Terraform-generatable Anthropic API key. `var.anthropic_api_key`
# defaults to "" and MUST be supplied by the operator out-of-band (see that
# variable's description in variables.tf and terraform.tfvars.example). This
# resource still creates the Secret even when the value is empty, so `plan`/
# `apply` never fail on a missing key -- see the `check` block below for how
# that condition surfaces instead, and warehouse-ops-agent's own ADR-0004
# composition root (cmd/agent/reasoner.go) for the real, cluster-side
# fail-loud behavior: `LLM_MODE=shadow requires ANTHROPIC_API_KEY` at pod
# startup, never a silent no-op.
# ---------------------------------------------------------------------------
resource "kubernetes_secret" "ops_agent_anthropic" {
  count = var.deploy_services ? 1 : 0

  metadata {
    name      = "warehouse-ops-agent-anthropic"
    namespace = var.apps_namespace
  }

  data = {
    ANTHROPIC_API_KEY = var.anthropic_api_key
  }

  depends_on = [kubernetes_namespace.apps]
}

# ---------------------------------------------------------------------------
# Plan/apply-time visibility for the "LLM_MODE=shadow with no real key"
# misconfiguration. This is a WARNING only (check-block asserts never fail
# validate/plan/apply) -- the actual enforcement is cluster-side, in
# warehouse-ops-agent's own composition root (confirmed in
# cmd/agent/reasoner.go: a non-off LLM_MODE with an empty ANTHROPIC_API_KEY
# is a hard startup error, so a misconfigured cluster fails LOUD via
# CrashLoopBackOff rather than quietly running the deterministic-only path
# under a name that claims otherwise). This check exists purely so an
# operator seeing `terraform plan` output does not have to wait for that
# crash loop to learn the same fact.
# ---------------------------------------------------------------------------
check "anthropic_api_key_required_for_llm_mode" {
  assert {
    condition     = local.ops_agent_helm_values.llm.mode == "off" || var.anthropic_api_key != ""
    error_message = <<-EOT
      warehouse-ops-agent's LLM_MODE is "${local.ops_agent_helm_values.llm.mode}"
      (not "off") but var.anthropic_api_key is empty. The chart will still
      apply, but the ops-agent pod will CrashLoopBackOff at startup with
      "LLM_MODE=${local.ops_agent_helm_values.llm.mode} requires ANTHROPIC_API_KEY"
      (ADR-0004, cmd/agent/reasoner.go) until a real key is supplied, e.g.:
        export TF_VAR_anthropic_api_key="sk-ant-..."
      before the next `terraform apply`. Never set a real key in this repo's
      tracked files.
    EOT
  }
}

resource "null_resource" "build_and_load_ops_agent" {
  count = var.deploy_services ? 1 : 0

  depends_on = [kind_cluster.warehouse]

  triggers = {
    source_hash = local.ops_agent_source_hash
    image       = "warehouse/warehouse-ops-agent:${local.ops_agent_image_tag}"
    cluster     = var.cluster_name
  }

  provisioner "local-exec" {
    command = "${path.module}/../scripts/build-and-load.sh 'warehouse-ops-agent' '${local.ops_agent_image_tag}' '${var.cluster_name}'"
  }
}

# ---------------------------------------------------------------------------
# Full computed Helm values for warehouse-ops-agent, extracted from the
# (now-removed) helm_release.ops_agent's `values` argument -- unchanged
# content, pure refactor -- so the ArgoCD Application in argocd-apps.tf
# reads from exactly the same computation. Mirrors services.tf's
# local.service_full_values pattern for the 8 database-backed services.
# ---------------------------------------------------------------------------
locals {
  # Content-derived, same rationale as services.tf's local.service_image_tags:
  # ArgoCD's sync only fires on an actual diff, so a fixed tag gives it
  # nothing to detect on a rebuild.
  ops_agent_image_tag = "local-${substr(local.ops_agent_source_hash, 0, 12)}"

  ops_agent_helm_values = merge(
    {
      image = {
        repository = "warehouse/warehouse-ops-agent"
        tag        = local.ops_agent_image_tag
        pullPolicy = "IfNotPresent"
      }

      service = {
        type       = "ClusterIP"
        port       = 80
        targetPort = 8095
      }

      upstreams = {
        wesWorkPlanning      = { endpoint = var.deploy_mcp_servers ? local.mcp_endpoint["wes-work-planning"] : "" }
        fulfillmentExecution = { endpoint = var.deploy_mcp_servers ? local.mcp_endpoint["fulfillment-execution"] : "" }
        inventoryStorage     = { endpoint = var.deploy_mcp_servers ? local.mcp_endpoint["inventory-storage"] : "" }
        workforceManagement  = { endpoint = var.deploy_mcp_servers ? local.mcp_endpoint["workforce-management"] : "" }
        facilityLayout       = { endpoint = var.deploy_mcp_servers ? local.mcp_endpoint["facility-layout"] : "" }
        # Second-wave upstreams (warehouse-ops-agent PR #44's mcpclients).
        # labor-performance is actually CONSUMED as of PR #45 (ADR 0008,
        # FlowBalanceAdvisory's utilization correlation) -- this entry
        # is what makes that live, not just wired-but-unconsumed. The
        # other two have no consuming use case yet; wired here anyway
        # so the next one to graduate needs no infra change, matching
        # the chart-side fix in warehouse-ops-agent PR #46.
        orderManagement       = { endpoint = var.deploy_mcp_servers ? local.mcp_endpoint["order-management"] : "" }
        laborPerformance      = { endpoint = var.deploy_mcp_servers ? local.mcp_endpoint["labor-performance"] : "" }
        processPathManagement = { endpoint = var.deploy_mcp_servers ? local.mcp_endpoint["process-path-management"] : "" }
      }
      # Real, in-cluster REST base URLs for the console-bff order-lifecycle
      # fan-out (cmd/agent/main.go's restclient wiring) — these ARE live
      # today, unlike the MCP upstreams above.
      restUrls = {
        orderManagement      = "http://order-management.${var.apps_namespace}.svc.cluster.local:80"
        inventoryStorage     = "http://inventory-storage.${var.apps_namespace}.svc.cluster.local:80"
        wesWorkPlanning      = "http://wes-work-planning.${var.apps_namespace}.svc.cluster.local:80"
        fulfillmentExecution = "http://fulfillment-execution.${var.apps_namespace}.svc.cluster.local:80"
      }

      # Real, in-cluster REST base URLs for the console-bff's WMS/WES
      # dashboard fan-out (GET /console/reports/wms and /wes -- see
      # warehouse-ops-agent PR #27). Each points at that context's own
      # ANALYTICS reports Service -- a SEPARATE Deployment+Service from the
      # OLTP one above, named "<service>-reports" by every analytics-enabled
      # chart's own reportsFullname helper (see locals.tf's analytics_services
      # set, which now includes all seven contexts). These are only live once
      # `analytics.enabled=true` is actually applied for that service (which
      # `contains(local.analytics_services, each.key)` in services.tf already
      # gates) -- an entry here for a service whose analytics rollout hasn't
      # applied yet just means the BFF's restclient gets a connection refused
      # and that one dashboard section degrades to available:false, per its
      # own documented per-section degradation contract. Not a crash.
      reportsUrls = {
        orderManagement      = "http://order-management-reports.${var.apps_namespace}.svc.cluster.local:80"
        inventoryStorage     = "http://inventory-storage-reports.${var.apps_namespace}.svc.cluster.local:80"
        wesWorkPlanning      = "http://wes-work-planning-reports.${var.apps_namespace}.svc.cluster.local:80"
        fulfillmentExecution = "http://fulfillment-execution-reports.${var.apps_namespace}.svc.cluster.local:80"
        workforceManagement  = "http://workforce-management-reports.${var.apps_namespace}.svc.cluster.local:80"
        facilityLayout       = "http://facility-layout-reports.${var.apps_namespace}.svc.cluster.local:80"
        laborPerformance     = "http://labor-performance-reports.${var.apps_namespace}.svc.cluster.local:80"
      }

      # ADR-0004 model-backed Reasoner. Real, in-cluster wiring per the
      # user's 2026-09-26 decision: shadow mode runs the LLM reasoner
      # alongside the deterministic policy without ever acting on the
      # model's output alone (see cmd/agent/reasoner.go/FlowBalanceAdvisory).
      # `credentials.existingSecret` points at the Terraform-managed
      # Secret above by its fixed, deterministic name (not a resource
      # attribute reference: kubernetes_secret.ops_agent_anthropic is
      # count-gated on var.deploy_services, and this local is evaluated
      # regardless of that flag) -- never `credentials.anthropicApiKey`
      # plaintext, which would land inside the ArgoCD Application CR's
      # `helm.valuesObject` (see this file's kubernetes_secret.
      # ops_agent_anthropic header comment for why that matters).
      credentials = {
        existingSecret = "warehouse-ops-agent-anthropic"
      }
      llm = {
        mode = "shadow"
      }

      # Kong route. NO Ingress at all once Gateway API is on (see the
      # gatewayApi block below) -- disabled-but-present would otherwise
      # still create a Kong route object nothing removes.
      ingress = {
        enabled   = !var.deploy_gateway_api
        className = "kong"
        annotations = {
          "konghq.com/strip-path" = "true"
        }
        hosts = [{
          host = ""
          paths = [{
            path     = "${var.api_path_prefix}/warehouse-ops-agent"
            pathType = "Prefix"
          }]
        }]
      }
    },
    # Gateway API routing -- see gateway-api.tf's header for the full
    # pilot history. warehouse-ops-agent isn't in local.services (it has
    # no database, see this file's own header), so it gets its own
    # gatewayApi block here rather than going through
    # local.gateway_api_pilot_services.
    var.deploy_gateway_api ? {
      gatewayApi = {
        enabled = true
        parentRefs = [{
          name        = local.gateway_name
          namespace   = var.kong_namespace
          sectionName = "http"
        }]
        hosts = [{
          path     = "${var.api_path_prefix}/warehouse-ops-agent"
          pathType = "PathPrefix"
        }]
        stripPath = true
      }
    } : {}
  )
}

# ---------------------------------------------------------------------------
# NOTE: there is deliberately NO `helm_release.ops_agent` resource here
# anymore. ArgoCD (argocd-apps.tf's `kubectl_manifest.ops_agent_application`)
# is now the sole owner of this release's lifecycle -- removed from
# Terraform state via `terraform state rm` after verifying the Application
# was already Synced/Healthy (never a `helm uninstall`).
# ---------------------------------------------------------------------------

output "ops_agent_route" {
  description = "Kong route for warehouse-ops-agent, once deployed."
  value       = var.deploy_services ? "http://localhost:${var.kong_proxy_http_host_port}${var.api_path_prefix}/warehouse-ops-agent" : ""
}
