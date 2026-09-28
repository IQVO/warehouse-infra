#!/usr/bin/env bash
# Build one service's image from its existing Dockerfile and side-load it into
# the kind cluster's containerd store.
#
# Invoked by Terraform (null_resource.build_and_load in terraform/services.tf),
# and safe to run by hand:
#     ./scripts/build-and-load.sh inventory-storage local warehouse
set -euo pipefail

SERVICE="${1:?usage: build-and-load.sh <service> [tag] [cluster]}"
TAG="${2:-local}"
CLUSTER="${3:-warehouse}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CONTEXT_DIR="${REPO_ROOT}/${SERVICE}"
IMAGE="warehouse/${SERVICE}:${TAG}"

if [[ ! -f "${CONTEXT_DIR}/Dockerfile" ]]; then
  echo "error: no Dockerfile at ${CONTEXT_DIR}/Dockerfile" >&2
  exit 1
fi

echo "==> building ${IMAGE} from ${CONTEXT_DIR}"
# --load is a no-op for the classic builder and required for buildx, so this
# works whichever builder the machine defaults to. Pin the platform to the
# host's own arch: the kind nodes run natively, and an amd64 image on an arm64
# node would either refuse to start or crawl under emulation.
docker build \
  --platform "linux/$(docker version --format '{{.Server.Arch}}')" \
  -t "${IMAGE}" \
  "${CONTEXT_DIR}"

echo "==> loading ${IMAGE} into kind cluster '${CLUSTER}'"
kind load docker-image "${IMAGE}" --name "${CLUSTER}"

echo "==> ${IMAGE} ready"
