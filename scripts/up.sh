#!/usr/bin/env bash
# Single entrypoint: bring the whole local environment up from nothing.
#
#     ./scripts/up.sh
#
# Three Terraform layers, applied in order (ADR 0007):
#
#   00-cluster   the kind cluster
#   10-platform  PostgreSQL / PgBouncer / Kafka / Istio / Kong / observability
#   20-apps      one state per application: builds its image, loads it into kind,
#                creates its role and database, and registers its ArgoCD Application
#
# Re-running is idempotent; images rebuild only when their source changes.
# Variables come from terraform/terraform.tfvars (or TF_VAR_*), which every
# layer reads.
set -euo pipefail

INFRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF="${INFRA_DIR}/scripts/tf.sh"

for tool in docker kind helm terraform kubectl; do
  command -v "$tool" >/dev/null 2>&1 || { echo "error: '$tool' is not on PATH" >&2; exit 1; }
done

if ! docker info >/dev/null 2>&1; then
  echo "error: the Docker daemon is not reachable — start Docker Desktop first" >&2
  exit 1
fi

echo "==> 00-cluster"
"${TF}" cluster apply -input=false -auto-approve

echo "==> 10-platform"
"${TF}" platform apply -input=false -auto-approve

echo "==> 20-apps (one state per application)"
"${TF}" apps apply -input=false -auto-approve

echo
echo "==> done. cluster is up."
echo
echo "The product has two independent host-facing edges (docs/exposure/localhost-edge-topology.md):"
echo
echo "  UI   $("${TF}" platform output -json product_endpoints | python3 -c 'import json,sys; print(json.load(sys.stdin)["ui"])' 2>/dev/null)"
echo "  API  $("${TF}" platform output -json product_endpoints | python3 -c 'import json,sys; print(json.load(sys.stdin)["api"])' 2>/dev/null)"
echo
"${TF}" platform output routes
echo
echo "Try it:"
# NOTE the /api prefix: API routes moved off the bare /<service> namespace
# because it collided with the console shell's own client-side routes
# (/order-management is a page in the SPA as well as an API prefix).
echo "  open $("${TF}" platform output -raw web_url 2>/dev/null || echo http://localhost)"
echo "  curl -i $("${TF}" platform output -raw kong_proxy_url)/api/inventory-storage/healthz"
echo "  bash scripts/test-exposure-policy.sh   # asserts the two edges stay separate"

# The observability UIs and Kiali are exposed the same way Kong is: a
# NodePort published on the host via kind's extraPortMappings (see main.tf),
# so they answer at a fixed http://localhost:<port>/ with nothing to
# port-forward or keep alive in a background terminal.
if [[ -n "$("${TF}" platform output -raw observability_namespace 2>/dev/null)" ]]; then
  echo
  echo "==> observability. Services send OTLP/gRPC to:"
  echo "  $("${TF}" platform output -raw otlp_endpoint)"
  echo
  echo "UIs (Grafana logs in as admin / admin):"
  "${TF}" platform output -json observability_urls \
    | python3 -c 'import json,sys; [print(f"  {k}: {v}") for k, v in json.load(sys.stdin).items()]'
fi

kiali_url="$("${TF}" platform output -raw kiali_url 2>/dev/null || true)"
if [[ -n "$kiali_url" ]]; then
  echo
  echo "==> Kiali (service mesh topology, traffic health): $kiali_url"
fi
