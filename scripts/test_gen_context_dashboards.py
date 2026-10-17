#!/usr/bin/env python3
"""Sensor for the generated Grafana dashboards (gap fix D20) and alert rules
(gap fix D30).

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
- Alert rules (terraform/alerting/warehouse-alert-rules.json): every context
  has a Kong 5xx rule and a pod-restart rule, an outbox-lag rule exactly when
  it exports a gauge, and every rule names its context's runbook
  (https://iqvo.github.io/<context>/docs/operations/runbook, or the GitHub
  file for a context without a docs site). PromQL validity and firing
  behaviour are promtool's job: make alert-rules-check. SLO burn-rate rules
  (gaps SLO-1/SLO-2): every context has the four WarehouseApi{Availability,
  Latency}Burn{Fast,Slow} alerts in group warehouse-<key>-slo with the decided
  thresholds, and the latency rule counts on a bucket Kong really exports.
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
ALERT_RULES = os.path.join(REPO_ROOT, "terraform", "alerting", "warehouse-alert-rules.json")


def load_generator():
    path = os.path.join(REPO_ROOT, "scripts", "gen-context-dashboards.py")
    spec = importlib.util.spec_from_file_location("gen_context_dashboards", path)
    assert spec is not None and spec.loader is not None, path
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


GEN = load_generator()


def committed_json_files():
    out = [os.path.relpath(ALERT_RULES, REPO_ROOT)]
    for root, _, files in os.walk(DASHBOARDS):
        for name in files:
            if name.endswith(".json"):
                out.append(os.path.relpath(os.path.join(root, name), REPO_ROOT))
    return sorted(out)


def committed_alert_rules():
    with open(ALERT_RULES) as f:
        return json.load(f)


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
            if rel == os.path.relpath(ALERT_RULES, REPO_ROOT):
                continue
            with open(os.path.join(REPO_ROOT, rel)) as f:
                dashboard = json.load(f)
            for title, expr in prometheus_exprs(dashboard):
                self.assertNotIn("\\", expr, f"{rel} / {title}: PromQL rejects backslash escapes like \\. -- use [.]")
        for group in committed_alert_rules()["groups"]:
            for rule in group["rules"]:
                self.assertNotIn("\\", rule["expr"], f"{group['name']} / {rule['alert']}")

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



class AlertRulesTest(unittest.TestCase):
    def rules_by_context(self):
        out = {}
        for group in committed_alert_rules()["groups"]:
            for rule in group["rules"]:
                out.setdefault(rule["labels"]["context"], []).append(rule)
        return out

    def test_every_context_has_kong_5xx_and_restart_rules_and_outbox_where_a_gauge_exists(self):
        by_context = self.rules_by_context()
        slo = [
            "WarehouseApiAvailabilityBurnFast",
            "WarehouseApiAvailabilityBurnSlow",
            "WarehouseApiLatencyBurnFast",
            "WarehouseApiLatencyBurnSlow",
        ]
        for ctx in GEN.CONTEXTS:
            names = sorted(r["alert"] for r in by_context.get(ctx["key"], []))
            expected = ["WarehouseKong5xxRatioHigh", "WarehousePodRestarting", *slo]
            if ctx.get("outbox_lag_metric"):
                expected.append("WarehouseOutboxLagHigh")
            self.assertEqual(names, sorted(expected), ctx["key"])

    def test_slo_burn_rules_live_in_a_sibling_group_with_the_decided_thresholds(self):
        groups = {g["name"]: g["rules"] for g in committed_alert_rules()["groups"]}
        for ctx in GEN.CONTEXTS:
            rules = {r["alert"]: r for r in groups[f"warehouse-{ctx['key']}-slo"]}
            self.assertEqual(
                sorted(rules),
                [
                    "WarehouseApiAvailabilityBurnFast",
                    "WarehouseApiAvailabilityBurnSlow",
                    "WarehouseApiLatencyBurnFast",
                    "WarehouseApiLatencyBurnSlow",
                ],
                ctx["key"],
            )
            for name, rule in rules.items():
                fast = name.endswith("Fast")
                self.assertEqual(rule["labels"], {"context": ctx["key"], "severity": "critical" if fast else "warning"}, name)
                self.assertEqual(rule["for"], "2m" if fast else "15m", name)
                long_w, short_w = ("1h", "5m") if fast else ("6h", "30m")
                burn = "14.4" if fast else "3"
                self.assertEqual(rule["expr"].count(f">= {burn})"), 2, name)
                self.assertIn(f"[{long_w}]", rule["expr"], name)
                self.assertIn(f"[{short_w}]", rule["expr"], name)
                # traffic floor on the long window
                self.assertRegex(rule["expr"], rf"increase\(kong_\w+\{{[^}}]*\}}\[{long_w}\]\)\) >= 30$", name)
                for annotation in ("summary", "description", "runbook_url", "dashboard_url"):
                    self.assertTrue(rule["annotations"][annotation], f"{name} / {annotation}")
                self.assertIn("one-day", rule["annotations"]["description"], name)
                self.assertIn(GEN.kong_service_regex(ctx["key"]), rule["expr"], name)

    def test_slo_burn_rules_use_the_budget_of_their_slo(self):
        # availability 99% -> budget 0.01 over the 5xx ratio; latency 95% -> 0.05.
        for ctx in GEN.CONTEXTS:
            rules = {r["alert"]: r for r in self.rules_by_context()[ctx["key"]]}
            for name in ("WarehouseApiAvailabilityBurnFast", "WarehouseApiAvailabilityBurnSlow"):
                expr = rules[name]["expr"]
                self.assertIn("kong_http_requests_total", expr)
                self.assertIn('code=~"5.."', expr)
                self.assertIn("/ 0.01 >=", expr)
            for name in ("WarehouseApiLatencyBurnFast", "WarehouseApiLatencyBurnSlow"):
                expr = rules[name]["expr"]
                self.assertIn("kong_upstream_latency_ms_bucket", expr)
                self.assertIn("kong_upstream_latency_ms_count", expr)
                self.assertIn("/ 0.05 >=", expr)

    def test_latency_slo_counts_on_a_bucket_kong_really_exports(self):
        # Kong 3.9 in this cluster exports NO le="500" bucket (verified on its
        # Prometheus: 25, 50, 80, 100, 250, 400, 700, 1000, ...; label spelled
        # "400.0"). A rule on le="500" would never match and never fire.
        self.assertEqual(GEN.LATENCY_SLO_BUCKET_LE, "400.0")
        for rule in (r for rules in self.rules_by_context().values() for r in rules if r["alert"].startswith("WarehouseApiLatencyBurn")):
            self.assertIn('le="400.0"', rule["expr"])
            self.assertNotIn('le="500', rule["expr"])
            self.assertIn("no 500 ms bucket", rule["annotations"]["description"])
            self.assertIn("le=400.0", rule["annotations"]["description"])

    def test_every_rule_names_its_contexts_runbook(self):
        for context, rules in self.rules_by_context().items():
            for rule in rules:
                url = rule["annotations"]["runbook_url"]
                self.assertIn(
                    url,
                    (
                        f"https://iqvo.github.io/{context}/docs/operations/runbook",
                        f"https://github.com/IQVO/{context}/blob/develop/docs/operations/runbook.md",
                    ),
                    f"{context} / {rule['alert']}",
                )

    def test_kong_rule_reads_kong_and_outbox_rule_reads_the_contexts_gauge(self):
        for ctx in GEN.CONTEXTS:
            rules = {r["alert"]: r for r in self.rules_by_context()[ctx["key"]]}
            self.assertIn("kong_http_requests_total", rules["WarehouseKong5xxRatioHigh"]["expr"])
            self.assertIn(GEN.kong_service_regex(ctx["key"]), rules["WarehouseKong5xxRatioHigh"]["expr"])
            if ctx.get("outbox_lag_metric"):
                self.assertIn(ctx["outbox_lag_metric"], rules["WarehouseOutboxLagHigh"]["expr"])

    def test_pod_regexes_do_not_overlap_between_contexts(self):
        keys = [c["key"] for c in GEN.CONTEXTS]
        for key in keys:
            regex = re.compile(GEN.pod_regex(key))
            for other in keys:
                if other != key:
                    self.assertIsNone(regex.fullmatch(f"{other}-6c8d7f5b9-k4l2m"), f"{key} pod regex matches {other}'s pods")
            self.assertTrue(regex.fullmatch(f"{key}-mcp-6c8d7f5b9-k4l2m"))


if __name__ == "__main__":
    sys.exit(0 if unittest.main(exit=False, verbosity=2).result.wasSuccessful() else 1)
