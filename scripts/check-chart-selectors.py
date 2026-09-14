#!/usr/bin/env python3
"""Chart selector conformance check.

Renders every service-owning Helm chart in the fleet with ALL optional
components enabled (analytics/frontend/mcp), then asserts every rendered
Service selects EXACTLY ONE Deployment.

Why this exists: every chart's `<ctx>.selectorLabels` helper originally
emitted only `app.kubernetes.io/name` + `app.kubernetes.io/instance`,
which are IDENTICAL across a service's OLTP/MCP/projector/reports/frontend
pods. The OLTP Service therefore selected ALL of them -- verified live via
`kubectl get endpointslices`, and a real `curl .../healthz` through Kong
was answered by the wrong (reports) pod. Every chart has since had
`app.kubernetes.io/component: <api|mcp|analytics-reports|frontend|...>`
added to each Deployment's selector.matchLabels + pod template labels +
its own Service's selector, but nothing enforced that convention going
forward -- a new component template that forgets the component label
reintroduces the exact same silent-multi-select bug, and it would NOT be
caught by `helm lint` (lint has no opinion on selector cardinality) or by
`helm template` alone (nothing fails, it just renders a Service that
happens to select more than intended).

Run from anywhere; paths below are relative to `terraform/` (this script
lives in `scripts/`, but is invoked via `cd terraform && python3
../scripts/check-chart-selectors.py` from the Makefile / CI job so the
chart paths match `terraform/locals.tf`'s own `../../<repo>/charts/<repo>`
convention).

Exit 0 if every Service selects exactly one Deployment; exit 1 (with the
offending Service(s) named) otherwise.
"""
import subprocess
import sys

import yaml

RELEASE_NAME = "chart-conformance-check"

# Every service-owning chart in the fleet, keyed by its path relative to
# terraform/, with the --set flags needed to render every optional
# component that adds its own Deployment+Service pair. Keep this list in
# sync with terraform/locals.tf's local.services chart_path values plus
# ops-agent.tf/frontends.tf (same discipline the Makefile's CHARTS
# variable already follows) -- it is not auto-discovered.
CHARTS: dict[str, dict[str, str]] = {
    "../../order-management/charts/order-management": {
        "analytics.enabled": "true", "frontend.enabled": "true", "mcp.enabled": "true",
    },
    "../../inventory-storage/charts/inventory-storage": {
        "analytics.enabled": "true", "frontend.enabled": "true", "mcp.enabled": "true",
    },
    "../../wes-work-planning/charts/wes-work-planning": {
        "analytics.enabled": "true", "frontend.enabled": "true", "mcp.enabled": "true",
    },
    "../../fulfillment-execution/charts/fulfillment-execution": {
        "analytics.enabled": "true", "frontend.enabled": "true", "mcp.enabled": "true",
    },
    "../../workforce-management/charts/workforce-management": {
        "analytics.enabled": "true", "frontend.enabled": "true", "mcp.enabled": "true",
        # This chart's templates fail to render at all without a database
        # URL or existingSecret -- see fleet skill note "workforce-management's
        # chart refuses to render without a database URL".
        "database.url": "postgres://u:p@example.invalid:5432/db",
    },
    "../../facility-layout/charts/facility-layout": {
        "analytics.enabled": "true", "frontend.enabled": "true", "mcp.enabled": "true",
    },
    "../../labor-performance/charts/labor-performance": {
        "analytics.enabled": "true", "frontend.enabled": "true", "mcp.enabled": "true",
    },
    "../../process-path-management/charts/process-path-management": {
        "analytics.enabled": "true", "frontend.enabled": "true", "mcp.enabled": "true",
    },
    # Single Deployment/Service each, no optional-component toggles that
    # add another pair -- included for completeness/regression coverage,
    # not because they're currently at risk of this specific bug shape.
    "../../warehouse-ops-agent/charts/warehouse-ops-agent": {},
    "../../warehouse-console/charts/warehouse-console": {},
}


def selector_selects_deployment(selector: dict, deployment: dict) -> bool:
    """True if `selector` (a Service's spec.selector) would route traffic
    to `deployment`'s pods -- i.e. every key in the selector matches that
    Deployment's pod template labels, AND the Deployment's own
    selector.matchLabels is fully satisfied by those same pod labels (a
    Deployment can never actually run pods that don't satisfy its own
    selector, so this is really just confirming label agreement both
    ways)."""
    pod_labels = deployment["spec"]["template"]["metadata"]["labels"]
    match_labels = deployment["spec"]["selector"]["matchLabels"]
    if not all(pod_labels.get(k) == v for k, v in selector.items()):
        return False
    if not all(pod_labels.get(k) == v for k, v in match_labels.items()):
        return False
    return True


def check_chart(chart_path: str, extra_set: dict) -> list[str]:
    """Returns a list of human-readable failure lines for this chart (empty
    list = chart is conformant)."""
    args = ["helm", "template", RELEASE_NAME, chart_path]
    for key, value in extra_set.items():
        args += ["--set", f"{key}={value}"]
    result = subprocess.run(args, capture_output=True, text=True)
    if result.returncode != 0:
        return [f"{chart_path}: helm template failed: {result.stderr.strip()[:500]}"]

    docs = [d for d in yaml.safe_load_all(result.stdout) if d]
    deployments = [d for d in docs if d.get("kind") == "Deployment"]
    services = [d for d in docs if d.get("kind") == "Service"]

    failures = []
    for svc in services:
        selector = (svc.get("spec") or {}).get("selector") or {}
        if not selector:
            continue
        matched = [
            d["metadata"]["name"]
            for d in deployments
            if selector_selects_deployment(selector, d)
        ]
        if len(matched) != 1:
            failures.append(
                f"{chart_path}: Service {svc['metadata']['name']} selects "
                f"{len(matched)} Deployment(s) (want exactly 1): {matched}"
            )
    return failures


def main() -> int:
    all_failures = []
    for chart_path, extra_set in CHARTS.items():
        failures = check_chart(chart_path, extra_set)
        if failures:
            all_failures.extend(failures)
        else:
            print(f"OK   {chart_path}")

    if all_failures:
        print()
        print("FAIL — the following Services do not select exactly one Deployment:")
        for line in all_failures:
            print(f"  {line}")
        return 1

    print()
    print(f"All {len(CHARTS)} charts conformant: every Service selects exactly one Deployment.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
