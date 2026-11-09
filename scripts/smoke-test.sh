#!/usr/bin/env bash
# Prove the whole path works: host -> kubectl port-forward (scripts/k3s-edges.sh)
# -> Kong -> Kong route -> Go service -> GET /healthz. Run k3s-edges.sh first.
set -uo pipefail

INFRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${INFRA_DIR}" || exit 1
TF="${INFRA_DIR}/scripts/tf.sh"

BASE="$("${TF}" platform output -raw kong_proxy_url)"
NAMESPACE="$("${TF}" platform output -raw apps_namespace 2>/dev/null || echo warehouse-systems)"

# Always the target's context (ADR 0011), never whatever happens to be current
# in the caller's kubeconfig: a stale one (a retired kind cluster) silently shows
# the wrong cluster, or none.
TARGET="${WAREHOUSE_TARGET:-k3s}"
CONTEXT="${KUBE_CONTEXT:-$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["kube_context"])' "${INFRA_DIR}/terraform/targets/${TARGET}.tfvars.json")}"
kubectl() { command kubectl --context "${CONTEXT}" "$@"; }

fail=0

echo "=== pods (expect every container ready; no Istio sidecars on k3s) ==="
kubectl -n "${NAMESPACE}" get pods -o wide
echo

echo "=== ingress routes ==="
kubectl -n "${NAMESPACE}" get ingress
echo

echo "=== GET /healthz through Kong ==="
# Every exposed API context, straight from the source inventory -- never a
# hardcoded service list that drifts the moment a context is registered.
# (while-read, not mapfile: macOS ships bash 3.2.)
APIS=()
while IFS= read -r ctx; do APIS+=("${ctx}"); done < <(python3 scripts/exposure_inventory.py --kind apis)
for ctx in "${APIS[@]}"; do
  # The route is the one the context's own values file declares: it is
  # /api/<ctx> for all but storefront-bff, which is /api/storefront.
  route="$(python3 -c 'import sys,yaml; print(yaml.safe_load(open(sys.argv[1]))["gatewayApi"]["hosts"][0]["path"])' "helm-values/${ctx}.yaml" 2>/dev/null || echo "/api/${ctx}")"
  url="${BASE}${route}/healthz"
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "${url}")"
  body="$(curl -s --max-time 10 "${url}")"
  # Healthy is 200 {"status":"ok"}; fulfillment-execution answers 200 with an
  # empty body and network-inventory-planning 204, both by their own contract.
  if { [ "${code}" = "200" ] && { [ "${body}" = '{"status":"ok"}' ] || [ -z "${body}" ]; }; } || [ "${code}" = "204" ]; then
    echo "ok   ${ctx}: ${code} ${body}"
  else
    echo "FAIL ${ctx}: ${code} ${body}"
    fail=1
  fi
done

# ---------------------------------------------------------------------------
# Observability. Skipped entirely when the stack was not deployed
# (terraform apply -var deploy_observability=false), which is not a failure.
#
# These UIs are ClusterIP only, so each check needs a port-forward. High local
# ports are used on purpose so this never collides with a port-forward the
# developer already has open on 16686/9090/3000.
# ---------------------------------------------------------------------------
OBS_NS="$("${TF}" platform output -raw observability_namespace 2>/dev/null || true)"

if [[ -z "${OBS_NS}" ]]; then
  echo "=== observability: not deployed (deploy_observability=false), skipping ==="
else
  echo
  echo "=== observability pods ==="
  kubectl -n "${OBS_NS}" get pods -o wide
  echo

  pf_pids=()
  cleanup() { for pid in "${pf_pids[@]:-}"; do kill "${pid}" 2>/dev/null || true; done; }
  trap cleanup EXIT

  port_forward() {  # svc, local port, remote port
    kubectl -n "${OBS_NS}" port-forward "svc/$1" "$2:$3" >/dev/null 2>&1 &
    pf_pids+=("$!")
  }

  port_forward jaeger            46686 16686
  port_forward prometheus-server 49090 9090
  port_forward grafana           43000 3000
  sleep 5

  echo "=== observability UIs (through a temporary port-forward) ==="
  check() {  # label, url, expected code
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$2")"
    if [[ "${code}" == "$3" ]]; then
      printf '  OK   %-24s %s -> %s\n' "$1" "$2" "${code}"
    else
      printf '  FAIL %-24s %s -> %s (want %s)\n' "$1" "$2" "${code}" "$3"
      fail=1
    fi
  }

  check "jaeger /api/services" "http://localhost:46686/api/services" 200
  check "prometheus /-/healthy" "http://localhost:49090/-/healthy"   200
  check "grafana /api/health"   "http://localhost:43000/api/health"  200

  # The pipeline itself, not just the pods: Prometheus scraping the collector.
  echo
  echo "=== collector is being scraped by Prometheus ==="
  for job in otel-collector otel-collector-internal; do
    val="$(curl -s --max-time 10 --get "http://localhost:49090/api/v1/query" \
             --data-urlencode "query=up{job=\"${job}\"}" \
           | python3 -c 'import json,sys; r=json.load(sys.stdin)["data"]["result"]; print(r[0]["value"][1] if r else "no-data")')"
    if [[ "${val}" == "1" ]]; then
      printf '  OK   up{job="%s"} = 1\n' "${job}"
    else
      printf '  FAIL up{job="%s"} = %s\n' "${job}" "${val}"
      fail=1
    fi
  done
fi

echo
if [[ "${fail}" -eq 0 ]]; then
  echo "smoke test PASSED"
else
  echo "smoke test FAILED"
fi
exit "${fail}"
