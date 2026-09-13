# ---------------------------------------------------------------------------
# One ArgoCD `Application` per bounded-context service, generated straight
# from `local.services` -- adding a service there is the ONLY registration
# step needed; it automatically gets an Application here with the exact
# same computed values `helm_release.service` (services.tf) uses today,
# via the shared `local.service_full_values` (services.tf).
#
# `for_each` over `local.services` directly (rather than ArgoCD's own
# `ApplicationSet` list-generator CRD) is deliberate: Terraform already
# owns the authoritative service registry, so a second generator construct
# to reproduce the same set adds a moving part with no benefit here.
#
# Piloted on "order-management" alone first (verified Synced/Healthy, zero
# drift, self-heal confirmed) before fanning out to the full set below.
# ---------------------------------------------------------------------------

resource "kubectl_manifest" "application" {
  for_each = var.deploy_services ? local.services : {}

  yaml_body = yamlencode({
    apiVersion = "argoproj.io/v1alpha1"
    kind       = "Application"
    metadata = {
      name      = each.key
      namespace = kubernetes_namespace.argocd.metadata[0].name
    }
    spec = {
      project = "default"
      source = {
        repoURL        = "https://github.com/claudioed/${each.key}.git"
        targetRevision = "develop"
        path           = "charts/${each.key}"
        helm = {
          valuesObject = local.service_full_values[each.key]
        }
      }
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

  depends_on = [
    helm_release.argocd,
    kubernetes_secret.service_db,
  ]
}
