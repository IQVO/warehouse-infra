# Makefile — the local quality gate for warehouse-infra.
#
# Every target here mirrors a job in .github/workflows/ci.yml — terraform
# fmt/validate, helm lint, shellcheck, and the chart-selector conformance
# check are all CI-enforced, not just documented convention.

TF_DIR := terraform

# The ten Helm charts this repo deploys, taken directly from
# terraform/locals.tf's local.services chart_path values plus
# ops-agent.tf's local.ops_agent_chart_path and warehouse-console's own
# chart (frontends.tf). Keep this list in sync with those files — it is
# not auto-discovered.
CHARTS := \
	../inventory-storage/charts/inventory-storage \
	../wes-work-planning/charts/wes-work-planning \
	../workforce-management/charts/workforce-management \
	../fulfillment-execution/charts/fulfillment-execution \
	../order-management/charts/order-management \
	../facility-layout/charts/facility-layout \
	../labor-performance/charts/labor-performance \
	../process-path-management/charts/process-path-management \
	../warehouse-ops-agent/charts/warehouse-ops-agent \
	../warehouse-console/charts/warehouse-console

.PHONY: help tf-fmt-check tf-validate helm-lint shellcheck chart-selector-check check check-all

help:
	@echo "warehouse-infra — local quality gate (no CI workflow yet; this IS the gate)"
	@echo ""
	@echo "  help            Print this list of targets (default target)"
	@echo "  tf-fmt-check    terraform fmt -check -recursive -diff (from $(TF_DIR)/)"
	@echo "  tf-validate     terraform init -backend=false + terraform validate"
	@echo "  helm-lint       helm lint on every chart in \$$(CHARTS) — workforce-management"
	@echo "                  needs a dummy database.url, wired in below"
	@echo "  shellcheck      shellcheck --severity=warning on scripts/*.sh"
	@echo "  chart-selector-check  render every chart with all components enabled,"
	@echo "                  assert every Service selects exactly one Deployment"
	@echo "                  (scripts/check-chart-selectors.py; needs PyYAML)"
	@echo ""
	@echo "  check           FAST bundle: tf-fmt-check tf-validate helm-lint shellcheck chart-selector-check"
	@echo "  check-all       alias for check — no deeper local gate exists yet"
	@echo "                  (see scripts/test-exposure-policy.sh and smoke-test.sh for"
	@echo "                  cluster-dependent checks that need a live kind cluster —"
	@echo "                  run those by hand after 'up.sh', not part of this gate)"

tf-fmt-check:
	cd $(TF_DIR) && terraform fmt -check -recursive -diff

tf-validate:
	cd $(TF_DIR) && terraform init -backend=false -input=false >/dev/null && terraform validate

helm-lint:
	@if ! command -v helm >/dev/null 2>&1; then \
		echo "helm is not installed."; \
		exit 1; \
	fi
	@for c in $(CHARTS); do \
		echo "==> $$c"; \
		if [ "$$(basename $$c)" = "workforce-management" ]; then \
			helm lint "$$c" --set database.url=postgres://u:p@example.invalid:5432/db || exit 1; \
		else \
			helm lint "$$c" || exit 1; \
		fi; \
	done

shellcheck:
	@if ! command -v shellcheck >/dev/null 2>&1; then \
		echo "shellcheck is not installed."; \
		echo "install it with: brew install shellcheck"; \
		exit 1; \
	fi
	shellcheck --severity=warning scripts/*.sh

chart-selector-check:
	@if ! command -v helm >/dev/null 2>&1; then \
		echo "helm is not installed."; \
		exit 1; \
	fi
	@python3 -c "import yaml" 2>/dev/null || { \
		echo "PyYAML is not installed."; \
		echo "install it with: pip3 install pyyaml (or: python3 -m pip install --user pyyaml)"; \
		exit 1; \
	}
	cd $(TF_DIR) && python3 ../scripts/check-chart-selectors.py

# The fast self-correction loop: run this after every change, before committing.
check: tf-fmt-check tf-validate helm-lint shellcheck chart-selector-check

# No deeper local gate exists yet — see the help text above for the
# cluster-dependent scripts that are NOT part of this target.
check-all: check
