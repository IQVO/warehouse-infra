#!/usr/bin/env bash
# Single entrypoint: bring the whole local environment up from nothing.
#
#     ./scripts/up.sh
#
# terraform apply does all of it — creates the kind cluster, installs
# PostgreSQL / Istio / Kong, then builds the four service images, loads them
# into kind and installs the four service charts. Re-running is idempotent;
# images rebuild only when their source changes.
set -euo pipefail

INFRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${INFRA_DIR}/terraform"

for tool in docker kind helm terraform kubectl; do
  command -v "$tool" >/dev/null 2>&1 || { echo "error: '$tool' is not on PATH" >&2; exit 1; }
done

if ! docker info >/dev/null 2>&1; then
  echo "error: the Docker daemon is not reachable — start Docker Desktop first" >&2
  exit 1
fi

echo "==> terraform init"
terraform init -input=false

echo "==> terraform apply"
terraform apply -input=false -auto-approve "$@"

echo
echo "==> done. cluster is up."
echo
echo "The product has two independent host-facing edges (docs/exposure/localhost-edge-topology.md):"
echo
echo "  UI   $(terraform output -json product_endpoints | python3 -c 'import json,sys; print(json.load(sys.stdin)["ui"])' 2>/dev/null)"
echo "  API  $(terraform output -json product_endpoints | python3 -c 'import json,sys; print(json.load(sys.stdin)["api"])' 2>/dev/null)"
echo
terraform output routes
echo
echo "Try it:"
# NOTE the /api prefix: API routes moved off the bare /<service> namespace
# because it collided with the console shell's own client-side routes
# (/order-management is a page in the SPA as well as an API prefix).
echo "  open $(terraform output -raw web_url 2>/dev/null || echo http://localhost)"
echo "  curl -i $(terraform output -raw kong_proxy_url)/api/inventory-storage/healthz"
echo "  bash scripts/test-exposure-policy.sh   # asserts the two edges stay separate"

# The observability UIs and Kiali are exposed the same way Kong is: a
# NodePort published on the host via kind's extraPortMappings (see main.tf),
# so they answer at a fixed http://localhost:<port>/ with nothing to
# port-forward or keep alive in a background terminal.
if [[ -n "$(terraform output -raw observability_namespace 2>/dev/null)" ]]; then
  echo
  echo "==> observability. Services send OTLP/gRPC to:"
  echo "  $(terraform output -raw otlp_endpoint)"
  echo
  echo "UIs (Grafana logs in as admin / admin):"
  terraform output -json observability_urls \
    | python3 -c 'import json,sys; [print(f"  {k}: {v}") for k, v in json.load(sys.stdin).items()]'
fi

kiali_url="$(terraform output -raw kiali_url 2>/dev/null || true)"
if [[ -n "$kiali_url" ]]; then
  echo
  echo "==> Kiali (service mesh topology, traffic health): $kiali_url"
fi
