#!/usr/bin/env bash
# Single entrypoint: bring the whole environment up on the k3s cluster.
#
#     ./scripts/up.sh [--target k3s]
#
# kind is banned (ADR 0011): the only environment is the existing k3s cluster
# (terraform/targets/k3s.tfvars.json). Nothing is created on the machine and
# nothing is built here; every image is pulled from ghcr.io, built by the
# publish-images workflow and pinned in terraform/targets/k3s.images.yaml.
#
# Three Terraform layers, applied in order (ADR 0007):
#
#   00-cluster   reads the kubeconfig context (creates nothing)
#   10-platform  PostgreSQL / PgBouncer / Kafka / Istio / Kong / observability
#   20-apps      one state per application: creates its role and database and
#                registers its ArgoCD Application with the pinned image tags
#
# Re-running is idempotent. Variables come from terraform/terraform.tfvars (or
# TF_VAR_*) and the target file, which every layer reads.
set -euo pipefail

INFRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF="${INFRA_DIR}/scripts/tf.sh"

TARGET="${WAREHOUSE_TARGET:-k3s}"
if [[ "${1:-}" == --target ]]; then TARGET="${2:?--target needs a name}"; shift 2; fi
[[ "${TARGET}" != kind ]] || { echo "error: kind is banned (ADR 0011); every deploy targets k3s" >&2; exit 1; }
export WAREHOUSE_TARGET="${TARGET}"

for tool in helm terraform kubectl python3; do
  command -v "$tool" >/dev/null 2>&1 || { echo "error: '$tool' is not on PATH" >&2; exit 1; }
done
ctx="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["kube_context"])' "${INFRA_DIR}/terraform/targets/${TARGET}.tfvars.json")"
echo "==> target ${TARGET}: context ${ctx}"
kubectl --context "${ctx}" get nodes >/dev/null || { echo "error: context ${ctx} does not answer" >&2; exit 1; }
# Every image is pulled; a missing pin is a plan error later, so say it now.
[[ -s "${INFRA_DIR}/terraform/targets/${TARGET}.images.yaml" ]] || {
  echo "error: terraform/targets/${TARGET}.images.yaml is missing: run the publish-images workflow, then scripts/k3s-pin-images.sh --latest" >&2
  exit 1
}

echo "==> 00-cluster"
"${TF}" cluster apply -input=false -auto-approve

echo "==> 10-platform"
"${TF}" platform apply -input=false -auto-approve

echo "==> 20-apps (one state per application)"
"${TF}" apps apply -input=false -auto-approve

echo
echo "==> done. cluster is up."
echo
echo "Nothing is published on the node. Reach the edges from this machine with:"
echo "  scripts/k3s-edges.sh"
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

# The observability UIs are ClusterIP Services on k3s; scripts/k3s-edges.sh
# port-forwards them to 127.0.0.1.
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
