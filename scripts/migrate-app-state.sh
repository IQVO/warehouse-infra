#!/usr/bin/env bash
# Moves one application's resources out of the shared terraform/ state and
# into its own terraform/20-apps workspace (ADR 0007 step 2, ADR 0003
# decision 6). Implements ADR 0007 decision 4: backs up first, prints the
# resource count before and after, and refuses to run without an explicit
# go-ahead. Run ONE application at a time; re-run for the next one.
#
# Prerequisites, in order:
#   1. This PR is merged to develop, and this checkout is at or after that
#      merge (ADR 0007 consequence: an older checkout would plan to CREATE
#      what this script already moved).
#   2. terraform/ has been applied at least once since the merge, so its new
#      `platform` output actually exists in the live state -- terraform/20-apps
#      reads it via terraform_remote_state and cannot plan without it.
#   3. The maintainer has said go-ahead for THIS run. Pass --go-ahead or the
#      script only prints what it would do.
#
# Usage:
#   scripts/migrate-app-state.sh <app-name> [--go-ahead]
#
# <app-name> must be a key in terraform/apps.yaml. Run with no --go-ahead
# first to see the plan; re-run with --go-ahead once you've read it.
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "usage: $0 <app-name> [--go-ahead]" >&2
  exit 1
fi

app="$1"
go_ahead=false
if [[ "${2:-}" == "--go-ahead" ]]; then
  go_ahead=true
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tf_dir="$repo_root/terraform"
apps_dir="$tf_dir/20-apps"
src_addr="module.application[\"${app}\"]"
dst_addr="module.application"

if ! command -v terraform >/dev/null 2>&1; then
  echo "terraform not found on PATH" >&2
  exit 1
fi

if ! python3 -c "
import sys, yaml
with open('$tf_dir/apps.yaml') as f:
    reg = yaml.safe_load(f)['applications']
sys.exit(0 if '$app' in reg else 1)
" 2>/dev/null; then
  echo "\"$app\" is not a key in terraform/apps.yaml -- check the spelling." >&2
  exit 1
fi

backup_dir="$repo_root/.state-migration-backups"
mkdir -p "$backup_dir"
stamp="$(date -u +%Y%m%dT%H%M%SZ)"
backup_file="$backup_dir/terraform.tfstate.pre-migrate.${app}.${stamp}.json"

echo "== backing up terraform/'s state to $backup_file =="
(cd "$tf_dir" && terraform state pull) >"$backup_file"

before_root_count="$(cd "$tf_dir" && terraform state list | grep -Fc "$src_addr" || true)"
echo "== $before_root_count resource(s) at $src_addr in terraform/ =="
if [[ "$before_root_count" -eq 0 ]]; then
  echo "Nothing to move -- \"$app\" already migrated, or apps.yaml has it but applications.tf never created it. Stopping." >&2
  exit 1
fi

if [[ "$go_ahead" != true ]]; then
  echo
  echo "DRY RUN -- no state was changed. The move:"
  (cd "$tf_dir" && terraform state list | grep -F "$src_addr")
  echo
  echo "  terraform/:        $src_addr  (every line above)"
  echo "  terraform/20-apps:  -> $dst_addr  (workspace \"$app\")"
  echo
  echo "Re-run with --go-ahead once a human has reviewed this and said go."
  exit 0
fi

echo "== creating the \"$app\" workspace in terraform/20-apps (if missing) =="
(cd "$apps_dir" && terraform workspace new "$app" 2>&1) || true

echo "== moving $src_addr -> $dst_addr =="
(
  cd "$tf_dir" && terraform state mv \
    -state-out="$apps_dir/terraform.tfstate.d/${app}/terraform.tfstate" \
    "$src_addr" "$dst_addr"
)

after_root_count="$(cd "$tf_dir" && terraform state list | grep -Fc "$src_addr" || true)"
after_apps_count="$(cd "$apps_dir" && TF_WORKSPACE="$app" terraform state list | grep -Fc "$dst_addr" || true)"

echo
echo "== counts =="
echo "  terraform/        $src_addr : before=$before_root_count after=$after_root_count"
echo "  terraform/20-apps $dst_addr : after=$after_apps_count"

if [[ "$after_root_count" -ne 0 || "$after_apps_count" -eq 0 ]]; then
  echo "UNEXPECTED COUNTS -- stop and inspect before moving another application. Backup: $backup_file" >&2
  exit 1
fi

echo
echo "== verifying: both layers must plan \"No changes\" (ADR 0007 decision 4) =="
echo "-- terraform/ --"
(cd "$tf_dir" && terraform plan -refresh=false -var-file=terraform.tfvars -no-color | tail -5)
echo "-- terraform/20-apps (workspace $app) --"
(cd "$apps_dir" && TF_WORKSPACE="$app" terraform plan -refresh=false -var-file=../terraform.tfvars -no-color | tail -5)

echo
echo "Done. If either plan above is not \"No changes\", stop and restore from $backup_file before moving the next application."
