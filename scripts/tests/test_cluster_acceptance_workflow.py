#!/usr/bin/env python3
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = ROOT / ".github" / "workflows" / "cluster-acceptance.yml"
CI_WORKFLOW = ROOT / ".github" / "workflows" / "ci.yml"


class ClusterAcceptanceWorkflowTest(unittest.TestCase):
    def test_workflow_runs_owned_cluster_orchestrator_and_always_uploads_diagnostics(self):
        source = WORKFLOW.read_text()
        self.assertIn("workflow_dispatch:", source)
        self.assertIn("pull_request:", source)
        self.assertIn("scripts/run-cluster-acceptance.sh --provision", source)
        self.assertIn("if: ${{ always() }}", source)
        self.assertIn("artifacts/cluster-acceptance", source)
        self.assertNotIn("scripts/down.sh", source)
        self.assertIn("fleet_shas", source)
        self.assertIn("EXPECTED_FLEET_SHAS", source)
        self.assertIn("setup-go", source)

    def test_workflow_checks_out_every_fleet_repository(self):
        source = WORKFLOW.read_text()
        for repository in (
            "order-management",
            "inventory-storage",
            "wes-work-planning",
            "fulfillment-execution",
            "workforce-management",
            "facility-layout",
            "labor-performance",
            "process-path-management",
            "warehouse-ops-agent",
            "network-fulfillment",
            "warehouse-console",
            "warehouse-ui-kit",
            "warehouse-docs",
            "e2e-tests",
        ):
            self.assertIn(f"claudioed/{repository}", source)

    def test_workflow_checks_out_release_gate_refs_not_ambiguous_branches(self):
        source = WORKFLOW.read_text()
        self.assertIn("fromJSON(inputs.fleet_shas", source)
        self.assertIn("--require-clean", source)
        self.assertIn("--expected-json", source)

    def test_fast_ci_runs_acceptance_unit_and_mcp_probe_tests(self):
        source = CI_WORKFLOW.read_text()
        self.assertIn("python3 -m unittest discover -s scripts/tests -v", source)
        self.assertIn("scripts/mcp-probe", source)


if __name__ == "__main__":
    unittest.main()
