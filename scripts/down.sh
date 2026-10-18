#!/usr/bin/env bash
# Tear everything down.
#
# Deleting the kind cluster removes every object in it (the Helm releases, the
# ArgoCD Applications, the namespaces, the data) and reclaims the Docker
# containers and their disk. `terraform destroy` per layer used to be the way,
# but it leaves phantom resources behind and takes far longer than the cluster
# delete it ends with, so the layers' states are dropped instead: with the
# cluster gone, none of the three describes anything.
set -euo pipefail

INFRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="${INFRA_DIR}/terraform"

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
