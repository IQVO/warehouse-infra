#!/usr/bin/env python3
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]


class LiveScriptContractTest(unittest.TestCase):
    def test_smoke_uses_source_inventory_and_api_prefix(self):
        source = (ROOT / "scripts" / "smoke-test.sh").read_text()
        self.assertIn("exposure_inventory.py --kind apis", source)
        self.assertIn("/api/${ctx}/healthz", source)
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


if __name__ == "__main__":
    unittest.main()
