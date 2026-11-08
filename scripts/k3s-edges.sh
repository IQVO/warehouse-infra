#!/usr/bin/env bash
# Reach the k3s environment's edges from this workstation (ADR 0011).
#
#     scripts/k3s-edges.sh            # forwards until Ctrl-C
#
# The kind environment publishes the product edges with extraPortMappings on
# 127.0.0.1. A k3s node we may not reconfigure has none, and a NodePort would
# answer on the node's LAN address while every REST/MCP endpoint of this fleet
# is unauthenticated. So the Services are ClusterIP (expose_node_ports = false)
# and this script bridges them with `kubectl port-forward`, bound to 127.0.0.1
# only, on the SAME ports the kind environment uses -- every URL, the console's
# apiOrigin and Kong's CORS origin stay valid:
#
#     UI          http://localhost:80      Nginx web gateway
#     API         http://localhost:8000    Kong
#     Grafana     http://localhost:3000    Jaeger  http://localhost:16686
#     Prometheus  http://localhost:9090    Kiali   http://localhost:20001
#
# Stop whatever else holds those ports first (a kind cluster, `docker ps`).
#
# Port 80 is privileged: macOS lets a normal user bind it on 0.0.0.0 but not on
# 127.0.0.1, and 0.0.0.0 would publish the UI to the LAN. So when any port is
# below 1024 the script re-runs itself under sudo (one password prompt); the
# forwards still bind 127.0.0.1 only. The UI has to stay on :80 -- Kong's CORS
# origin (helm-values/_platform.yaml) and storefront.localhost are fixed to it.
# Override per edge: EDGE_UI_PORT=8081 scripts/k3s-edges.sh (then the console's
# CORS origin no longer matches: browse the API directly, not through the UI).
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  for p in "${EDGE_UI_PORT:-80}" "${EDGE_API_PORT:-8000}" "${EDGE_GRAFANA_PORT:-3000}" "${EDGE_JAEGER_PORT:-16686}" "${EDGE_PROMETHEUS_PORT:-9090}" "${EDGE_KIALI_PORT:-20001}"; do
    if [[ "${p}" -lt 1024 ]]; then
      echo "==> port ${p} is privileged: re-running under sudo" >&2
      exec sudo -E env "KUBECONFIG=${KUBECONFIG:-${HOME}/.kube/config}" "$0" "$@"
    fi
  done
fi

CONTEXT="${KUBE_CONTEXT:-$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["kube_context"])' "$(dirname "${BASH_SOURCE[0]}")/../terraform/targets/k3s.tfvars.json")}"
APPS_NS="${APPS_NAMESPACE:-warehouse-systems}"
KONG_NS="${KONG_NAMESPACE:-kong}"
OBS_NS="${OBSERVABILITY_NAMESPACE:-observability}"
MESH_NS="${ISTIO_NAMESPACE:-istio-system}"

k() { kubectl --context "${CONTEXT}" "$@"; }

# edge <local port> <namespace> <service> <label>
pids=()
edge() {
  local port="$1" ns="$2" svc="$3" label="$4" remote
  if ! remote="$(k -n "${ns}" get "svc/${svc}" -o jsonpath='{.spec.ports[0].port}' 2>/dev/null)" || [[ -z "${remote}" ]]; then
    echo "  skip ${label}: svc/${svc} not found in ${ns}" >&2
    return 0
  fi
  # Restart the forward whenever the pod behind it is replaced.
  (
    while true; do
      k -n "${ns}" port-forward --address 127.0.0.1 "svc/${svc}" "${port}:${remote}" >/dev/null 2>&1 || true
      sleep 2
    done
  ) &
  pids+=("$!")
  echo "  ${label}: http://localhost:${port}" >&2
}

trap 'kill "${pids[@]}" 2>/dev/null || true' EXIT INT TERM

echo "==> forwarding from context ${CONTEXT} (127.0.0.1 only)" >&2
edge "${EDGE_UI_PORT:-80}" "${APPS_NS}" web-gateway "UI (Nginx)"
edge "${EDGE_API_PORT:-8000}" "${KONG_NS}" kong-kong-proxy "API (Kong)"
edge "${EDGE_GRAFANA_PORT:-3000}" "${OBS_NS}" grafana "Grafana"
edge "${EDGE_JAEGER_PORT:-16686}" "${OBS_NS}" jaeger "Jaeger"
edge "${EDGE_PROMETHEUS_PORT:-9090}" "${OBS_NS}" prometheus-server "Prometheus"
edge "${EDGE_KIALI_PORT:-20001}" "${MESH_NS}" kiali "Kiali"

[[ ${#pids[@]} -gt 0 ]] || { echo "error: nothing to forward -- is the platform applied?" >&2; exit 1; }
wait
