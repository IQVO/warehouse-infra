# Variables of the cluster layer (ADR 0007, ADR 0011): which existing cluster
# the layers above deploy to, and the legacy node/host port pairs the other
# layers read from this layer's `cluster` output instead of declaring them
# again. Nothing here creates a cluster: kind is banned, k3s is the only target.

# ---------------------------------------------------------------------------
# Cluster
# ---------------------------------------------------------------------------

variable "kubeconfig_file" {
  description = "The kubeconfig that holds kube_context. A leading ~ is expanded."
  type        = string
  default     = "~/.kube/config"
}

variable "kube_context" {
  description = "The context of kubeconfig_file the layers above deploy to (e.g. k3s-multipass). Must authenticate with client certificates or a token; exec plugins are not supported."
  type        = string
  default     = ""
}

variable "cluster_name" {
  description = "Label of the cluster (the kubectl context is kube_context)."
  type        = string
  default     = "warehouse"
}

variable "web_gateway_node_port" {
  description = "NodePort for the Nginx web gateway."
  type        = number
  default     = 30081
}

variable "web_gateway_host_port" {
  description = <<-EOT
    Host port for the Nginx web gateway -- where the product UI actually lives.
    Defaults to 80 so the console is at http://localhost/.

    Note Kong moved OFF port 80 to make room for this (see
    kong_proxy_http_host_port, now 8000). kind's extraPortMappings are
    immutable, so changing either port requires a cluster destroy/recreate.
  EOT
  type        = number
  default     = 80
}

variable "kong_proxy_http_node_port" {
  description = "NodePort inside the cluster for Kong's HTTP proxy listener."
  type        = number
  default     = 30080
}

variable "kong_proxy_https_node_port" {
  description = "NodePort inside the cluster for Kong's HTTPS proxy listener."
  type        = number
  default     = 30443
}

variable "kong_proxy_http_host_port" {
  description = <<-EOT
    Host port mapped to the Kong HTTP NodePort: the product's API origin,
    http://localhost:8000.

    This was 80 until the Nginx web gateway took that port for the product UI
    (ADR-0005). Kong serves APIs only and must never serve HTML/JS/CSS, so the
    two edges get their own ports rather than one proxying to the other.
  EOT
  type        = number
  default     = 8000
}

variable "kong_proxy_https_host_port" {
  description = "Host port mapped to the Kong HTTPS NodePort. Defaults to 443."
  type        = number
  default     = 443
}

# ---------------------------------------------------------------------------
# Observability + Kiali north-south exposure
#
# Same pattern as Kong above: no cloud load balancer, so each UI's Service is
# a NodePort and kind's extraPortMappings publish that NodePort on a host
# port at cluster-creation time. This replaces ad-hoc `kubectl port-forward`
# for these UIs — a host port survives pod restarts and multiple terminal
# tabs; a port-forward process does neither.
# ---------------------------------------------------------------------------

variable "grafana_node_port" {
  description = "NodePort inside the cluster for Grafana."
  type        = number
  default     = 30300
}

variable "grafana_host_port" {
  description = "Host port mapped to Grafana's NodePort. Grafana is reachable at http://localhost:<this>/."
  type        = number
  default     = 3000
}

variable "jaeger_node_port" {
  description = "NodePort inside the cluster for the Jaeger query UI."
  type        = number
  default     = 30686
}

variable "jaeger_host_port" {
  description = "Host port mapped to Jaeger's NodePort. Jaeger is reachable at http://localhost:<this>/."
  type        = number
  default     = 16686
}

variable "prometheus_node_port" {
  description = "NodePort inside the cluster for the Prometheus UI."
  type        = number
  default     = 30909
}

variable "prometheus_host_port" {
  description = "Host port mapped to Prometheus's NodePort. Prometheus is reachable at http://localhost:<this>/."
  type        = number
  default     = 9090
}

variable "kiali_node_port" {
  description = "NodePort inside the cluster for the Kiali UI."
  type        = number
  default     = 30200
}

variable "kiali_host_port" {
  description = "Host port mapped to Kiali's NodePort. Kiali is reachable at http://localhost:<this>/."
  type        = number
  default     = 20001
}

variable "kafka_node_port" {
  description = <<-EOT
    NodePort inside the cluster for Kafka's EXTERNAL listener.

    Deliberately 9092 — the same number as the host port — so there is one
    Kafka port to remember across the whole fleet. This is BELOW the default
    service-node-port-range (30000-32767), which is why main.tf patches the
    apiserver's --service-node-port-range; without that patch the Service is
    rejected with "provided port is not in the valid range".
  EOT
  type        = number
  default     = 9092
}

variable "kafka_host_port" {
  description = <<-EOT
    Host port mapped to Kafka's NodePort. Kafka is reachable from the host at
    localhost:<this>, which is the address e2e-tests/env.sh and every service
    repo's README already use.
  EOT
  type        = number
  default     = 9092
}

