#!/usr/bin/env bash
# Tear everything down.
#
# Deleting the kind cluster removes every object in it (the Helm releases, the
# ArgoCD Applications, the namespaces, the data) and reclaims the Docker
# containers and their disk. `terraform destroy` per layer used to be the way,
# but it leaves phantom resources behind and takes far longer than the cluster
# delete it ends with, so the layers' states are dropped instead: with the
# cluster gone, none of the three describes anything.
#
# With --target <name> (ADR 0011) the cluster is not ours to delete: the
# applications and then the platform are `terraform destroy`ed, in that order,
# and only that target's state is dropped. Needs --yes.
set -euo pipefail

INFRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="${INFRA_DIR}/terraform"

TARGET="${WAREHOUSE_TARGET:-}"
YES=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --target) TARGET="${2:?--target needs a name}"; shift 2 ;;
    --yes) YES=1; shift ;;
    *) echo "usage: down.sh [--target <name> --yes]" >&2; exit 2 ;;
  esac
done
[[ "${TARGET}" == kind ]] && TARGET=""

if [[ -n "${TARGET}" ]]; then
  [[ -n "${YES}" ]] || { echo "error: this destroys the ${TARGET} environment's Helm releases, namespaces and data; re-run with --yes" >&2; exit 1; }
  TF="${INFRA_DIR}/scripts/tf.sh"
  echo "==> terraform destroy: 20-apps (${TARGET})"
  "${TF}" --target "${TARGET}" apps destroy -input=false -auto-approve
  echo "==> terraform destroy: 10-platform (${TARGET})"
  "${TF}" --target "${TARGET}" platform destroy -input=false -auto-approve
  echo "==> dropping the ${TARGET} state"
  for layer in 00-cluster 10-platform 20-apps; do
    rm -f "${TF_DIR}/${layer}/terraform.tfstate.${TARGET}" "${TF_DIR}/${layer}/terraform.tfstate.${TARGET}.backup"
  done
  rm -rf "${TF_DIR}/20-apps/terraform.tfstate.d.${TARGET}"
  echo "==> torn down (the ${TARGET} machine itself is untouched)"
  exit 0
fi

CLUSTER="$("${INFRA_DIR}/scripts/tf.sh" cluster output -raw cluster_name 2>/dev/null || echo warehouse)"

if kind get clusters 2>/dev/null | grep -qx "${CLUSTER}"; then
  echo "==> kind delete cluster --name ${CLUSTER}"
  kind delete cluster --name "${CLUSTER}"
fi

echo "==> dropping the layers' Terraform state"
for layer in 00-cluster 10-platform 20-apps; do
  rm -f "${TF_DIR}/${layer}"/terraform.tfstate "${TF_DIR}/${layer}"/terraform.tfstate.*
done
rm -rf "${TF_DIR}/20-apps/terraform.tfstate.d"
rm -f "${TF_DIR}/00-cluster/kubeconfig"
echo "==> torn down"
