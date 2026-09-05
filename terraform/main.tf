# ---------------------------------------------------------------------------
# The kind cluster: one control-plane + var.worker_count workers.
#
# extraPortMappings on the control-plane publish Kong's NodePort, plus the
# observability UIs' (Grafana/Jaeger/Prometheus) and Kiali's NodePorts, on
# host ports. NodePorts answer on every node, so mapping them on the
# control-plane alone is enough no matter where each pod actually lands.
# ---------------------------------------------------------------------------

resource "kind_cluster" "warehouse" {
  name            = var.cluster_name
  node_image      = var.kind_node_image
  kubeconfig_path = local.kubeconfig_path
  wait_for_ready  = true

  kind_config {
    kind        = "Cluster"
    api_version = "kind.x-k8s.io/v1alpha4"

    node {
      role = "control-plane"

      extra_port_mappings {
        container_port = var.kong_proxy_http_node_port
        host_port      = var.kong_proxy_http_host_port
        listen_address = "0.0.0.0"
        protocol       = "TCP"
      }

      extra_port_mappings {
        container_port = var.kong_proxy_https_node_port
        host_port      = var.kong_proxy_https_host_port
        listen_address = "0.0.0.0"
        protocol       = "TCP"
      }

      extra_port_mappings {
        container_port = var.grafana_node_port
        host_port      = var.grafana_host_port
        listen_address = "0.0.0.0"
        protocol       = "TCP"
      }

      extra_port_mappings {
        container_port = var.jaeger_node_port
        host_port      = var.jaeger_host_port
        listen_address = "0.0.0.0"
        protocol       = "TCP"
      }

      extra_port_mappings {
        container_port = var.prometheus_node_port
        host_port      = var.prometheus_host_port
        listen_address = "0.0.0.0"
        protocol       = "TCP"
      }

      extra_port_mappings {
        container_port = var.kiali_node_port
        host_port      = var.kiali_host_port
        listen_address = "0.0.0.0"
        protocol       = "TCP"
      }
    }

    dynamic "node" {
      for_each = range(var.worker_count)
      content {
        role = "worker"
      }
    }
  }
}

# Convenience only — the providers above do NOT read this (see providers.tf).
# Setting kubeconfig_path on kind_cluster makes the provider write credentials
# to that file *instead of* your default kubeconfig, which would leave plain
# `kubectl` with no kind-<name> context. This exports to both: the module-local
# file, and your default kubeconfig so kubectl/helm just work.
#
# The kind CLI is used here purely to export credentials; the cluster lifecycle
# stays owned by the kind_cluster resource above, so `terraform destroy` still
# tears it down properly.
resource "null_resource" "kubeconfig" {
  depends_on = [kind_cluster.warehouse]

  triggers = {
    cluster_id = kind_cluster.warehouse.id
  }

  provisioner "local-exec" {
    command = <<-EOT
      kind export kubeconfig --name ${var.cluster_name} --kubeconfig ${local.kubeconfig_path}
      kind export kubeconfig --name ${var.cluster_name}
    EOT
  }
}

# ---------------------------------------------------------------------------
# Namespaces
# ---------------------------------------------------------------------------

resource "kubernetes_namespace" "data" {
  depends_on = [null_resource.kubeconfig]

  metadata {
    name = var.data_namespace
    labels = {
      "warehouse.local/tier" = "data"
    }
  }
}

resource "kubernetes_namespace" "kong" {
  depends_on = [null_resource.kubeconfig]

  metadata {
    name = var.kong_namespace
    labels = {
      "warehouse.local/tier" = "gateway"
    }
  }
}

# The ONLY thing required to put the four Go services into the Istio mesh.
# No application code, port, or env-var change is needed: istiod's mutating
# admission webhook rewrites the pod spec at admission time to add the
# istio-proxy sidecar and an init container that installs the iptables
# redirect. The apps keep listening on :8080 and keep serving GET /healthz
# exactly as they do under docker-compose.
resource "kubernetes_namespace" "apps" {
  depends_on = [helm_release.istiod]

  metadata {
    name = var.apps_namespace
    labels = {
      "istio-injection"      = "enabled"
      "warehouse.local/tier" = "application"
    }
  }
}
