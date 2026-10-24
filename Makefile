# Makefile — the local quality gate for warehouse-infra.
#
# Every target here mirrors a job in .github/workflows/ci.yml — terraform
# fmt/validate, helm lint, shellcheck, and the chart-selector conformance
# check are all CI-enforced, not just documented convention.

TF_DIR := terraform

# The Helm charts this repo deploys: the application registry in
# terraform/apps.yaml (one chart per application). Keep this list in
# sync with it — it is not auto-discovered.
CHARTS := \
	../inventory-storage/charts/inventory-storage \
	../wes-work-planning/charts/wes-work-planning \
	../workforce-management/charts/workforce-management \
	../fulfillment-execution/charts/fulfillment-execution \
	../order-management/charts/order-management \
	../facility-layout/charts/facility-layout \
	../labor-performance/charts/labor-performance \
	../process-path-management/charts/process-path-management \
	../warehouse-planning/charts/warehouse-planning \
	../product-master/charts/product-master \
	../inbound-receiving/charts/inbound-receiving \
	../slotting-optimization/charts/slotting-optimization \
	../pick-face-replenishment/charts/pick-face-replenishment \
	../task-interleaving/charts/task-interleaving \
	../returns-processing/charts/returns-processing \
	../exception-management/charts/exception-management \
	../network-inventory-planning/charts/network-inventory-planning \
	../warehouse-ops-agent/charts/warehouse-ops-agent \
	../warehouse-console/charts/warehouse-console \
	../ecosystem/charts/ecosystem \
	../customer-ordering/charts/customer-ordering \
	../delivery-promise/charts/delivery-promise \
	../last-mile-delivery/charts/last-mile-delivery \
	../linehaul-transportation/charts/linehaul-transportation \
	../node-performance/charts/node-performance \
	../node-topology/charts/node-topology \
	../offer-availability/charts/offer-availability \
	../order-sourcing/charts/order-sourcing \
	../shipping-and-tracking/charts/shipping-and-tracking \
	../vendor-connectivity/charts/vendor-connectivity

.PHONY: help tf-fmt-check tf-validate helm-lint shellcheck chart-selector-check observability-check alert-rules-check seed-scripts-test check check-all

help:
	@echo "warehouse-infra — local quality gate (no CI workflow yet; this IS the gate)"
	@echo ""
	@echo "  help            Print this list of targets (default target)"
	@echo "  tf-fmt-check    terraform fmt -check -recursive -diff (from $(TF_DIR)/)"
	@echo "  tf-validate     terraform init -backend=false + terraform validate, in each of the three layers"
	@echo "  cluster-plan|apply, platform-plan|apply   one layer (ARGS=... goes to terraform)"
	@echo "  app-plan|apply APP=<name>   one application's own state (terraform/20-apps, workspace <name>)"
	@echo "  apps-plan|apply  every application of terraform/apps.yaml, one after the other"
	@echo "  helm-lint       helm lint on every chart in \$$(CHARTS) — workforce-management"
	@echo "                  and warehouse-planning need a dummy database.url, wired in below"
	@echo "  shellcheck      shellcheck --severity=warning on scripts/*.sh"
	@echo "  chart-selector-check  render every chart with all components enabled,"
	@echo "                  assert every Service selects exactly one Deployment"
	@echo "                  (scripts/check-chart-selectors.py; needs PyYAML)"
	@echo "  observability-check  generated Grafana dashboards are current, valid"
	@echo "                  and parse as PromQL-safe (scripts/test_gen_context_dashboards.py)"
	@echo "  alert-rules-check  promtool check + unit tests of the generated alert rules"
	@echo "                  (promtool if installed, else docker $(PROMETHEUS_IMAGE))"
	@echo "  seed-scripts-test  unit tests of the post-deploy seed scripts against a fake"
	@echo "                  facility-layout (scripts/test_seed_transfer_capability.py)"
	@echo ""
	@echo "  check           FAST bundle: tf-fmt-check tf-validate helm-lint shellcheck chart-selector-check observability-check alert-rules-check seed-scripts-test"
	@echo "  check-all       alias for check — no deeper local gate exists yet"
	@echo "                  (see scripts/test-exposure-policy.sh and smoke-test.sh for"
	@echo "                  cluster-dependent checks that need a live kind cluster —"
	@echo "                  run those by hand after 'up.sh', not part of this gate)"

tf-fmt-check:
	cd $(TF_DIR) && terraform fmt -check -recursive -diff

# The three layers of ADR 0007. Validation needs no state: terraform_remote_state
# is only read by plan.
TF_LAYERS := 00-cluster 10-platform 20-apps

tf-validate:
	@for l in $(TF_LAYERS); do \
		echo "==> $$l"; \
		(cd $(TF_DIR)/$$l && terraform init -backend=false -input=false >/dev/null && terraform validate) || exit 1; \
	done

# ---- Running Terraform: one layer, or one application's state (ADR 0003, 0007).
# ARGS is passed to terraform, e.g. `make app-plan APP=product-master ARGS=-refresh=false`.
cluster-plan cluster-apply platform-plan platform-apply: ; @scripts/tf.sh $(word 1,$(subst -, ,$@)) $(word 2,$(subst -, ,$@)) $(ARGS)

app-plan app-apply:
	@test -n "$(APP)" || { echo "usage: make $@ APP=<application of terraform/apps.yaml>"; exit 2; }
	@scripts/tf.sh app $(APP) $(subst app-,,$@) $(ARGS)

apps-plan apps-apply:
	@scripts/tf.sh apps $(subst apps-,,$@) $(ARGS)

helm-lint:
	@if ! command -v helm >/dev/null 2>&1; then \
		echo "helm is not installed."; \
		exit 1; \
	fi
	@for c in $(CHARTS); do \
		echo "==> $$c"; \
		if [ "$$(basename $$c)" = "workforce-management" ]; then \
			helm lint "$$c" --set database.url=postgres://u:p@example.invalid:5432/db || exit 1; \
		elif [ "$$(basename $$c)" = "warehouse-planning" ] || [ "$$(basename $$c)" = "network-inventory-planning" ] || [ "$$(basename $$c)" = "product-master" ] || [ "$$(basename $$c)" = "inbound-receiving" ] || [ "$$(basename $$c)" = "slotting-optimization" ]; then \
			helm lint "$$c" --set database.url=postgres://u@example.invalid:5432/db || exit 1; \
		elif [ "$$(basename $$c)" = "pick-face-replenishment" ] || [ "$$(basename $$c)" = "task-interleaving" ] || [ "$$(basename $$c)" = "returns-processing" ] || [ "$$(basename $$c)" = "exception-management" ]; then \
			helm lint "$$c" --set database.url=postgres://u@example.invalid:5432/db --set kafka.brokers=kafka.example.invalid:9092 || exit 1; \
		elif [ -f "$$c/ci/default-values.yaml" ]; then \
			helm lint "$$c" -f "$$c/ci/default-values.yaml" || exit 1; \
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

# Generated dashboards: committed JSON == generator output, valid JSON, no
# backslash escapes in PromQL, 5xx panels on Kong metrics (gap fix D20).
observability-check:
	python3 scripts/test_gen_context_dashboards.py

# Generated alert rules (gap fix D30): promtool syntax check plus the unit
# tests in terraform/alerting/tests/. The image tag matches the server the
# pinned prometheus chart (var.prometheus_chart_version) deploys.
PROMETHEUS_IMAGE := quay.io/prometheus/prometheus:v3.14.0
ALERTING_DIR := terraform/alerting
alert-rules-check:
	@if command -v promtool >/dev/null 2>&1; then \
		promtool check rules $(ALERTING_DIR)/warehouse-alert-rules.json && \
		promtool test rules $(ALERTING_DIR)/tests/warehouse-alert-rules.test.yml $(ALERTING_DIR)/tests/warehouse-slo-burn-rules.test.yml; \
	else \
		docker run --rm -v "$(CURDIR)/$(ALERTING_DIR):/w:ro" --entrypoint promtool $(PROMETHEUS_IMAGE) check rules /w/warehouse-alert-rules.json && \
		docker run --rm -v "$(CURDIR)/$(ALERTING_DIR):/w:ro" --entrypoint promtool $(PROMETHEUS_IMAGE) test rules /w/tests/warehouse-alert-rules.test.yml /w/tests/warehouse-slo-burn-rules.test.yml; \
	fi

# Post-deploy seed scripts (final-gaps E2): stdlib unit tests against a real
# HTTP fake of facility-layout, so no cluster is needed.
seed-scripts-test:
	python3 scripts/test_seed_transfer_capability.py
	python3 scripts/test_seed_transfer_lanes.py

# The fast self-correction loop: run this after every change, before committing.
check: tf-fmt-check tf-validate helm-lint shellcheck chart-selector-check observability-check alert-rules-check seed-scripts-test

# No deeper local gate exists yet — see the help text above for the
# cluster-dependent scripts that are NOT part of this target.
check-all: check

# --- agent harness (harness-template v3) -----------------------------------
.PHONY: cluster-plan cluster-apply platform-plan platform-apply app-plan app-apply apps-plan apps-apply check-fast secret-files-check guide-lint harness-test
# Fast local gate used by the agent Stop hook (this repo's own quick checks).
check-fast: tf-fmt-check shellcheck chart-selector-check observability-check secret-files-check

secret-files-check: ## no tracked plan, state, tfvars, kubeconfig or API key (the repo is public)
	./scripts/check-no-secret-files.sh

guide-lint: ## lint agent guides: skills load, references resolve, context budget
	python3 scripts/harness/guide_lint.py

harness-test: ## unit-test the agent hooks (pre/post/stop)
	python3 scripts/harness/test_hook.py
	python3 scripts/harness/test_red_issue.py
