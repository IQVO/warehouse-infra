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

variable "web_gateway_host_port" {
  description = <<-EOT
    Host port for the Nginx web gateway -- where the product UI actually lives.
    Defaults to 80 so the console is at http://localhost/.

    Note Kong moved OFF port 80 to make room for this (see
    kong_proxy_http_host_port, now 8000). scripts/k3s-edges.sh reads its
    ports from its own EDGE_*_PORT variables, so these are labels for the
    URLs the outputs print.
  EOT
  type        = number
  default     = 80
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

# ---------------------------------------------------------------------------
# Observability + Kiali edges
#
# The UIs' Services are ClusterIP; scripts/k3s-edges.sh port-forwards them to
# these local ports on 127.0.0.1 (ADR 0011). The numbers only label the URLs
# the platform outputs print.
# ---------------------------------------------------------------------------

variable "grafana_host_port" {
  description = "Host port mapped to Grafana's NodePort. Grafana is reachable at http://localhost:<this>/."
  type        = number
  default     = 3000
}

variable "jaeger_host_port" {
  description = "Host port mapped to Jaeger's NodePort. Jaeger is reachable at http://localhost:<this>/."
  type        = number
  default     = 16686
}

variable "prometheus_host_port" {
  description = "Host port mapped to Prometheus's NodePort. Prometheus is reachable at http://localhost:<this>/."
  type        = number
  default     = 9090
}

variable "kiali_host_port" {
  description = "Host port mapped to Kiali's NodePort. Kiali is reachable at http://localhost:<this>/."
  type        = number
  default     = 20001
}

