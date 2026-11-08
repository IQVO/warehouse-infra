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
# Which environment (ADR 0011):
#
#   scripts/tf.sh [--target <name>] <layer> ...    or   WAREHOUSE_TARGET=<name>
#
#   no target / k3s    the existing k3s cluster of terraform/targets/k3s.tfvars.json
#                      (the default and the only supported environment).
#                      State files terraform.tfstate.k3s, terraform.tfstate.d.k3s/ and
#                      plugin directory .terraform.k3s.
#   kind               REFUSED: kind is banned (ADR 0011). Every deploy targets k3s.
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

# --- target (ADR 0011) -------------------------------------------------------
target="${WAREHOUSE_TARGET:-k3s}"
if [[ "${1:-}" == --target ]]; then
  target="${2:-}"
  shift 2 || true
elif [[ "${1:-}" == --target=* ]]; then
  target="${1#--target=}"
  shift
fi
[[ "${target}" == kind ]] && { echo "error: kind is banned (ADR 0011); every deploy targets k3s" >&2; exit 1; }
[[ -n "${target}" ]] || target=k3s
state_suffix=""
target_vars=""
if [[ -n "${target}" ]]; then
  [[ "${target}" =~ ^[a-z0-9-]+$ ]] || { echo "error: invalid target '${target}'" >&2; exit 1; }
  target_vars="${tf_dir}/targets/${target}.tfvars.json"
  [[ -f "${target_vars}" ]] || { echo "error: no ${target_vars}" >&2; exit 1; }
  state_suffix=".${target}"
  # The layers read each other's state at <layer>/terraform.tfstate<suffix>.
  export TF_VAR_state_suffix="${state_suffix}"
  # A private plugin/working directory per target: `init -reconfigure` of one
  # target must not rewrite the other's.
  export TF_DATA_DIR=".terraform${state_suffix}"
  echo "==> target ${target} (state suffix '${state_suffix}')" >&2

  # The published images are public (the repository is), so no pull Secret is
  # needed. If they ever turn private: WAREHOUSE_GHCR_AUTH=gh takes a read
  # token from the GitHub CLI at run time -- never written to a file -- for the
  # platform layer's `ghcr-pull` Secret; or set TF_VAR_ghcr_token yourself.
  # (Mind the scopes: `gh auth token` is a broad personal token; prefer a
  # fine-grained read:packages one.)
  if [[ -z "${TF_VAR_ghcr_token:-}" && "${WAREHOUSE_GHCR_AUTH:-off}" == gh ]] && command -v gh >/dev/null 2>&1; then
    if token="$(gh auth token 2>/dev/null)" && [[ -n "${token}" ]]; then
      export TF_VAR_ghcr_token="${token}"
      export TF_VAR_ghcr_username="${TF_VAR_ghcr_username:-$(gh api user -q .login 2>/dev/null || true)}"
    fi
  fi
fi

# Commands that take -state, and commands that need no state at all. Anything
# else is refused: it would read the bare terraform.tfstate, which belongs to the
# retired kind environment.
state_cmds=" plan apply destroy refresh import output console state "
plain_cmds=" init validate fmt version providers "

usage() { sed -n '2,/^set -/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//' >&2; exit 2; }
die() { echo "error: $*" >&2; exit 1; }

registry_names() { grep -E '^  [a-z0-9-]+:[[:space:]]*$' "${tf_dir}/apps.yaml" | tr -d ' :'; }

# run_in <dir> <terraform args...>
run_in() {
  local dir="$1"; shift
  local cmd="${1:-}"
  local extra=()
  if [[ -n "${target}" ]]; then
    if [[ "${state_cmds}" != *" ${cmd} "* && "${plain_cmds}" != *" ${cmd} "* ]]; then
      die "'${cmd}' is not supported with --target ${target}: it would use the retired kind state"
    fi
  fi
  case "${cmd}" in
    plan | apply | destroy | refresh | import)
      extra+=(-lock-timeout=300s)
      # `terraform apply <planfile>` refuses variables: the plan already holds them.
      local saved_plan=0 a
      if [[ "${cmd}" == apply ]]; then
        for a in "${@:2}"; do [[ "${a}" != -* ]] && saved_plan=1; done
      fi
      if [[ "${saved_plan}" -eq 0 && -f "${tf_dir}/terraform.tfvars" ]]; then
        extra+=("-var-file=${tf_dir}/terraform.tfvars")
      fi
      # The target's values come last: a later -var-file wins.
      if [[ "${saved_plan}" -eq 0 && -n "${target_vars}" ]]; then
        extra+=("-var-file=${target_vars}")
      fi
      ;;
  esac
  # The target's own state file. A workspace of 20-apps is a directory
  # under terraform.tfstate.d<suffix>.
  local state_args=()
  if [[ -n "${target}" && "${state_cmds}" == *" ${cmd} "* ]]; then
    local state_file="${dir}/terraform.tfstate${state_suffix}"
    if [[ -n "${TF_WORKSPACE:-}" ]]; then
      state_file="${dir}/terraform.tfstate.d${state_suffix}/${TF_WORKSPACE}/terraform.tfstate"
      mkdir -p "$(dirname "${state_file}")"
    fi
    state_args=("-state=${state_file}")
  fi
  # -reconfigure: `make tf-validate` initialises every layer with -backend=false,
  # and a plain init after that asks to migrate state (and fails without a tty).
  # The backend is always the local file, so there is nothing to migrate.
  (cd "${dir}" && terraform init -input=false -reconfigure >/dev/null)
  if [[ "${cmd}" == state ]]; then
    # `terraform state <sub> [-state=...] args`
    (cd "${dir}" && terraform state "${2:-}" ${state_args[@]+"${state_args[@]}"} "${@:3}")
  else
    (cd "${dir}" && terraform "${cmd}" ${extra[@]+"${extra[@]}"} ${state_args[@]+"${state_args[@]}"} "${@:2}")
  fi
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
