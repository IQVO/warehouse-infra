#!/usr/bin/env python3
"""The gateway split of helm-values/_platform.yaml (ADR 0014 A2A, ADR 0015 MCP).

Kong serves REST only (the API routes and the analytics reports routes); the
Agent Router (Envoy Gateway) serves every MCP and A2A route. Terraform checks the
same facts as lifecycle preconditions on each Gateway, but `terraform validate`
never evaluates them, so this test is what fails a PR that moves a route family
to the wrong edge.
"""
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[2]
PLATFORM = yaml.safe_load((ROOT / "helm-values" / "_platform.yaml").read_text())

KONG = [{"name": "warehouse-gateway", "namespace": "kong", "sectionName": "http"}]
AGENT_ROUTER = [{"name": "agent-router", "namespace": "envoy-gateway-system", "sectionName": "http"}]


class PlatformGatewaySplitTest(unittest.TestCase):
    def test_rest_routes_attach_to_kong(self):
        self.assertEqual(PLATFORM["gatewayApi"]["parentRefs"], KONG)
        self.assertEqual(PLATFORM["analytics"]["reports"]["route"]["parentRefs"], KONG)

    def test_mcp_and_a2a_routes_attach_to_the_agent_router(self):
        self.assertEqual(PLATFORM["mcp"]["route"]["parentRefs"], AGENT_ROUTER)
        self.assertEqual(PLATFORM["a2a"]["route"]["parentRefs"], AGENT_ROUTER)

    def test_no_application_overrides_the_split(self):
        # An app file may not re-attach a route family to the other edge: the
        # anchors above move the whole fleet at once.
        for values in sorted((ROOT / "helm-values").glob("*.yaml")):
            if values.name.startswith("_"):
                continue
            parsed = yaml.safe_load(values.read_text()) or {}
            for family in ("mcp", "a2a"):
                route = (parsed.get(family) or {}).get("route") or {}
                self.assertNotIn(
                    "parentRefs", route, f"{values.name}: {family}.route.parentRefs must come from _platform.yaml"
                )
            reports = ((parsed.get("analytics") or {}).get("reports") or {}).get("route") or {}
            self.assertNotIn("parentRefs", reports, f"{values.name}: reports route parentRefs must come from _platform.yaml")
            self.assertNotIn(
                "parentRefs", parsed.get("gatewayApi") or {},
                f"{values.name}: gatewayApi.parentRefs must come from _platform.yaml",
            )


if __name__ == "__main__":
    unittest.main()
