#!/usr/bin/env bash
# Probe every in-cluster MCP server through the official Go SDK, without auth.
#
# Opt-in extra step (default OFF, so today's acceptance does not turn red before
# the Agentic Standard v2 fleet wave): MCP_CONFORMANCE=1 additionally runs the raw
# MCP 2026-07-28 conformance probe (scripts/mcp-conformance-2026-07-28.py) against
# the same port-forward of every server in the same loop: stateless server/discover
# must list 2026-07-28, tools/list must work without Mcp-Session-Id, and a legacy
# 2025-06-18 initialize must still answer 200. Failures are collected and fail the
# run after every server was probed. Output: ${ARTIFACT_DIR}/mcp-conformance-<service>.txt
#   MCP_CONFORMANCE=1                      enable the step
#   MCP_CONFORMANCE_REQUIRE_AUTHORITY=1    also FAIL (not just WARN) on a tool without a
#                                          valid com.warehouse/authority (L1..L4)
# See README.md "MCP 2026-07-28 conformance probe". Not wired into the
# cluster-acceptance workflow yet.
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

conformance_failed=0
conformance_failed_services=""

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
  if [[ "${MCP_CONFORMANCE:-0}" == "1" ]]; then
    conformance_args=(--timeout 10 --target "${service}=http://127.0.0.1:${local_port}/mcp")
    if [[ "${MCP_CONFORMANCE_REQUIRE_AUTHORITY:-0}" == "1" ]]; then
      conformance_args+=(--require-authority)
    fi
    if ! python3 scripts/mcp-conformance-2026-07-28.py "${conformance_args[@]}" \
      | tee "${ARTIFACT_DIR}/mcp-conformance-${service}.txt"; then
      conformance_failed=1
      conformance_failed_services+=" ${service}"
    fi
  fi
  cleanup_port_forward
  echo "  OK   ${service}: official SDK initialize/list/call"
done

if [[ "${MCP_CONFORMANCE:-0}" == "1" ]]; then
  if [[ "${conformance_failed}" -ne 0 ]]; then
    echo "MCP 2026-07-28 conformance FAILED for:${conformance_failed_services}" >&2
    exit 1
  fi
  echo "MCP 2026-07-28 conformance PASSED (${#MCPS[@]} servers)"
fi

echo "MCP acceptance PASSED (${#MCPS[@]} servers, unauthenticated read-only calls)"
