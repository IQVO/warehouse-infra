#!/usr/bin/env python3
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
CI_WORKFLOW = ROOT / ".github" / "workflows" / "ci.yml"


class FastCiTest(unittest.TestCase):
    def test_fast_ci_runs_acceptance_unit_and_mcp_probe_tests(self):
        source = CI_WORKFLOW.read_text()
        self.assertIn("python3 -m unittest discover -s scripts/tests -v", source)
        self.assertIn("scripts/mcp-probe", source)


if __name__ == "__main__":
    unittest.main()
