#!/usr/bin/env bash
# Build one frontend's image from its own Dockerfile and side-load it into the
# kind cluster's containerd store.
#
# Separate from build-and-load.sh because a frontend build is genuinely a
# different shape from a Go service build:
#
#   * the build context is <repo>/web/, not <repo>/ (the console is the one
#     exception -- its SPA lives at the repo root)
#   * @warehouse/ui-kit is a sibling CHECKOUT consumed via `file:` rather than
#     a registry package, so it must be supplied as a named BuildKit context
#   * BuildKit is mandatory (the Dockerfiles use `--mount=type=cache`), so
#     DOCKER_BUILDKIT=1 is forced rather than left to the machine's default
#
# Invoked by Terraform (null_resource.build_and_load_frontend in
# terraform/frontends.tf), and safe to run by hand:
#     ./scripts/build-and-load-frontend.sh order-management web local-abc123 warehouse
set -euo pipefail

CONTEXT_NAME="${1:?usage: build-and-load-frontend.sh <context> <subdir> [tag] [cluster]}"
SUBDIR="${2:?usage: build-and-load-frontend.sh <context> <subdir> [tag] [cluster]}"
TAG="${3:-local}"
CLUSTER="${4:-warehouse}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# The console's SPA is the repo root; every bounded-context remote lives in
# <repo>/web. "." keeps the caller from having to special-case that.
if [[ "${SUBDIR}" == "." ]]; then
  CONTEXT_DIR="${REPO_ROOT}/${CONTEXT_NAME}"
else
  CONTEXT_DIR="${REPO_ROOT}/${CONTEXT_NAME}/${SUBDIR}"
fi

UIKIT_DIR="${REPO_ROOT}/warehouse-ui-kit"
IMAGE="warehouse/${CONTEXT_NAME}-frontend:${TAG}"

if [[ ! -f "${CONTEXT_DIR}/Dockerfile" ]]; then
  echo "error: no Dockerfile at ${CONTEXT_DIR}/Dockerfile" >&2
  exit 1
fi

if [[ ! -d "${UIKIT_DIR}" ]]; then
  echo "error: no warehouse-ui-kit checkout at ${UIKIT_DIR}" >&2
  echo "       every frontend consumes it via file:../../warehouse-ui-kit" >&2
  exit 1
fi

echo "==> building ${IMAGE} from ${CONTEXT_DIR}"
# BuildKit is required for --mount=type=cache and --build-context, both of
# which these Dockerfiles use. Pin the platform to the host's own arch for the
# same reason build-and-load.sh does: the kind nodes run natively.
DOCKER_BUILDKIT=1 docker build \
  --platform "linux/$(docker version --format '{{.Server.Arch}}')" \
  --build-context "uikit=${UIKIT_DIR}" \
  -t "${IMAGE}" \
  "${CONTEXT_DIR}"

echo "==> loading ${IMAGE} into kind cluster '${CLUSTER}'"
kind load docker-image "${IMAGE}" --name "${CLUSTER}"

echo "==> ${IMAGE} ready"
