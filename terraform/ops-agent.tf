# ---------------------------------------------------------------------------
# warehouse-ops-agent — a different shape from the database-backed contexts:
# NO database, NO Kafka. A stateless MCP-client aggregator / console-bff
# fan-out reading the other services over plain REST and MCP. Its chart lives
# in its own repo, its configuration (MCP upstream endpoints, reports URLs,
# LLM mode) in helm-values/warehouse-ops-agent.yaml (ADR 0002 D2), and its
# Application and Anthropic-key Secret come from modules/application
# (applications.tf). Static-bearer MCP auth was removed fleet-wide
# (2026-09-09): the endpoints need no keys.
#
# DECIDED 2026-09-26: no local build. This repo's `docker-publish` CI job
# publishes to GHCR (ghcr.io/iqvo/warehouse-ops-agent), including a
# `:latest` tag on every merge to main.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# ANTHROPIC_API_KEY — the warehouse-ops-agent-anthropic Secret, created by
# modules/application from this application's `secrets` entry
# (applications.tf), the same way the module creates every context's
# <name>-db Secret: created directly by Terraform (never a plaintext value
# inside the ArgoCD
# Application CR's `helm.valuesObject`, which is visible via `kubectl get
# application -o yaml`/the ArgoCD UI), consumed by the chart via
# `credentials.existingSecret` rather than `credentials.anthropicApiKey`.
#
# UNLIKE the <name>-db Secrets, this is NOT a `random_password` --
# there is no Terraform-generatable Anthropic API key. `var.anthropic_api_key`
# defaults to "" and MUST be supplied by the operator out-of-band (see that
# variable's description in variables.tf and terraform.tfvars.example). The
# module still creates the Secret even when the value is empty, so `plan`/
# `apply` never fail on a missing key -- see the `check` block below for how
# that condition surfaces instead, and warehouse-ops-agent's own ADR-0004
# composition root (cmd/agent/reasoner.go) for the real, cluster-side
# fail-loud behavior: `LLM_MODE=shadow requires ANTHROPIC_API_KEY` at pod
# startup, never a silent no-op.
# ---------------------------------------------------------------------------
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
    condition     = local.ops_agent_values_file.llm.mode == "off" || var.anthropic_api_key != ""
    error_message = <<-EOT
      warehouse-ops-agent's LLM_MODE is "${local.ops_agent_values_file.llm.mode}"
      (not "off") but var.anthropic_api_key is empty. The chart will still
      apply, but the ops-agent pod will CrashLoopBackOff at startup with
      "LLM_MODE=${local.ops_agent_values_file.llm.mode} requires ANTHROPIC_API_KEY"
      (ADR-0004, cmd/agent/reasoner.go) until a real key is supplied, e.g.:
        export TF_VAR_anthropic_api_key="sk-ant-..."
      before the next `terraform apply`. Never set a real key in this repo's
      tracked files.
    EOT
  }
}

# ---------------------------------------------------------------------------
# warehouse-ops-agent's configuration lives in helm-values/warehouse-ops-agent.yaml
# (ADR 0002 D2). Terraform owns only its image, chosen per machine through
# terraform.tfvars, and passes it in the Application's valuesObject
# (applications.tf's local.application_helm_values).
# ---------------------------------------------------------------------------
locals {
  # `:latest` -- this repo's docker-publish CI job pushes it on every merge
  # to main. See this file's header re: no local build. Overridable via
  # var.ops_agent_image_* (e.g. a kind-loaded `warehouse/warehouse-ops-agent`
  # local build) because GHCR org packages are PRIVATE by default: the
  # documented pull-straight-from-GHCR posture needs the package public
  # (org Settings -> Packages -> warehouse-ops-agent -> Change visibility),
  # which needs admin:packages and cannot be done from Terraform.
  ops_agent_image_tag = "latest"

  ops_agent_terraform_values = {
    image = {
      repository = var.ops_agent_image_repository
      tag        = var.ops_agent_image_tag != "" ? var.ops_agent_image_tag : local.ops_agent_image_tag
      # Always for the GHCR default (a :latest tag only tracks the newest
      # published image if the kubelet re-pulls it); IfNotPresent for a
      # kind-loaded local image, which exists only in the nodes'
      # containerd store and must never be pulled.
      pullPolicy = var.ops_agent_image_repository == "ghcr.io/iqvo/warehouse-ops-agent" ? "Always" : "IfNotPresent"
    }
  }

  # The values file, read here only for the check below.
  ops_agent_values_file = yamldecode(file("${path.module}/../helm-values/warehouse-ops-agent.yaml"))
}

# ---------------------------------------------------------------------------
# NOTE: there is deliberately NO `helm_release.ops_agent` resource here
# anymore. ArgoCD (the Application modules/application creates) is now the
# sole owner of this release's lifecycle -- removed from
# Terraform state via `terraform state rm` after verifying the Application
# was already Synced/Healthy (never a `helm uninstall`).
# ---------------------------------------------------------------------------

output "ops_agent_route" {
  description = "Kong route for warehouse-ops-agent, once deployed."
  value       = var.deploy_services ? "http://localhost:${var.kong_proxy_http_host_port}${var.api_path_prefix}/warehouse-ops-agent" : ""
}
