# The contract this layer publishes (ADR 0007). Other layers read it through
# terraform_remote_state on the local backend.

output "cluster" {
  description = "Non-secret facts about the cluster: its name, kube context, kubeconfig path and the host/node port pairs the kind config publishes."
  value = {
    name            = var.cluster_name
    provider        = var.cluster_provider
    kube_context    = local.kube_context
    kubeconfig_path = local.kubeconfig_path
    ports = {
      web_gateway_node_port      = var.web_gateway_node_port
      web_gateway_host_port      = var.web_gateway_host_port
      kong_proxy_http_node_port  = var.kong_proxy_http_node_port
      kong_proxy_http_host_port  = var.kong_proxy_http_host_port
      kong_proxy_https_node_port = var.kong_proxy_https_node_port
      kong_proxy_https_host_port = var.kong_proxy_https_host_port
      grafana_node_port          = var.grafana_node_port
      grafana_host_port          = var.grafana_host_port
      jaeger_node_port           = var.jaeger_node_port
      jaeger_host_port           = var.jaeger_host_port
      prometheus_node_port       = var.prometheus_node_port
      prometheus_host_port       = var.prometheus_host_port
      kiali_node_port            = var.kiali_node_port
      kiali_host_port            = var.kiali_host_port
      kafka_node_port            = var.kafka_node_port
      kafka_host_port            = var.kafka_host_port
    }
  }
}

output "connection" {
  description = "Credentials for the kubernetes, helm and kubectl providers of the layers above."
  sensitive   = true
  value = {
    host                   = local.existing ? local.existing_connection.host : kind_cluster.warehouse[0].endpoint
    cluster_ca_certificate = local.existing ? local.existing_connection.cluster_ca_certificate : kind_cluster.warehouse[0].cluster_ca_certificate
    client_certificate     = local.existing ? local.existing_connection.client_certificate : kind_cluster.warehouse[0].client_certificate
    client_key             = local.existing ? local.existing_connection.client_key : kind_cluster.warehouse[0].client_key
    token                  = local.existing ? local.existing_connection.token : ""
  }
}

output "cluster_name" {
  description = "Name of the cluster (the kind cluster's name, or a label for an existing cluster)."
  value       = var.cluster_name
}
