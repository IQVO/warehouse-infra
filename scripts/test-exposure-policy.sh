#!/usr/bin/env bash
# Assert the localhost exposure policy (ADR-0005) against the LIVE cluster.
#
# The design's whole point is that the two host-facing edges are independent:
#
#   http://localhost      -> Nginx web gateway -> frontend bytes only
#   http://localhost:8000 -> Kong              -> APIs only
#
# Neither proxies to the other. That is easy to state and easy to erode -- the
# single most tempting "fix" for a CORS complaint is to add a `location /api`
# to the web gateway, which silently collapses the separation while everything
# still appears to work. This script fails loudly if that happens.
#
# Usage:  ./scripts/test-exposure-policy.sh [web_url] [api_url]
set -uo pipefail

WEB_URL="${1:-http://localhost}"
API_URL="${2:-http://localhost:8000}"
NAMESPACE="${NAMESPACE:-warehouse-systems}"
CONTEXT="${KUBE_CONTEXT:-kind-warehouse}"

KUBECTL=(kubectl --context "${CONTEXT}")

FAILURES=0
CHECKS=0

pass() { CHECKS=$((CHECKS + 1)); printf '  ok    %s\n' "$1"; }
fail() { CHECKS=$((CHECKS + 1)); FAILURES=$((FAILURES + 1)); printf '  FAIL  %s\n' "$1"; }

echo "==> 1. The web gateway must not know how to reach an API"
# The rendered nginx config is the artifact that would betray a collapse of the
# separation, so assert on the config itself rather than only on behaviour.
GW_CONF="$("${KUBECTL[@]}" -n "${NAMESPACE}" get configmap web-gateway-config \
  -o jsonpath='{.data.nginx\.conf}' 2>/dev/null || true)"

if [[ -z "${GW_CONF}" ]]; then
  fail "web-gateway-config ConfigMap not found in ${NAMESPACE}"
else
  # Strip comments BEFORE asserting. The config documents its own policy in
  # prose ("there is deliberately NO location /api ... no Kong upstream"), so
  # grepping the raw text matches the documentation and reports a false
  # failure -- observed exactly that on the first run of this script.
  GW_BODY="$(grep -v '^[[:space:]]*#' <<<"${GW_CONF}")"

  if grep -qE 'location[[:space:]]+[^}]*/api' <<<"${GW_BODY}"; then
    fail "web gateway declares an /api location -- APIs must go to Kong directly"
  else
    pass "web gateway has no /api location"
  fi

  if grep -qiE 'proxy_pass[^;]*kong' <<<"${GW_BODY}"; then
    fail "web gateway proxies to Kong -- the two edges must stay independent"
  else
    pass "web gateway has no Kong upstream"
  fi

  # A backend API Service would be <context>.<ns>.svc, with no -frontend suffix.
  if grep -oE 'proxy_pass http://\$upstream_[a-z_]+' <<<"${GW_BODY}" >/dev/null; then
    if grep -E '^\s*set \$upstream_' <<<"${GW_BODY}" | grep -vE 'frontend|warehouse-console' >/dev/null; then
      fail "web gateway has a non-frontend upstream"
    else
      pass "every web gateway upstream is a frontend Service"
    fi
  fi
fi

echo "==> 2. Kong must route to APIs only, never to a frontend"
ROUTE_BACKENDS="$("${KUBECTL[@]}" -n "${NAMESPACE}" get httproute -o jsonpath='{range .items[*]}{.metadata.name}{"="}{.spec.rules[*].backendRefs[*].name}{"\n"}{end}' 2>/dev/null || true)"
if [[ -z "${ROUTE_BACKENDS}" ]]; then
  fail "no HTTPRoutes found in ${NAMESPACE}"
else
  if grep -E '=.*-frontend' <<<"${ROUTE_BACKENDS}" >/dev/null; then
    fail "a Kong HTTPRoute targets a -frontend Service:"
    grep -E '=.*-frontend' <<<"${ROUTE_BACKENDS}" | sed 's/^/          /'
  else
    pass "no Kong HTTPRoute targets a frontend Service ($(wc -l <<<"${ROUTE_BACKENDS}" | tr -d ' ') routes)"
  fi
fi

echo "==> 3. Exactly two host-facing product Services"
NODEPORTS="$("${KUBECTL[@]}" get svc -A -o jsonpath='{range .items[?(@.spec.type=="NodePort")]}{.metadata.namespace}{"/"}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)"
PRODUCT_NODEPORTS="$(grep "^${NAMESPACE}/" <<<"${NODEPORTS}" || true)"
PRODUCT_COUNT="$(grep -c . <<<"${PRODUCT_NODEPORTS}" || true)"
if [[ "${PRODUCT_COUNT}" == "1" ]] && grep -q "web-gateway" <<<"${PRODUCT_NODEPORTS}"; then
  pass "web-gateway is the only NodePort in ${NAMESPACE}"
else
  fail "expected exactly one NodePort (web-gateway) in ${NAMESPACE}, found: ${PRODUCT_NODEPORTS//$'\n'/ }"
fi

echo "==> 4. The UI answers on the web origin"
for probe in "/healthz" "/"; do
  CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "${WEB_URL}${probe}" || echo 000)"
  if [[ "${CODE}" == "200" ]]; then
    pass "GET ${WEB_URL}${probe} -> 200"
  else
    fail "GET ${WEB_URL}${probe} -> ${CODE}"
  fi
done

echo "==> 5. Every remote is served through the gateway, as JavaScript"
for ctx in order-management inventory-storage wes-work-planning fulfillment-execution \
           workforce-management facility-layout labor-performance process-path-management; do
  URL="${WEB_URL}/mfes/${ctx}/remoteEntry.js"
  read -r CODE CTYPE < <(curl -s -o /dev/null -w '%{http_code} %{content_type}' --max-time 10 "${URL}" || echo "000 none")
  if [[ "${CODE}" == "200" && "${CTYPE}" == *javascript* ]]; then
    pass "${ctx} remoteEntry.js -> 200 ${CTYPE}"
  else
    # An SPA fallback returning HTML with a 200 is the sneaky failure here:
    # the request "succeeded" but the remote does not actually exist.
    fail "${ctx} remoteEntry.js -> ${CODE} ${CTYPE} (expected 200 javascript)"
  fi
done

echo "==> 6. Every API answers on the API origin"
for ctx in order-management inventory-storage wes-work-planning fulfillment-execution \
           workforce-management facility-layout labor-performance process-path-management; do
  CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "${API_URL}/api/${ctx}/healthz" || echo 000)"
  if [[ "${CODE}" == "200" ]]; then
    pass "${ctx} /healthz -> 200"
  else
    fail "${ctx} /healthz -> ${CODE}"
  fi
done

echo "==> 7. APIs are NOT reachable on the web origin"
# If this passes, the gateway is quietly proxying APIs after all.
CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "${WEB_URL}/api/order-management/healthz" || echo 000)"
if [[ "${CODE}" == "200" ]]; then
  fail "GET ${WEB_URL}/api/order-management/healthz -> 200 (the gateway is proxying APIs)"
else
  pass "web origin does not serve APIs (${CODE})"
fi

echo "==> 8. Frontend assets are NOT reachable through Kong"
for probe in "/" "/mfes/order-management/remoteEntry.js"; do
  read -r CODE CTYPE < <(curl -s -o /dev/null -w '%{http_code} %{content_type}' --max-time 10 "${API_URL}${probe}" || echo "000 none")
  if [[ "${CODE}" == "200" && ("${CTYPE}" == *html* || "${CTYPE}" == *javascript*) ]]; then
    fail "Kong served frontend content at ${probe} (${CTYPE})"
  else
    pass "Kong does not serve ${probe} (${CODE})"
  fi
done

echo "==> 9. CORS grants exactly the web origin"
PREFLIGHT="$(curl -s -D - -o /dev/null --max-time 10 -X OPTIONS \
  -H "Origin: ${WEB_URL}" \
  -H 'Access-Control-Request-Method: GET' \
  -H 'Access-Control-Request-Headers: content-type' \
  "${API_URL}/api/order-management/healthz" || true)"
ALLOW="$(grep -i '^access-control-allow-origin:' <<<"${PREFLIGHT}" | tr -d '\r' | awk '{print $2}')"
if [[ "${ALLOW}" == "${WEB_URL}" ]]; then
  pass "preflight from ${WEB_URL} -> allow-origin ${ALLOW}"
elif [[ "${ALLOW}" == "*" ]]; then
  fail "CORS allow-origin is '*' -- these endpoints are unauthenticated, never use a wildcard"
else
  fail "preflight from ${WEB_URL} -> allow-origin '${ALLOW:-<none>}'"
fi

EVIL="$(curl -s -D - -o /dev/null --max-time 10 -X OPTIONS \
  -H 'Origin: http://evil.example' \
  -H 'Access-Control-Request-Method: GET' \
  "${API_URL}/api/order-management/healthz" || true)"
EVIL_ALLOW="$(grep -i '^access-control-allow-origin:' <<<"${EVIL}" | tr -d '\r' | awk '{print $2}')"
if [[ -z "${EVIL_ALLOW}" || "${EVIL_ALLOW}" == "${WEB_URL}" ]]; then
  pass "unapproved origin is not granted access"
else
  fail "unapproved origin was granted '${EVIL_ALLOW}'"
fi

echo "==> 10. Access logs confirm the separation held"
GW_POD="$("${KUBECTL[@]}" -n "${NAMESPACE}" get pods -l app.kubernetes.io/name=web-gateway -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
if [[ -n "${GW_POD}" ]]; then
  if "${KUBECTL[@]}" -n "${NAMESPACE}" logs "${GW_POD}" --tail=2000 2>/dev/null | grep -qE '"[A-Z]+ /api/'; then
    fail "web gateway access log contains an /api request"
  else
    pass "web gateway access log contains no /api request"
  fi
fi

KONG_POD="$("${KUBECTL[@]}" -n kong get pods -l app.kubernetes.io/name=kong -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
if [[ -n "${KONG_POD}" ]]; then
  if "${KUBECTL[@]}" -n kong logs "${KONG_POD}" -c proxy --tail=2000 2>/dev/null \
      | grep -oE '"[A-Z]+ [^ "]+' | grep -qE '\.(html|css|js|woff2?|png|svg)|/mfes/'; then
    fail "Kong access log contains a frontend asset request"
  else
    pass "Kong access log contains no frontend asset request"
  fi
fi

echo
if [[ "${FAILURES}" -eq 0 ]]; then
  echo "PASS: ${CHECKS} exposure-policy checks"
  exit 0
fi
echo "FAIL: ${FAILURES} of ${CHECKS} exposure-policy checks failed"
exit 1
