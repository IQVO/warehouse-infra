#!/usr/bin/env bash
# Run Terraform in one layer, or in one application's workspace (ADR 0007).
#
#   scripts/tf.sh cluster  <terraform args...>    terraform/00-cluster
#   scripts/tf.sh platform <terraform args...>    terraform/10-platform
#   scripts/tf.sh app <name> <terraform args...>  terraform/20-apps, workspace <name>
#   scripts/tf.sh apps <terraform args...>        every application of apps.yaml, one after the other
#
#   scripts/tf.sh app inventory-storage plan
#   scripts/tf.sh apps apply -auto-approve
#   scripts/tf.sh platform output -raw kong_proxy_url
#
# What it adds to a bare `terraform`:
#  - terraform/terraform.tfvars is passed to plan/apply/destroy/refresh as
#    -var-file, so every layer sees the same values;
#  - the workspace is chosen with TF_WORKSPACE for this command only, never with
#    `terraform workspace select`, whose choice lives in a file two sessions
#    would share (ADR 0003 D2);
#  - the application name is checked against terraform/apps.yaml first, because
#    TF_WORKSPACE would otherwise create a workspace for a typo;
#  - plan/apply/destroy get -lock-timeout=300s, so a second session queues
#    behind the first instead of failing.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tf_dir="${repo}/terraform"

usage() { sed -n '2,/^set -/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//' >&2; exit 2; }
die() { echo "error: $*" >&2; exit 1; }

registry_names() { grep -E '^  [a-z0-9-]+:[[:space:]]*$' "${tf_dir}/apps.yaml" | tr -d ' :'; }

# run_in <dir> <terraform args...>
run_in() {
  local dir="$1"; shift
  local cmd="${1:-}"
  local extra=()
  case "${cmd}" in
    plan | apply | destroy | refresh | import)
      extra+=(-lock-timeout=300s)
      [[ -f "${tf_dir}/terraform.tfvars" ]] && extra+=("-var-file=${tf_dir}/terraform.tfvars")
      ;;
  esac
  # -reconfigure: `make tf-validate` initialises every layer with -backend=false,
  # and a plain init after that asks to migrate state (and fails without a tty).
  # The backend is always the local file, so there is nothing to migrate.
  (cd "${dir}" && terraform init -input=false -reconfigure >/dev/null)
  (cd "${dir}" && terraform "${cmd}" ${extra[@]+"${extra[@]}"} "${@:2}")
}

# run_app <name> <terraform args...>
run_app() {
  local name="$1"; shift
  registry_names | grep -qx -- "${name}" || die "'${name}' is not an application of terraform/apps.yaml"
  echo "==> ${name}" >&2
  TF_WORKSPACE="${name}" run_in "${tf_dir}/20-apps" "$@"
}

[[ $# -ge 1 ]] || usage
target="$1"; shift
case "${target}" in
  cluster) [[ $# -ge 1 ]] || usage; run_in "${tf_dir}/00-cluster" "$@" ;;
  platform) [[ $# -ge 1 ]] || usage; run_in "${tf_dir}/10-platform" "$@" ;;
  app)
    [[ $# -ge 2 ]] || usage
    name="$1"; shift
    run_app "${name}" "$@"
    ;;
  apps)
    [[ $# -ge 1 ]] || usage
    rc=0
    while IFS= read -r name; do
      run_app "${name}" "$@" || { rc=1; echo "!! ${name} failed" >&2; }
    done < <(registry_names)
    exit "${rc}"
    ;;
  *) usage ;;
esac
