#!/usr/bin/env bash
# Tear the environment down on the k3s cluster (ADR 0011).
#
# The cluster is not ours to delete: the applications and then the platform are
# `terraform destroy`ed, in that order, and only that target's state is
# dropped. 00-cluster is never destroyed (it creates nothing). kind is banned.
# Needs --yes.
set -euo pipefail

INFRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="${INFRA_DIR}/terraform"

TARGET="${WAREHOUSE_TARGET:-k3s}"
YES=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --target) TARGET="${2:?--target needs a name}"; shift 2 ;;
    --yes) YES=1; shift ;;
    *) echo "usage: down.sh [--target <name>] --yes" >&2; exit 2 ;;
  esac
done
[[ "${TARGET}" != kind ]] || { echo "error: kind is banned (ADR 0011); every deploy targets k3s" >&2; exit 1; }

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
