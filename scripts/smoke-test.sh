#!/usr/bin/env bash
# Behavioral smoke: every deployed API and production MFE asset path.
set -uo pipefail

INFRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${INFRA_DIR}" || exit 1

API_URL="${API_URL:-$(terraform -chdir=terraform output -raw kong_proxy_url 2>/dev/null || echo http://localhost:8000)}"
WEB_URL="${WEB_URL:-$(terraform -chdir=terraform output -raw web_url 2>/dev/null || echo http://localhost)}"
NAMESPACE="${NAMESPACE:-$(terraform -chdir=terraform output -raw apps_namespace 2>/dev/null || echo warehouse-systems)}"
CONTEXT="${KUBE_CONTEXT:-$(terraform -chdir=terraform output -raw kube_context 2>/dev/null || echo kind-warehouse)}"
PROPERTIES="${INFRA_DIR}/scripts/exposure_properties.py"

APIS=()
while IFS= read -r context; do APIS+=("${context}"); done < <(python3 scripts/exposure_inventory.py --kind apis)
REMOTES=()
while IFS= read -r context; do REMOTES+=("${context}"); done < <(python3 scripts/exposure_inventory.py --kind remotes)

failures=0
scratch="$(mktemp -d "${TMPDIR:-/tmp}/warehouse-smoke.XXXXXX")"
cleanup() { rm -rf "${scratch}"; }
trap cleanup EXIT

pass() { printf '  OK   %s\n' "$1"; }
fail() { printf '  FAIL %s\n' "$1"; failures=$((failures + 1)); }

fetch() {
  local url="$1" body_file="$2" headers_file="$3" result
  result="$(curl -sS -D "${headers_file}" -o "${body_file}" \
    -w '%{http_code} %{content_type}' --max-time 15 "${url}" 2>/dev/null)" || result="000 none"
  printf '%s\n' "${result}"
}

echo "=== deployed workloads ==="
kubectl --context "${CONTEXT}" -n "${NAMESPACE}" get pods -o wide || failures=$((failures + 1))
echo

echo "=== all source-derived APIs through Kong ==="
for ctx in "${APIS[@]}"; do
  url="${API_URL}/api/${ctx}/healthz"
  body="${scratch}/${ctx}-api.body"
  headers="${scratch}/${ctx}-api.headers"
  read -r code ctype <<<"$(fetch "${url}" "${body}" "${headers}")"
  if [[ "${code}" == "200" ]]; then
    pass "${ctx} ${url} -> ${code} ${ctype}"
  else
    fail "${ctx} ${url} -> ${code} ${ctype}: $(tr '\n' ' ' <"${body}" 2>/dev/null)"
  fi
done

echo
echo "=== all source-derived remotes and one resolved chunk each ==="
for ctx in "${REMOTES[@]}"; do
  entry_url="${WEB_URL}/mfes/${ctx}/remoteEntry.js"
  body="${scratch}/${ctx}-entry.body"
  headers="${scratch}/${ctx}-entry.headers"
  read -r code ctype <<<"$(fetch "${entry_url}" "${body}" "${headers}")"
  if ! python3 "${PROPERTIES}" javascript --code "${code}" --content-type "${ctype}" --body-file "${body}" >/dev/null; then
    fail "${ctx} remoteEntry.js -> ${code} ${ctype}"
    continue
  fi
  chunk_url="$(python3 "${PROPERTIES}" chunk --entry-url "${entry_url}" --body-file "${body}" 2>/dev/null)" || {
    fail "${ctx} remoteEntry.js has no resolvable chunk"
    continue
  }
  chunk_body="${scratch}/${ctx}-chunk.body"
  chunk_headers="${scratch}/${ctx}-chunk.headers"
  read -r chunk_code chunk_ctype <<<"$(fetch "${chunk_url}" "${chunk_body}" "${chunk_headers}")"
  if python3 "${PROPERTIES}" javascript --code "${chunk_code}" --content-type "${chunk_ctype}" --body-file "${chunk_body}" >/dev/null; then
    pass "${ctx} remoteEntry.js + $(basename "${chunk_url}")"
  else
    fail "${ctx} resolved chunk -> ${chunk_code} ${chunk_ctype}: ${chunk_url}"
  fi
done

echo
if [[ "${failures}" -eq 0 ]]; then
  echo "smoke test PASSED (${#APIS[@]} APIs, ${#REMOTES[@]} remotes with chunks)"
  exit 0
fi
echo "smoke test FAILED (${failures} failures)"
exit 1
