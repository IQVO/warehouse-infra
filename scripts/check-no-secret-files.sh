#!/usr/bin/env bash
# Fail when a tracked file looks like a secret store.
#
# This repository is public. A Terraform plan or state file carries every
# variable and resource attribute in clear text (the Anthropic key, database
# passwords, the cluster's client key), so none may ever be committed.
# terraform/full.tfplan was, on 2026-10-17; this check exists so it is the
# last one. Run by CI (guide-lint job) and `make check-fast`.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

status=0

# Names that hold secrets by construction. terraform.tfvars.example is the
# one allowed tfvars file.
bad_names="$(git ls-files | grep -E '(^|/)(terraform\.tfstate[^/]*|[^/]*\.tfplan|kubeconfig|[^/]*\.pem|id_rsa[^/]*|\.env)$|\.tfstate\.d/|\.tfvars$' || true)"
if [[ -n "${bad_names}" ]]; then
  echo "error: tracked file(s) that hold secrets:" >&2
  while IFS= read -r f; do echo "  ${f}" >&2; done <<<"${bad_names}"
  echo "  FIX: git rm --cached <file>, add it to .gitignore, and rotate every credential it held." >&2
  status=1
fi

# Credentials in tracked text.
if git grep -I -n -E 'sk-ant-[A-Za-z0-9_-]{20,}|BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY' -- . ':!scripts/check-no-secret-files.sh' >/dev/null 2>&1; then
  echo "error: a tracked text file contains an API key or a private key:" >&2
  while IFS= read -r f; do echo "  ${f}" >&2; done < <(git grep -I -l -E 'sk-ant-[A-Za-z0-9_-]{20,}|BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY' -- . ':!scripts/check-no-secret-files.sh')
  echo "  FIX: remove it from the tree, rotate the credential, and see the git-history-hygiene skill." >&2
  status=1
fi

exit "${status}"
