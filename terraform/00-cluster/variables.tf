# Variables of the cluster layer: the kind cluster and the host ports its
# extraPortMappings publish. The other layers read them from this layer's
# `cluster` output instead of declaring them again (ADR 0007).

# ---------------------------------------------------------------------------
# Cluster
# ---------------------------------------------------------------------------

variable "cluster_provider" {
  description = <<-EOT
    Who owns the cluster this layer describes.

      kind      (default) this layer creates and destroys a kind cluster on the
                local Docker daemon. Every other variable below applies.
      existing  the cluster already exists and belongs to someone else -- a
                k3s node reached over the network. Nothing is created and
                nothing on the machine is touched: the layer only reads the
                credentials of kube_context out of kubeconfig_file and
                publishes them as `connection` (ADR 0011). The kind-only
                variables (worker_count, the *_host_port mappings,
                service_node_port_range) are ignored.
  EOT
  type        = string
  default     = "kind"

  validation {
    condition     = contains(["kind", "existing"], var.cluster_provider)
    error_message = "cluster_provider must be \"kind\" or \"existing\"."
  }
}

variable "kubeconfig_file" {
  description = "cluster_provider = existing: the kubeconfig that holds kube_context. A leading ~ is expanded."
  type        = string
  default     = "~/.kube/config"
}

variable "kube_context" {
  description = "cluster_provider = existing: the context of kubeconfig_file the layers above deploy to (e.g. k3s-multipass). Must authenticate with client certificates or a token; exec plugins are not supported."
  type        = string
  default     = ""
}

variable "cluster_name" {
  description = "Name of the cluster. For kind it is the kind cluster's name and the kubectl context becomes kind-<cluster_name>; with cluster_provider = existing it is only a label (the context is kube_context)."
  type        = string
  default     = "warehouse"
}

variable "kind_node_image" {
  description = <<-EOT
    kind node image, digest-pinned. This is the default image shipped with
    kind v0.32.0 — if you upgrade kind, re-pin this to the new default
    (`strings $(which kind) | grep kindest/node`), because an image newer than
    the kind library embedded in the tehcyx/kind provider will not boot.
  EOT
  type        = string
  default     = "kindest/node:v1.36.1@sha256:3489c7674813ba5d8b1a9977baea8a6e553784dab7b84759d1014dbd78f7ebd5"
}

variable "worker_count" {
  description = "Number of kind worker nodes (in addition to the control-plane node)."
  type        = number
  default     = 1
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

variable "service_node_port_range" {
  description = <<-EOT
    The apiserver's --service-node-port-range, applied via a kubeadm config
    patch in main.tf. Widened from the 30000-32767 default down to 9000 so
    Kafka's NodePort can be 9092 (see kafka_node_port). Kong's and the
    observability UIs' NodePorts stay in the 30000s and are unaffected.
  EOT
  type        = string
  default     = "9000-32767"
}
