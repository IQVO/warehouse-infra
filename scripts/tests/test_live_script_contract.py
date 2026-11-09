#!/usr/bin/env python3
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]


class LiveScriptContractTest(unittest.TestCase):
    def test_smoke_uses_source_inventory_and_api_prefix(self):
        source = (ROOT / "scripts" / "smoke-test.sh").read_text()
        self.assertIn("exposure_inventory.py --kind apis", source)
        # the route is the one the context's own values file declares
        self.assertIn("${route}/healthz", source)
        self.assertIn("gatewayApi", source)
        self.assertNotIn("for svc in inventory-storage", source)

    def test_policy_uses_source_inventory_and_resolves_every_remote_chunk(self):
        source = (ROOT / "scripts" / "test-exposure-policy.sh").read_text()
        self.assertIn("exposure_inventory.py --kind remotes", source)
        self.assertIn('exposure_properties.py" chunk', source)
        self.assertIn("selector isolation", source)
        self.assertNotIn("for ctx in order-management inventory-storage", source)

    def test_mcp_runner_uses_source_inventory_and_never_auth_headers(self):
        source = (ROOT / "scripts" / "run-mcp-acceptance.sh").read_text()
        self.assertIn("exposure_inventory.py --kind mcps", source)
        self.assertIn("go run ./scripts/mcp-probe", source)
        self.assertNotIn("Authorization", source)
        self.assertNotIn("BEARER", source.upper())

    def test_mcp_conformance_probe_is_opt_in_and_off_the_acceptance_script(self):
        source = (ROOT / "scripts" / "run-mcp-acceptance.sh").read_text()
        self.assertIn('"${MCP_CONFORMANCE:-0}" == "1"', source)
        self.assertIn("scripts/mcp-conformance-2026-07-28.py", source)
        self.assertNotIn("MCP_CONFORMANCE", (ROOT / "scripts" / "run-cluster-acceptance.sh").read_text())


if __name__ == "__main__":
    unittest.main()
