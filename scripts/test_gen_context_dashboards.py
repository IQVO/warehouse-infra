#!/usr/bin/env python3
"""Sensor for the generated Grafana dashboards (gap fix D20).

Run from the repo root (stdlib only, no cluster needed):

    python3 scripts/test_gen_context_dashboards.py

What it pins, and why each one exists:

- The committed JSON under terraform/dashboards/ is exactly what
  scripts/gen-context-dashboards.py produces. The JSON is a build output;
  a hand edit or a forgotten re-run is drift that the next regeneration
  silently reverts.
- No generated PromQL expression contains a backslash. Inside a PromQL
  double-quoted string `\\.` is a parse error ("unknown escape sequence"),
  and that is how every Kong panel of every context dashboard was broken
  until D20 without anyone noticing (Grafana just shows an error badge).
- Every context dashboard's 5xx panels read Kong's kong_http_requests_total,
  never an otelchi status-code label: otelchi's http.server.request.duration
  carries no status code in this fleet, so such a panel is always empty.
- workforce-management's labor panel groups by `outcome` (the attribute was
  renamed from workforce.assignment.outcome by that repo's ADR-0015 pass).
- Every context deployed through terraform/locals.tf's local.services map has
  a dashboard, so a newly wired context cannot ship without one.
- process-path-management has an outbox-lag panel on its real gauge.
"""
import importlib.util
import json
import os
import re
import sys
import tempfile
import unittest

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DASHBOARDS = os.path.join(REPO_ROOT, "terraform", "dashboards")
CONTEXT_DIR = os.path.join(DASHBOARDS, "contexts")


def load_generator():
    path = os.path.join(REPO_ROOT, "scripts", "gen-context-dashboards.py")
    spec = importlib.util.spec_from_file_location("gen_context_dashboards", path)
    assert spec is not None and spec.loader is not None, path
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


GEN = load_generator()


def committed_json_files():
    out = []
    for root, _, files in os.walk(DASHBOARDS):
        for name in files:
            if name.endswith(".json"):
                out.append(os.path.relpath(os.path.join(root, name), REPO_ROOT))
    return sorted(out)


def prometheus_exprs(dashboard):
    for panel in dashboard.get("panels", []):
        for target in panel.get("targets", []):
            if target.get("datasource", {}).get("type") == "prometheus":
                yield panel["title"], target["expr"]


def local_services_keys():
    with open(os.path.join(REPO_ROOT, "terraform", "locals.tf")) as f:
        text = f.read()
    start = text.index("  services = {")
    end = text.index("\n  }\n", start)
    return re.findall(r'^    "([a-z0-9-]+)" = \{', text[start:end], re.MULTILINE)


class GeneratedDashboardsTest(unittest.TestCase):
    def test_committed_json_matches_the_generator(self):
        with tempfile.TemporaryDirectory() as tmp:
            # The generator writes only these two directories.
            os.makedirs(os.path.join(tmp, "terraform", "dashboards", "contexts"))
            GEN.main(repo_root=tmp)
            generated = sorted(
                os.path.relpath(os.path.join(root, name), tmp)
                for root, _, files in os.walk(tmp)
                for name in files
            )
            for rel in generated:
                with open(os.path.join(tmp, rel)) as g, open(os.path.join(REPO_ROOT, rel)) as c:
                    self.assertEqual(
                        g.read(), c.read(),
                        f"{rel} differs from the generator output: run python3 scripts/gen-context-dashboards.py",
                    )
        hand_written = {"terraform/dashboards/go-runtime.json"}
        self.assertEqual(
            sorted(set(committed_json_files()) - hand_written), generated,
            "a dashboard JSON exists that the generator does not produce (or the reverse)",
        )

    def test_every_committed_dashboard_is_valid_json(self):
        for rel in committed_json_files():
            with open(os.path.join(REPO_ROOT, rel)) as f:
                json.load(f)

    def test_no_prometheus_expression_contains_a_backslash(self):
        for rel in committed_json_files():
            with open(os.path.join(REPO_ROOT, rel)) as f:
                dashboard = json.load(f)
            for title, expr in prometheus_exprs(dashboard):
                self.assertNotIn("\\", expr, f"{rel} / {title}: PromQL rejects backslash escapes like \\. -- use [.]")

    def test_five_xx_panels_read_kong_not_otelchi_status_codes(self):
        for ctx in GEN.CONTEXTS:
            dashboard = GEN.build_dashboard(ctx)
            exprs = list(prometheus_exprs(dashboard))
            five_xx = [(t, e) for t, e in exprs if '"5.."' in e]
            self.assertGreaterEqual(len(five_xx), 2, f"{ctx['key']}: expected the Kong ratio and per-route 5xx panels")
            for title, expr in five_xx:
                self.assertIn("kong_http_requests_total", expr, f"{ctx['key']} / {title}")
            for title, expr in exprs:
                self.assertNotRegex(expr, r"http_(response_)?status_code", f"{ctx['key']} / {title}: otelchi records no status code")

    def test_kong_regex_covers_api_mcp_and_reports_routes(self):
        regex = re.compile(GEN.kong_service_regex("order-management"))
        for label in (
            "httproute.warehouse-systems.order-management.0",
            "httproute.warehouse-systems.order-management-mcp.0",
            "httproute.warehouse-systems.order-management-reports.0",
        ):
            self.assertTrue(regex.fullmatch(label), label)
        self.assertIsNone(regex.fullmatch("httproute.warehouse-systems.order-managementx.0"))

    def test_workforce_labor_panel_groups_by_outcome(self):
        ctx = next(c for c in GEN.CONTEXTS if c["key"] == "workforce-management")
        exprs = [e for _, e in prometheus_exprs(GEN.build_dashboard(ctx)) if "workforce_labor_assignments_total" in e]
        self.assertEqual(exprs, ["sum by (outcome) (rate(workforce_labor_assignments_total[5m]))"])

    def test_every_deployed_context_has_a_dashboard(self):
        keys = {c["key"] for c in GEN.CONTEXTS}
        for name in local_services_keys():
            self.assertIn(name, keys, f"{name} is in local.services but has no CONTEXTS entry")
        self.assertIn("slotting-optimization", local_services_keys())

    def test_process_path_management_has_an_outbox_lag_panel(self):
        ctx = next(c for c in GEN.CONTEXTS if c["key"] == "process-path-management")
        exprs = [e for _, e in prometheus_exprs(GEN.build_dashboard(ctx))]
        self.assertTrue(any("process_path_management_outbox_lag_seconds" in e for e in exprs))


if __name__ == "__main__":
    sys.exit(0 if unittest.main(exit=False, verbosity=2).result.wasSuccessful() else 1)
