#!/usr/bin/env bash
# Split the single Terraform state into the three layers of ADR 0007.
#
#   source state (terraform/terraform.tfstate)
#     kind_cluster.warehouse, null_resource.kubeconfig
#                                  -> terraform/00-cluster/terraform.tfstate
#     module.application["<name>"] -> module.application in
#                                      terraform/20-apps/terraform.tfstate.d/<name>/terraform.tfstate
#     everything else              -> terraform/10-platform/terraform.tfstate
#
# This is the recorded `state mv` script ADR 0002 asks for; it replaces the
# per-application scripts/migrate-app-state.sh of ADR 0007 step 2 (ADR 0008).
# It only MOVES addresses between state files; no resource is read, created
# or destroyed. The one rename is the instance key: the shared root keys the
# module by application name, each workspace holds the application unkeyed.
#
# The source state is never modified: the script works on a copy and leaves the
# old file for the operator to rename once the verification plans are clean.
# (Rollback is therefore: delete the three layer states and use the commit
# before the split.) Refuses to run over an existing layer state.
#
# Usage: scripts/migrate-state-to-layers.sh [SOURCE_STATE]
#   SOURCE_STATE defaults to terraform/terraform.tfstate.
#   TF_DIR overrides the terraform directory (default: <repo>/terraform).
#
# Afterwards, in this order (docs/adr/0007-state-split-in-four-steps.md):
#   1. terraform -chdir=terraform/00-cluster  apply -refresh-only   (records outputs)
#   2. terraform -chdir=terraform/10-platform apply -refresh-only   (records outputs)
#   3. make apps-plan                                               (17 x "No changes")
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tf_dir="${TF_DIR:-${repo}/terraform}"
src="${1:-${tf_dir}/terraform.tfstate}"

cluster_state="${tf_dir}/00-cluster/terraform.tfstate"
platform_state="${tf_dir}/10-platform/terraform.tfstate"
apps_dir="${tf_dir}/20-apps/terraform.tfstate.d"

die() { echo "error: $*" >&2; exit 1; }

[[ -f "${src}" ]] || die "source state not found: ${src}"
command -v terraform >/dev/null || die "terraform is not on PATH"
[[ -f "${tf_dir}/apps.yaml" ]] || die "no ${tf_dir}/apps.yaml"
[[ ! -e "${cluster_state}" ]] || die "${cluster_state} already exists; refusing to overwrite"
[[ ! -e "${platform_state}" ]] || die "${platform_state} already exists; refusing to overwrite"
if [[ -d "${apps_dir}" ]] && [[ -n "$(ls -A "${apps_dir}" 2>/dev/null)" ]]; then
  die "${apps_dir} is not empty; refusing to overwrite"
fi
if pgrep -f '^terraform (plan|apply|destroy|state|import)' >/dev/null 2>&1; then
  die "a terraform process is running; wait for it (it may hold the state lock)"
fi

# `terraform state` loads the configuration of the directory it runs in, which
# needs its modules installed; -backend=false because only the local files below
# are involved.
(cd "${tf_dir}/10-platform" && terraform init -backend=false -input=false >/dev/null)
tf() { (cd "${tf_dir}/10-platform" && terraform "$@"); }

# Moves keep no backups: the source is untouched and holds everything.
mv_opts=(-backup=- -backup-out=-)

mkdir -p "${tf_dir}/00-cluster" "${tf_dir}/10-platform" "${apps_dir}"
umask 077
cp "${src}" "${platform_state}"
chmod 600 "${platform_state}"

tf state list -state="${src}" | sort >"${platform_state}.addresses"
total="$(wc -l <"${platform_state}.addresses" | tr -d ' ')"

# 1. The cluster.
for addr in kind_cluster.warehouse null_resource.kubeconfig; do
  grep -qx "${addr}" "${platform_state}.addresses" || die "expected ${addr} in the source state"
  tf state mv "${mv_opts[@]}" -state="${platform_state}" -state-out="${cluster_state}" "${addr}" "${addr}" >/dev/null
done

# 2. One state per application: module.application["<name>"] becomes
#    module.application in the workspace named after it (terraform/20-apps/main.tf).
registry_names="$(grep -E '^  [a-z0-9-]+:[[:space:]]*$' "${tf_dir}/apps.yaml" | tr -d ' :' | sort)"
state_names="$(sed -n 's/^module\.application\["\([^"]*\)"\].*/\1/p' "${platform_state}.addresses" | sort -u)"
[[ "${registry_names}" == "${state_names}" ]] || {
  echo "registry: $(echo "${registry_names}" | tr '\n' ' ')" >&2
  echo "state:    $(echo "${state_names}" | tr '\n' ' ')" >&2
  die "the applications in apps.yaml and in the state differ"
}
while IFS= read -r name; do
  mkdir -p "${apps_dir}/${name}"
  tf state mv "${mv_opts[@]}" -state="${platform_state}" \
    -state-out="${apps_dir}/${name}/terraform.tfstate" \
    "module.application[\"${name}\"]" "module.application" >/dev/null
done <<<"${state_names}"

# The kubeconfig kind exported for the cluster lives next to its layer now.
if [[ -f "${tf_dir}/kubeconfig" && ! -e "${tf_dir}/00-cluster/kubeconfig" ]]; then
  cp "${tf_dir}/kubeconfig" "${tf_dir}/00-cluster/kubeconfig"
  chmod 600 "${tf_dir}/00-cluster/kubeconfig"
fi

# `state mv` writes a timestamped backup of every state it touches whatever
# -backup says; the source is the backup, and each copy holds every secret.
find "${tf_dir}/00-cluster" "${tf_dir}/10-platform" "${apps_dir}" -name 'terraform.tfstate.*.backup' -exec rm -f {} +

# 3. Nothing lost, nothing duplicated.
n_cluster="$(tf state list -state="${cluster_state}" | wc -l | tr -d ' ')"
n_platform="$(tf state list -state="${platform_state}" | wc -l | tr -d ' ')"
n_apps=0
for f in "${apps_dir}"/*/terraform.tfstate; do
  n_apps=$((n_apps + $(tf state list -state="${f}" | wc -l | tr -d ' ')))
done
rm -f "${platform_state}.addresses"
echo "source ${total} = cluster ${n_cluster} + platform ${n_platform} + applications ${n_apps}"
[[ $((n_cluster + n_platform + n_apps)) -eq "${total}" ]] || die "address counts do not add up"

echo "ok. ${src} is untouched; rename it once the verification plans are clean."
