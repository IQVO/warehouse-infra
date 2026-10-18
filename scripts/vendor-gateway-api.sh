#!/usr/bin/env bash
# Vendor a Gateway API standard-channel release bundle into terraform/gateway-api/.
#
# terraform/gateway-api.tf reads terraform/gateway-api/standard-install-<tag>.yaml
# for var.gateway_api_version, so a plan needs no network and a version bump is
# a reviewable diff (ADR 0006). Run it, then commit the new file:
#     ./scripts/vendor-gateway-api.sh v1.6.2
set -euo pipefail

VERSION="${1:?usage: vendor-gateway-api.sh <tag, e.g. v1.6.2>}"
if [[ ! "${VERSION}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "error: '${VERSION}' is not a release tag like v1.6.2" >&2
  exit 2
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="${REPO_ROOT}/terraform/gateway-api/standard-install-${VERSION}.yaml"
URL="https://github.com/kubernetes-sigs/gateway-api/releases/download/${VERSION}/standard-install.yaml"

TMP="$(mktemp)"
trap 'rm -f "${TMP}"' EXIT

curl --fail --silent --show-error --location --output "${TMP}" "${URL}"

# A wrong tag can still return a page; insist on the bundle's own markers.
if ! grep -q '^kind: CustomResourceDefinition$' "${TMP}" ||
  ! grep -q "gateway.networking.k8s.io/bundle-version: ${VERSION}" "${TMP}"; then
  echo "error: ${URL} is not the ${VERSION} standard bundle" >&2
  exit 1
fi

mkdir -p "$(dirname "${DEST}")"
mv "${TMP}" "${DEST}"
trap - EXIT

echo "wrote ${DEST}"
echo "objects: $(grep -c '^kind: ' "${DEST}")"
if command -v sha256sum >/dev/null 2>&1; then
  sha256sum "${DEST}"
else
  shasum -a 256 "${DEST}"
fi
echo "next: set gateway_api_version=${VERSION}, read the diff for removed documents, run terraform plan."
