#!/usr/bin/env bash
# Read-only acceptance of the EXISTING k3s cluster (ADR 0011).
#
#     scripts/run-cluster-acceptance.sh --existing
#
# kind is banned, so there is no provisioning mode: nothing is created, planned,
# applied or deleted here. The script only reads (kubectl get/wait, helm list),
# port-forward-backed probes and local artifact writes. Run scripts/k3s-edges.sh
# in another terminal first: smoke-test.sh and test-exposure-policy.sh reach the
# edges on 127.0.0.1.
set -euo pipefail

INFRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKSPACE="$(cd "${INFRA_DIR}/.." && pwd)"
ARTIFACT_DIR="${CLUSTER_ACCEPTANCE_ARTIFACT_DIR:-${INFRA_DIR}/artifacts/cluster-acceptance}"
TARGET="${WAREHOUSE_TARGET:-k3s}"
CONTEXT="${KUBE_CONTEXT:-$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["kube_context"])' "${INFRA_DIR}/terraform/targets/${TARGET}.tfvars.json")}"
MODE="${1:-}"

if [[ "${MODE}" != "--existing" ]]; then
  echo "usage: $0 --existing   (kind is banned: there is no provisioning mode)" >&2
  exit 2
fi

for tool in helm kubectl python3 curl go; do
  command -v "${tool}" >/dev/null 2>&1 || { echo "missing required tool: ${tool}" >&2; exit 5; }
done
kubectl --context "${CONTEXT}" get nodes >/dev/null || { echo "context ${CONTEXT} does not answer" >&2; exit 4; }

mkdir -p "${ARTIFACT_DIR}"

collect_diagnostics() {
  local status="${1:-0}"
  set +e
  kubectl --context "${CONTEXT}" get pods -A -o wide >"${ARTIFACT_DIR}/pods.txt" 2>&1
  kubectl --context "${CONTEXT}" get deployment,statefulset,job -A -o wide >"${ARTIFACT_DIR}/workloads.txt" 2>&1
  kubectl --context "${CONTEXT}" get events -A --sort-by=.lastTimestamp >"${ARTIFACT_DIR}/events.txt" 2>&1
  kubectl --context "${CONTEXT}" get httproute,gateway -A -o yaml >"${ARTIFACT_DIR}/gateway-api.yaml" 2>&1
  kubectl --context "${CONTEXT}" -n argocd get applications.argoproj.io -o yaml >"${ARTIFACT_DIR}/argocd-applications.yaml" 2>&1
  helm --kube-context "${CONTEXT}" list -A >"${ARTIFACT_DIR}/helm-releases.txt" 2>&1
  kubectl --context "${CONTEXT}" get pods -A \
    -o custom-columns=NS:.metadata.namespace,POD:.metadata.name,UID:.metadata.uid,IMAGES:.spec.containers[*].image \
    >"${ARTIFACT_DIR}/pod-images.txt" 2>&1
  "${INFRA_DIR}/scripts/tf.sh" --target "${TARGET}" platform state list >"${ARTIFACT_DIR}/terraform-state.txt" 2>&1
  for output in cluster_name kube_context product_endpoints frontend_routes routes observability_urls kiali_url; do
    "${INFRA_DIR}/scripts/tf.sh" --target "${TARGET}" platform output -no-color "${output}" >"${ARTIFACT_DIR}/terraform-output-${output}.txt" 2>&1
  done
  kubectl --context "${CONTEXT}" -n warehouse-systems describe pods >"${ARTIFACT_DIR}/pod-descriptions.txt" 2>&1
  while IFS= read -r pod; do
    [[ -n "${pod}" ]] || continue
    kubectl --context "${CONTEXT}" -n warehouse-systems logs "${pod}" --all-containers --tail=1000 \
      >"${ARTIFACT_DIR}/logs-${pod}.txt" 2>&1
    kubectl --context "${CONTEXT}" -n warehouse-systems logs "${pod}" --all-containers --previous --tail=1000 \
      >"${ARTIFACT_DIR}/logs-${pod}-previous.txt" 2>&1
  done < <(kubectl --context "${CONTEXT}" -n warehouse-systems get pods -o name 2>/dev/null | cut -d/ -f2)
  printf '%s\n' "${status}" >"${ARTIFACT_DIR}/exit-code.txt"
}

finish() {
  local status=$?
  trap - EXIT
  collect_diagnostics "${status}"
  exit "${status}"
}
trap finish EXIT

fleet_args=(
  --infra-root "${INFRA_DIR}"
  --workspace "${WORKSPACE}"
  --output "${ARTIFACT_DIR}/fleet-shas.json"
)
if [[ -n "${EXPECTED_FLEET_SHAS:-}" ]]; then
  fleet_args+=(--expected-json "${EXPECTED_FLEET_SHAS}")
fi
python3 "${INFRA_DIR}/scripts/write_fleet_shas.py" "${fleet_args[@]}"

for namespace in warehouse-systems warehouse-data kong argocd istio-system; do
  kubectl --context "${CONTEXT}" wait --for=condition=Available deployment --all \
    -n "${namespace}" --timeout=20m
  statefulsets="$(kubectl --context "${CONTEXT}" -n "${namespace}" get statefulset -o name 2>/dev/null || true)"
  while IFS= read -r statefulset; do
    [[ -n "${statefulset}" ]] && kubectl --context "${CONTEXT}" -n "${namespace}" rollout status "${statefulset}" --timeout=20m
  done <<<"${statefulsets}"
  jobs="$(kubectl --context "${CONTEXT}" -n "${namespace}" get job -o name 2>/dev/null || true)"
  while IFS= read -r job; do
    [[ -n "${job}" ]] && kubectl --context "${CONTEXT}" -n "${namespace}" wait --for=condition=Complete "${job}" --timeout=20m
  done <<<"${jobs}"
done

kubectl --context "${CONTEXT}" -n argocd wait applications.argoproj.io --all \
  --for=jsonpath='{.status.sync.status}'=Synced --timeout=20m
kubectl --context "${CONTEXT}" -n argocd wait applications.argoproj.io --all \
  --for=jsonpath='{.status.health.status}'=Healthy --timeout=20m

helm --kube-context "${CONTEXT}" list -A -o json \
  >"${ARTIFACT_DIR}/helm-releases.json"
python3 - "${ARTIFACT_DIR}/helm-releases.json" <<'PY'
import json
import sys

releases = json.load(open(sys.argv[1], encoding="utf-8"))
if not releases:
    raise SystemExit("no Helm releases found")
bad = [f"{item['namespace']}/{item['name']}={item['status']}" for item in releases if item["status"] != "deployed"]
if bad:
    raise SystemExit("Helm releases not deployed: " + ", ".join(bad))
print(f"Helm releases deployed: {len(releases)}")
PY

# k3s runs without Istio sidecars (istio_injection_enabled = false, ADR 0011), so
# there is no istio-proxy readiness check.

bash "${INFRA_DIR}/scripts/smoke-test.sh" | tee "${ARTIFACT_DIR}/smoke-test.txt"
bash "${INFRA_DIR}/scripts/test-exposure-policy.sh" | tee "${ARTIFACT_DIR}/exposure-policy.txt"
KUBE_CONTEXT="${CONTEXT}" NAMESPACE="warehouse-systems" \
  CLUSTER_ACCEPTANCE_ARTIFACT_DIR="${ARTIFACT_DIR}" \
  bash "${INFRA_DIR}/scripts/run-mcp-acceptance.sh" \
  | tee "${ARTIFACT_DIR}/mcp-acceptance.txt"

echo "cluster acceptance PASSED; artifacts: ${ARTIFACT_DIR}"
