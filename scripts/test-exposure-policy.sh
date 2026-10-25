#!/usr/bin/env bash
# Assert the split Nginx/Kong localhost policy against a deployed cluster.
set -uo pipefail

INFRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${INFRA_DIR}" || exit 1

WEB_URL="${1:-${WEB_URL:-http://localhost}}"
API_URL="${2:-${API_URL:-http://localhost:8000}}"
NAMESPACE="${NAMESPACE:-warehouse-systems}"
CONTEXT="${KUBE_CONTEXT:-kind-warehouse}"
KUBECTL=(kubectl --context "${CONTEXT}")
PROPERTIES="${INFRA_DIR}/scripts/exposure_properties.py"

APIS=()
while IFS= read -r context; do APIS+=("${context}"); done < <(python3 scripts/exposure_inventory.py --kind apis)
REMOTES=()
while IFS= read -r context; do REMOTES+=("${context}"); done < <(python3 scripts/exposure_inventory.py --kind remotes)

FAILURES=0
CHECKS=0
scratch="$(mktemp -d "${TMPDIR:-/tmp}/warehouse-exposure.XXXXXX")"
cleanup() { rm -rf "${scratch}"; }
trap cleanup EXIT

pass() { CHECKS=$((CHECKS + 1)); printf '  ok    %s\n' "$1"; }
fail() { CHECKS=$((CHECKS + 1)); FAILURES=$((FAILURES + 1)); printf '  FAIL  %s\n' "$1"; }

fetch() {
  local url="$1" body_file="$2" headers_file="$3" result
  result="$(curl -sS -D "${headers_file}" -o "${body_file}" \
    -w '%{http_code} %{content_type}' --max-time 15 "${url}" 2>/dev/null)" || result="000 none"
  printf '%s\n' "${result}"
}

header_value() {
  local file="$1" name="$2"
  awk -v wanted="${name}" 'BEGIN { IGNORECASE=1 } $1 == wanted":" { gsub("\\r", "", $2); print $2 }' "${file}" | tail -n 1
}

echo "==> 1. Web gateway config contains frontend routing only"
GW_CONF="${scratch}/nginx.conf"
"${KUBECTL[@]}" -n "${NAMESPACE}" get configmap web-gateway-config \
  -o jsonpath='{.data.nginx\.conf}' >"${GW_CONF}" 2>/dev/null || true
if [[ ! -s "${GW_CONF}" ]]; then
  fail "web-gateway-config ConfigMap not found in ${NAMESPACE}"
elif errors="$(python3 "${PROPERTIES}" nginx --file "${GW_CONF}" 2>&1)"; then
  pass "comments stripped: no /api location, Kong proxy, or API upstream"
else
  fail "invalid web gateway config: ${errors//$'\n'/; }"
fi

echo "==> 2. Kong route, selector isolation, and exposure allowlist"
RESOURCES="${scratch}/resources.json"
APIS_FILE="${scratch}/apis.txt"
printf '%s\n' "${APIS[@]}" >"${APIS_FILE}"
"${KUBECTL[@]}" get service,deployment,httproute -A -o json >"${RESOURCES}" 2>/dev/null || true
if [[ ! -s "${RESOURCES}" ]]; then
  fail "could not read Services, Deployments, and HTTPRoutes"
else
  cluster_args=(
    cluster --resources-file "${RESOURCES}" --apis-file "${APIS_FILE}"
    --allow-exposed warehouse-systems/web-gateway
    --allow-exposed warehouse-systems/kafka-controller-0-external
    --allow-exposed kong/kong-kong-proxy
    --allow-exposed kong/kong-kong-manager
    --allow-exposed observability/grafana-nodeport
    --allow-exposed observability/jaeger-nodeport
    --allow-exposed observability/prometheus-nodeport
    --allow-exposed istio-system/kiali-nodeport
  )
  if errors="$(python3 "${PROPERTIES}" "${cluster_args[@]}" 2>&1)"; then
    pass "all API routes target APIs; selector isolation and NodePort/LoadBalancer allowlist hold"
  else
    fail "cluster exposure property failed: ${errors//$'\n'/; }"
  fi
fi

echo "==> 3. Web shell answers"
for probe in "/healthz" "/"; do
  body="${scratch}/web-$(printf '%s' "${probe}" | tr '/' '_').body"
  headers="${body}.headers"
  read -r code ctype <<<"$(fetch "${WEB_URL}${probe}" "${body}" "${headers}")"
  if [[ "${code}" == "200" ]]; then
    pass "GET ${WEB_URL}${probe} -> 200 ${ctype}"
  else
    fail "GET ${WEB_URL}${probe} -> ${code} ${ctype}"
  fi
done

echo "==> 4. Every source-derived remote serves remoteEntry.js and a resolved chunk"
for ctx in "${REMOTES[@]}"; do
  entry_url="${WEB_URL}/mfes/${ctx}/remoteEntry.js"
  body="${scratch}/${ctx}-entry.body"
  headers="${body}.headers"
  read -r code ctype <<<"$(fetch "${entry_url}" "${body}" "${headers}")"
  if ! errors="$(python3 "${PROPERTIES}" javascript --code "${code}" --content-type "${ctype}" --body-file "${body}" 2>&1)"; then
    fail "${ctx} remoteEntry.js is not JavaScript: ${errors//$'\n'/; }"
    continue
  fi
  chunk_url="$(python3 "${INFRA_DIR}/scripts/exposure_properties.py" chunk --entry-url "${entry_url}" --body-file "${body}" 2>/dev/null)" || {
    fail "${ctx} remoteEntry.js has no relative JavaScript chunk"
    continue
  }
  chunk_body="${scratch}/${ctx}-chunk.body"
  chunk_headers="${chunk_body}.headers"
  read -r chunk_code chunk_ctype <<<"$(fetch "${chunk_url}" "${chunk_body}" "${chunk_headers}")"
  if python3 "${PROPERTIES}" javascript --code "${chunk_code}" --content-type "${chunk_ctype}" --body-file "${chunk_body}" >/dev/null 2>&1; then
    pass "${ctx}: remoteEntry.js + resolved chunk $(basename "${chunk_url}")"
  else
    fail "${ctx}: resolved chunk ${chunk_url} -> ${chunk_code} ${chunk_ctype}"
  fi
done

echo "==> 5. Every source-derived API answers through Kong"
for ctx in "${APIS[@]}"; do
  body="${scratch}/${ctx}-api.body"
  headers="${body}.headers"
  read -r code ctype <<<"$(fetch "${API_URL}/api/${ctx}/healthz" "${body}" "${headers}")"
  if [[ "${code}" == "200" ]]; then
    pass "${ctx} /healthz -> 200 ${ctype}"
  else
    fail "${ctx} /healthz -> ${code} ${ctype}"
  fi
done

echo "==> 6. Web origin never serves an API response"
for ctx in "${APIS[@]}"; do
  body="${scratch}/${ctx}-web-api.body"
  headers="${body}.headers"
  read -r code ctype <<<"$(fetch "${WEB_URL}/api/${ctx}/healthz" "${body}" "${headers}")"
  if [[ "${ctype}" == *html* ]] && ! grep -qi '"status"[[:space:]]*:' "${body}"; then
    pass "web origin returns SPA HTML, not ${ctx} API (${code} ${ctype})"
  else
    fail "web origin may have served ${ctx} API (${code} ${ctype})"
  fi
done

echo "==> 7. Kong never serves frontend assets"
for ctx in "${REMOTES[@]}"; do
  probe="/mfes/${ctx}/remoteEntry.js"
  body="${scratch}/${ctx}-kong-asset.body"
  headers="${body}.headers"
  read -r code ctype <<<"$(fetch "${API_URL}${probe}" "${body}" "${headers}")"
  if [[ "${code}" =~ ^[23] ]] && [[ "${ctype}" == *javascript* || "${ctype}" == *html* ]]; then
    fail "Kong served frontend content at ${probe} (${code} ${ctype})"
  else
    pass "Kong refused ${probe} (${code} ${ctype})"
  fi
done

echo "==> 8. CORS grants exactly ${WEB_URL}"
approved_headers="${scratch}/cors-approved.headers"
evil_headers="${scratch}/cors-evil.headers"
curl -sS -D "${approved_headers}" -o /dev/null --max-time 15 -X OPTIONS \
  -H "Origin: ${WEB_URL}" -H 'Access-Control-Request-Method: GET' \
  "${API_URL}/api/${APIS[0]}/healthz" 2>/dev/null || true
curl -sS -D "${evil_headers}" -o /dev/null --max-time 15 -X OPTIONS \
  -H 'Origin: http://evil.example' -H 'Access-Control-Request-Method: GET' \
  "${API_URL}/api/${APIS[0]}/healthz" 2>/dev/null || true
allow="$(header_value "${approved_headers}" access-control-allow-origin)"
evil_allow="$(header_value "${evil_headers}" access-control-allow-origin)"
if errors="$(python3 "${PROPERTIES}" cors --web-origin "${WEB_URL}" \
  --allowed-origin "${allow}" --evil-allowed-origin "${evil_allow}" 2>&1)"; then
  pass "exact origin allowed and unrelated origin rejected"
else
  fail "CORS policy failed: ${errors//$'\n'/; }"
fi

echo "==> 9. Probe side effects did not cross the split edges"
GW_POD="$("${KUBECTL[@]}" -n "${NAMESPACE}" get pods -l app.kubernetes.io/name=web-gateway -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
CONSOLE_IP="$("${KUBECTL[@]}" -n "${NAMESPACE}" get svc warehouse-console -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true)"
if [[ -z "${GW_POD}" || -z "${CONSOLE_IP}" ]]; then
  fail "cannot inspect web-gateway upstream logs"
else
  API_UPSTREAMS="$("${KUBECTL[@]}" -n "${NAMESPACE}" logs "${GW_POD}" --tail=4000 2>/dev/null \
    | grep -E '"[A-Z]+ /api/' | grep -oE 'upstream=[0-9.]+:[0-9]+' | sort -u \
    | grep -v "upstream=${CONSOLE_IP}:" || true)"
  if [[ -n "${API_UPSTREAMS}" ]]; then
    fail "web gateway proxied /api to non-console upstreams: ${API_UPSTREAMS//$'\n'/ }"
  else
    pass "web /api probes reached only the console SPA upstream"
  fi
fi

KONG_POD="$("${KUBECTL[@]}" -n kong get pods -l app.kubernetes.io/name=kong -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
if [[ -z "${KONG_POD}" ]]; then
  fail "cannot inspect Kong asset-request logs"
else
  SERVED_ASSETS="$("${KUBECTL[@]}" -n kong logs "${KONG_POD}" -c proxy --tail=4000 2>/dev/null \
    | grep -E '"[A-Z]+ [^"]*(\.(html|css|js|woff2?|png|svg)|/mfes/)' \
    | grep -oE '" [23][0-9][0-9] ' || true)"
  if [[ -n "${SERVED_ASSETS}" ]]; then
    fail "Kong served a frontend asset"
  else
    pass "Kong refused every frontend asset probe"
  fi
fi

echo
if [[ "${FAILURES}" -eq 0 ]]; then
  echo "PASS: ${CHECKS} exposure-policy checks (${#APIS[@]} APIs, ${#REMOTES[@]} remotes)"
  exit 0
fi
echo "FAIL: ${FAILURES} of ${CHECKS} exposure-policy checks failed"
exit 1
