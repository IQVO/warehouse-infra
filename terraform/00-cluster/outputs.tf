# The contract this layer publishes (ADR 0007). Other layers read it through
# terraform_remote_state on the local backend.

output "cluster" {
  description = "Non-secret facts about the cluster: its name, kube context, kubeconfig path and the legacy host/node port pairs."
  value = {
    name            = var.cluster_name
    kube_context    = var.kube_context
    kubeconfig_file = var.kubeconfig_file
    ports = {
      web_gateway_host_port     = var.web_gateway_host_port
      kong_proxy_http_host_port = var.kong_proxy_http_host_port
      grafana_host_port         = var.grafana_host_port
      jaeger_host_port          = var.jaeger_host_port
      prometheus_host_port      = var.prometheus_host_port
      kiali_host_port           = var.kiali_host_port
    }
  }
}

output "connection" {
  description = "Credentials for the kubernetes, helm and kubectl providers of the layers above."
  sensitive   = true
  value       = local.connection
}

output "cluster_name" {
  description = "Label of the cluster."
  value       = var.cluster_name
}
