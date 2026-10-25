#!/usr/bin/env bash
# Probe every in-cluster MCP server through the official Go SDK, without auth.
set -euo pipefail

INFRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONTEXT="${KUBE_CONTEXT:-kind-${CLUSTER_NAME:-warehouse}}"
NAMESPACE="${NAMESPACE:-warehouse-systems}"
ARTIFACT_DIR="${CLUSTER_ACCEPTANCE_ARTIFACT_DIR:-${INFRA_DIR}/artifacts/cluster-acceptance}"
mkdir -p "${ARTIFACT_DIR}"
cd "${INFRA_DIR}"

MCPS=()
while IFS= read -r context; do MCPS+=("${context}"); done \
  < <(python3 scripts/exposure_inventory.py --kind mcps)

if [[ "${#MCPS[@]}" -ne 8 ]]; then
  echo "expected 8 MCP services from Terraform, got ${#MCPS[@]}" >&2
  exit 1
fi

port_forward_pid=""
cleanup_port_forward() {
  if [[ -n "${port_forward_pid}" ]]; then
    kill "${port_forward_pid}" 2>/dev/null || true
    wait "${port_forward_pid}" 2>/dev/null || true
    port_forward_pid=""
  fi
}
trap cleanup_port_forward EXIT

for index in "${!MCPS[@]}"; do
  service="${MCPS[${index}]}"
  local_port=$((18090 + index))
  log_file="${ARTIFACT_DIR}/mcp-${service}-port-forward.log"
  result_file="${ARTIFACT_DIR}/mcp-${service}.json"

  cluster_ip="$(kubectl --context "${CONTEXT}" -n "${NAMESPACE}" \
    get "service/${service}-mcp" -o jsonpath='{.spec.clusterIP}')"
  if [[ -z "${cluster_ip}" || "${cluster_ip}" == "None" ]]; then
    echo "${service}-mcp is not a ClusterIP Service" >&2
    exit 1
  fi

  kubectl --context "${CONTEXT}" -n "${NAMESPACE}" \
    port-forward "service/${service}-mcp" "${local_port}:8090" \
    >"${log_file}" 2>&1 &
  port_forward_pid=$!

  ready=0
  for _ in {1..30}; do
    if curl -fsS --max-time 2 "http://127.0.0.1:${local_port}/healthz" >/dev/null 2>&1; then
      ready=1
      break
    fi
    if ! kill -0 "${port_forward_pid}" 2>/dev/null; then
      break
    fi
    sleep 1
  done
  if [[ "${ready}" -ne 1 ]]; then
    echo "${service}-mcp port-forward did not become healthy" >&2
    exit 1
  fi

  go run ./scripts/mcp-probe \
    -service "${service}" \
    -endpoint "http://127.0.0.1:${local_port}/mcp" \
    | tee "${result_file}"
  cleanup_port_forward
  echo "  OK   ${service}: official SDK initialize/list/call"
done

echo "MCP acceptance PASSED (${#MCPS[@]} servers, unauthenticated read-only calls)"
