#!/usr/bin/env bash
# Provision an owned ephemeral cluster, or inspect an existing cluster read-only.
set -euo pipefail

INFRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKSPACE="$(cd "${INFRA_DIR}/.." && pwd)"
TF_DIR="${INFRA_DIR}/terraform"
ARTIFACT_DIR="${CLUSTER_ACCEPTANCE_ARTIFACT_DIR:-${INFRA_DIR}/artifacts/cluster-acceptance}"
CLUSTER_NAME="${CLUSTER_NAME:-warehouse}"
CONTEXT="kind-${CLUSTER_NAME}"
MODE="${1:-}"

if [[ "${MODE}" != "--provision" && "${MODE}" != "--existing" ]]; then
  echo "usage: $0 --provision|--existing" >&2
  exit 2
fi

cluster_exists() { kind get clusters 2>/dev/null | grep -qx "${CLUSTER_NAME}"; }

# The irreversible boundary is checked before any other command. --provision is
# for a fresh, owned runner only and will never adopt, replace, or mutate a
# cluster that was present when the script started.
if [[ "${MODE}" == "--provision" ]] && cluster_exists; then
  echo "refusing to modify pre-existing kind cluster '${CLUSTER_NAME}'; use --existing for read-only acceptance" >&2
  exit 3
fi
if [[ "${MODE}" == "--existing" ]] && ! cluster_exists; then
  echo "kind cluster '${CLUSTER_NAME}' does not exist" >&2
  exit 4
fi

for tool in docker kind helm terraform kubectl python3 curl go; do
  command -v "${tool}" >/dev/null 2>&1 || { echo "missing required tool: ${tool}" >&2; exit 5; }
done

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
  terraform -chdir="${TF_DIR}" state list >"${ARTIFACT_DIR}/terraform-state.txt" 2>&1
  for output in cluster_name kube_context product_endpoints frontend_routes routes observability_urls kiali_url; do
    terraform -chdir="${TF_DIR}" output -no-color "${output}" >"${ARTIFACT_DIR}/terraform-output-${output}.txt" 2>&1
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
if [[ "${MODE}" == "--provision" ]]; then
  fleet_args+=(--require-clean)
fi
if [[ -n "${EXPECTED_FLEET_SHAS:-}" ]]; then
  fleet_args+=(--expected-json "${EXPECTED_FLEET_SHAS}")
fi
python3 "${INFRA_DIR}/scripts/write_fleet_shas.py" "${fleet_args[@]}"

if [[ "${MODE}" == "--provision" ]]; then
  terraform -chdir="${TF_DIR}" init -input=false
  state_entries="$(terraform -chdir="${TF_DIR}" state list 2>/dev/null || true)"
  if [[ -n "${state_entries}" ]]; then
    if [[ "${CLUSTER_ACCEPTANCE_CLEAR_STALE_STATE:-0}" != "1" ]]; then
      echo "Terraform state is non-empty while cluster '${CLUSTER_NAME}' is absent; refusing to clear it without CLUSTER_ACCEPTANCE_CLEAR_STALE_STATE=1" >&2
      exit 6
    fi
    cp "${TF_DIR}/terraform.tfstate" "${ARTIFACT_DIR}/terraform.tfstate.stale-backup"
    printf '%s\n' "${state_entries}" >"${ARTIFACT_DIR}/stale-state-addresses.txt"
    while IFS= read -r address; do
      [[ -n "${address}" ]] && terraform -chdir="${TF_DIR}" state rm "${address}"
    done <<<"${state_entries}"
  fi
  bash "${INFRA_DIR}/scripts/up.sh"
fi

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

# Native Istio sidecars appear under initContainerStatuses. Every product pod
# must report the injected istio-proxy ready before route acceptance starts.
kubectl --context "${CONTEXT}" -n warehouse-systems get pods -o json \
  | python3 -c 'import json,sys; pods=json.load(sys.stdin)["items"]; bad=[p["metadata"]["name"] for p in pods if not any(s["name"]=="istio-proxy" and s.get("ready") for s in p.get("status",{}).get("initContainerStatuses",[]))]; print("native Istio sidecars ready" if not bad else "not ready: "+", ".join(bad)); raise SystemExit(bool(bad))'

bash "${INFRA_DIR}/scripts/smoke-test.sh" | tee "${ARTIFACT_DIR}/smoke-test.txt"
bash "${INFRA_DIR}/scripts/test-exposure-policy.sh" | tee "${ARTIFACT_DIR}/exposure-policy.txt"
KUBE_CONTEXT="${CONTEXT}" NAMESPACE="warehouse-systems" \
  CLUSTER_ACCEPTANCE_ARTIFACT_DIR="${ARTIFACT_DIR}" \
  bash "${INFRA_DIR}/scripts/run-mcp-acceptance.sh" \
  | tee "${ARTIFACT_DIR}/mcp-acceptance.txt"

if [[ "${MODE}" == "--provision" ]]; then
  set +e
  terraform -chdir="${TF_DIR}" plan -input=false -detailed-exitcode -no-color \
    >"${ARTIFACT_DIR}/terraform-second-plan.txt" 2>&1
  plan_status=$?
  set -e
  if [[ "${plan_status}" -ne 0 ]]; then
    echo "second Terraform plan was not idempotent (exit ${plan_status})" >&2
    exit "${plan_status}"
  fi
fi

echo "cluster acceptance PASSED; artifacts: ${ARTIFACT_DIR}"
