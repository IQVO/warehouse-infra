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
# Kafka's broker listener (kafka-controller-*-external) shares this namespace but
# is PLATFORM infra, not a product edge: it exists so host-side clients
# (e2e-tests, `go run`) can reach the one in-cluster broker. The policy is about
# the product's HTTP surface, so exclude it rather than let it mask a real
# regression. Anything else appearing here IS a finding.
PRODUCT_NODEPORTS="$(grep "^${NAMESPACE}/" <<<"${NODEPORTS}" | grep -v 'kafka-controller' || true)"
PRODUCT_COUNT="$(grep -c . <<<"${PRODUCT_NODEPORTS}" || true)"
if [[ "${PRODUCT_COUNT}" == "1" ]] && grep -q "web-gateway" <<<"${PRODUCT_NODEPORTS}"; then
  pass "web-gateway is the only product NodePort in ${NAMESPACE}"
else
  fail "expected exactly one product NodePort (web-gateway) in ${NAMESPACE}, found: ${PRODUCT_NODEPORTS//$'\n'/ }"
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
# returns-processing and exception-management are in this list (their
# <name>-frontend remotes deploy with everything else) but NOT in the API
# list below: their charts render no Kong HTTPRoute yet, so
# /api/<name>/healthz would 404 (see README's returns/exceptions paragraph).
for ctx in order-management inventory-storage wes-work-planning fulfillment-execution \
           workforce-management facility-layout labor-performance process-path-management \
           warehouse-planning product-master inbound-receiving network-inventory-planning \
           slotting-optimization pick-face-replenishment task-interleaving \
           returns-processing exception-management; do
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
# network-inventory-planning's healthz deliberately returns 204 No Content
# (no body by design) — that is a healthy answer, not a failure.
for ctx in order-management inventory-storage wes-work-planning fulfillment-execution \
           workforce-management facility-layout labor-performance process-path-management \
           warehouse-planning product-master inbound-receiving slotting-optimization \
           pick-face-replenishment task-interleaving network-inventory-planning; do
  CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "${API_URL}/api/${ctx}/healthz" || echo 000)"
  if [[ "${CODE}" == "200" || ( "${CODE}" == "204" && "${ctx}" == "network-inventory-planning" ) ]]; then
    pass "${ctx} /healthz -> ${CODE}"
  else
    fail "${ctx} /healthz -> ${CODE}"
  fi
done

echo "==> 7. APIs are NOT reachable on the web origin"
# If this passes, the gateway is quietly proxying APIs after all.
# The status code alone does not answer this. The gateway's catch-all sends any
# unknown path to the console, whose nginx applies the SPA fallback -- so
# /api/... legitimately returns 200 text/html (the shell). That is NOT a policy
# violation; the violation would be an actual API RESPONSE. Assert on the
# content type and body instead.
read -r CODE CTYPE < <(curl -s -o /tmp/.exposure-api-probe -w '%{http_code} %{content_type}' --max-time 10 "${WEB_URL}/api/order-management/healthz" || echo "000 none")
if [[ "${CTYPE}" == *html* ]]; then
  pass "web origin returns the SPA shell for /api/**, not an API (${CODE} ${CTYPE})"
elif grep -qi '"status"' /tmp/.exposure-api-probe 2>/dev/null; then
  fail "web origin served a real API response for /api/order-management/healthz -- the gateway is proxying APIs"
else
  pass "web origin does not serve APIs (${CODE} ${CTYPE})"
fi
rm -f /tmp/.exposure-api-probe

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

# The warehouse-planning remote's station-standard form and the product-master
# remote's register/classify/dimensions forms issue cross-origin PUTs with a
# JSON Content-Type, which the browser preflights. GET alone would pass the
# check above even if PUT were dropped from the plugin's methods.
for ctx in warehouse-planning product-master; do
  PUT_PREFLIGHT="$(curl -s -D - -o /dev/null --max-time 10 -X OPTIONS \
    -H "Origin: ${WEB_URL}" \
    -H 'Access-Control-Request-Method: PUT' \
    -H 'Access-Control-Request-Headers: content-type' \
    "${API_URL}/api/${ctx}/healthz" || true)"
  PUT_METHODS="$(grep -i '^access-control-allow-methods:' <<<"${PUT_PREFLIGHT}" | tr -d '\r')"
  PUT_HEADERS="$(grep -i '^access-control-allow-headers:' <<<"${PUT_PREFLIGHT}" | tr -d '\r')"
  if grep -qiE '(:|,) *PUT *(,|$)' <<<"${PUT_METHODS}" && grep -qi 'content-type' <<<"${PUT_HEADERS}"; then
    pass "${ctx} PUT preflight from ${WEB_URL} allows PUT + Content-Type"
  else
    fail "${ctx} PUT preflight from ${WEB_URL} -> methods '${PUT_METHODS:-<none>}' headers '${PUT_HEADERS:-<none>}' (its remote needs PUT and Content-Type)"
  fi
done

# The inbound-receiving remote POSTs JSON with an Idempotency-Key header on every
# command (register ASN, book appointment, record receipt lines, ...). A custom
# request header is not CORS-safelisted, so the preflight must list it.
POST_PREFLIGHT="$(curl -s -D - -o /dev/null --max-time 10 -X OPTIONS \
  -H "Origin: ${WEB_URL}" \
  -H 'Access-Control-Request-Method: POST' \
  -H 'Access-Control-Request-Headers: content-type,idempotency-key' \
  "${API_URL}/api/inbound-receiving/healthz" || true)"
POST_METHODS="$(grep -i '^access-control-allow-methods:' <<<"${POST_PREFLIGHT}" | tr -d '\r')"
POST_HEADERS="$(grep -i '^access-control-allow-headers:' <<<"${POST_PREFLIGHT}" | tr -d '\r')"
if grep -qiE '(:|,) *POST *(,|$)' <<<"${POST_METHODS}" && grep -qi 'content-type' <<<"${POST_HEADERS}" && grep -qi 'idempotency-key' <<<"${POST_HEADERS}"; then
  pass "inbound-receiving POST preflight from ${WEB_URL} allows POST + Content-Type + Idempotency-Key"
else
  fail "inbound-receiving POST preflight from ${WEB_URL} -> methods '${POST_METHODS:-<none>}' headers '${POST_HEADERS:-<none>}' (its remote needs POST, Content-Type and Idempotency-Key)"
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
  # A logged /api line is expected (the probe above deliberately makes one) and
  # is only a violation if the gateway PROXIED it to a backend. The log format
  # records the chosen upstream, so compare that against the console's ClusterIP:
  # anything else means an API upstream was reached from here.
  CONSOLE_IP="$("${KUBECTL[@]}" -n "${NAMESPACE}" get svc warehouse-console -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true)"
  API_UPSTREAMS="$("${KUBECTL[@]}" -n "${NAMESPACE}" logs "${GW_POD}" --tail=2000 2>/dev/null \
    | grep -E '"[A-Z]+ /api/' | grep -oE 'upstream=[0-9.]+:[0-9]+' | sort -u \
    | grep -v "upstream=${CONSOLE_IP}:" || true)"
  if [[ -n "${API_UPSTREAMS}" ]]; then
    fail "web gateway proxied an /api request to a non-console upstream: ${API_UPSTREAMS//$'\n'/ }"
  else
    pass "web gateway never proxied /api to a backend (only the SPA shell)"
  fi
fi

KONG_POD="$("${KUBECTL[@]}" -n kong get pods -l app.kubernetes.io/name=kong -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
if [[ -n "${KONG_POD}" ]]; then
  # An asset request appearing in Kong's log is expected (check 8 deliberately
  # makes one). The violation would be Kong SERVING it, so require that every
  # such request was refused -- a 2xx/3xx here means a frontend route exists on
  # Kong, which the design forbids.
  SERVED_ASSETS="$("${KUBECTL[@]}" -n kong logs "${KONG_POD}" -c proxy --tail=2000 2>/dev/null \
    | grep -E '"[A-Z]+ [^"]*(\.(html|css|js|woff2?|png|svg)|/mfes/)' \
    | grep -oE '" [23][0-9][0-9] ' || true)"
  if [[ -n "${SERVED_ASSETS}" ]]; then
    fail "Kong SERVED a frontend asset (expected every such request to be refused)"
  else
    pass "Kong refused every frontend asset request it saw"
  fi
fi

echo "==> 11. Kong plugins: chart-owned, observability on, auth off"
# Fleet decision 2026-10-13: ALL Kong configuration — routes AND plugins —
# lives in each application's Helm chart (namespace-scoped KongPlugin CRs
# attached via konghq.com/plugins), switched on by warehouse-infra's value
# files (helm-values/). Terraform no longer kubectl-applies any Kong
# object. These checks are the sensor for both halves of that decision:
# the plugins must EXIST and be attached, and no authentication or
# authorization plugin may ever appear at the gateway (removed fleet-wide).
PLUGIN_LIST="$("${KUBECTL[@]}" -n "${NAMESPACE}" get kongplugin -o jsonpath='{range .items[*]}{.metadata.name}{"="}{.plugin}{"\n"}{end}' 2>/dev/null || true)"
if [[ -z "${PLUGIN_LIST}" ]]; then
  fail "no KongPlugin objects in ${NAMESPACE} — every chart must render cors/prometheus/opentelemetry and receive kongPlugins.* values from warehouse-infra"
else
  CORS_COUNT=$(grep -c '=cors$' <<<"${PLUGIN_LIST}" || true)
  PROM_COUNT=$(grep -c '=prometheus$' <<<"${PLUGIN_LIST}" || true)
  OTEL_COUNT=$(grep -c '=opentelemetry$' <<<"${PLUGIN_LIST}" || true)
  if [[ "${CORS_COUNT}" -ge 1 && "${PROM_COUNT}" -ge 1 && "${OTEL_COUNT}" -ge 1 ]]; then
    pass "chart-owned KongPlugins present: cors=${CORS_COUNT} prometheus=${PROM_COUNT} opentelemetry=${OTEL_COUNT}"
  else
    fail "chart-owned KongPlugins incomplete in ${NAMESPACE}: cors=${CORS_COUNT} prometheus=${PROM_COUNT} opentelemetry=${OTEL_COUNT} (all must be >= 1)"
  fi
fi
# Authentication/authorization plugins are FORBIDDEN at the gateway.
AUTH_PLUGINS="$(grep -iE '=(basic-auth|key-auth|jwt|oauth2|oidc|acl|hmac-auth|ldap-auth|mtls|session|request-termination)$' <<<"${PLUGIN_LIST}" || true)"
if [[ -n "${AUTH_PLUGINS}" ]]; then
  fail "auth/authorization plugin(s) present, forbidden by the fleet-wide no-auth decision: ${AUTH_PLUGINS//$'\n'/ }"
else
  pass "no authentication/authorization plugin exists at the gateway"
fi
# Every Kong route in the product namespace must carry the plugins annotation
# (a route without it is invisible to cors/prometheus/otel — the exact drift
# the 2026-10-13 incident found live).
UNANNOTATED="$("${KUBECTL[@]}" -n "${NAMESPACE}" get httproute -o json | python3 -c '
import json,sys
routes=json.load(sys.stdin)["items"]
bad=[r["metadata"]["name"] for r in routes if not (r.get("metadata",{}).get("annotations") or {}).get("konghq.com/plugins")]
print(" ".join(bad))
' 2>/dev/null || true)"
if [[ -n "${UNANNOTATED}" ]]; then
  fail "HTTPRoute(s) without konghq.com/plugins annotation: ${UNANNOTATED}"
else
  ROUTE_COUNT="$("${KUBECTL[@]}" -n "${NAMESPACE}" get httproute --no-headers 2>/dev/null | wc -l | tr -d ' ')"
  pass "every HTTPRoute (${ROUTE_COUNT}) carries the konghq.com/plugins annotation"
fi

echo "==> 12. Every MCP server is exposed through Kong"
# Host contract (mcp.route in helm-values/<context>.yaml + each chart's mcp-route.yaml): /api/mcp/<context>
# rewritten to /mcp. A real initialize — not a TCP probe — is the proof:
# routing, rewrite, SSE streaming and the SDK handshake in one round trip.
# NOTE: probe the ROUTE ROOT (/api/mcp/<ctx>), which rewrites to exactly
# /mcp. Appending another /mcp works only on charts whose router also
# mounts the handler at / and silently 404s on three of them.
for ctx in $("${KUBECTL[@]}" -n "${NAMESPACE}" get deploy -o name | sed 's|deployment.apps/||' | grep -- '-mcp$' | sed 's/-mcp$//' | sort); do
  INIT_RESPONSE="$(curl -s --max-time 15 -X POST "${API_URL}/api/mcp/${ctx}" \
    -H 'Content-Type: application/json' \
    -H 'Accept: application/json, text/event-stream' \
    -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"exposure-policy","version":"1"}}}' || true)"
  if grep -q '"protocolVersion"' <<<"${INIT_RESPONSE}"; then
    pass "MCP ${ctx}: initialize through ${API_URL}/api/mcp/${ctx}"
  else
    fail "MCP ${ctx}: initialize at /api/mcp/${ctx} returned no protocolVersion (${INIT_RESPONSE:0:80})"
  fi
done

echo "==> 13. Kong telemetry is actually flowing"
# Plugins existing is necessary but not sufficient (2026-10-13 finding #2:
# the otel plugin was configured but exported ZERO spans because
# KONG_TRACING_INSTRUMENTATIONS was unset). Assert on the live signals.
if "${KUBECTL[@]}" -n kong get deploy kong-kong -o jsonpath='{.spec.template.spec.containers[?(@.name=="proxy")].env}' 2>/dev/null | grep -q 'TRACING_INSTRUMENTATIONS'; then
  pass "Kong proxy has tracing instrumentation enabled (KONG_TRACING_INSTRUMENTATIONS)"
else
  fail "Kong proxy lacks KONG_TRACING_INSTRUMENTATIONS — the otel plugins will export zero spans"
fi
# Prometheus pipeline: Kong's :8100 status listener has no curl/wget in the
# container, so prove it the real way — Prometheus itself scraped kong_*
# metrics (plugin -> :8100 -> prometheus scrape). The Prometheus UI is
# already host-reachable at the observability NodePort (exposure.tf);
# query it directly, no port-forward needed. KUBECONFIG's prometheus
# port-forward in an earlier draft targeted :80 while the Service listens
# on 9090 — that mismatch made this check always fail.
PROM_URL="http://localhost:9090"
KONG_METRICS="$(curl -s --max-time 10 "${PROM_URL}/api/v1/query?query=kong_http_requests_total" 2>/dev/null || true)"
if grep -q '"result":\[{' <<<"${KONG_METRICS}"; then
  pass "Prometheus is scraping Kong's prometheus-plugin metrics (kong_http_requests_total present)"
else
  fail "kong_http_requests_total absent from Prometheus at ${PROM_URL} — the prometheus plugins or the :8100 scrape path is broken"
fi

echo
if [[ "${FAILURES}" -eq 0 ]]; then
  echo "PASS: ${CHECKS} exposure-policy checks"
  exit 0
fi
echo "FAIL: ${FAILURES} of ${CHECKS} exposure-policy checks failed"
exit 1
