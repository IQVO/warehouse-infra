#!/usr/bin/env python3
import subprocess
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "run-cluster-acceptance.sh"


class ClusterAcceptanceSafetyTest(unittest.TestCase):
    def test_there_is_no_provisioning_mode(self):
        result = subprocess.run(["bash", str(SCRIPT), "--provision"], cwd=ROOT, capture_output=True, text=True)
        self.assertEqual(2, result.returncode)
        self.assertIn("there is no provisioning mode", result.stderr)

    def test_orchestrator_only_reads_the_cluster(self):
        source = SCRIPT.read_text()
        for forbidden in (
            "terraform destroy",
            "terraform apply",
            "terraform -chdir",
            "kind ",
            "kubectl --context \"${CONTEXT}\" delete",
            "scripts/up.sh",
            "scripts/down.sh",
            "state rm",
        ):
            self.assertNotIn(forbidden, source.replace("kind is banned", ""), forbidden)
        self.assertIn("fleet-shas.json", source)
        self.assertIn("collect_diagnostics", source)
        self.assertIn('bash "${INFRA_DIR}/scripts/run-mcp-acceptance.sh"', source)
        self.assertIn('helm --kube-context "${CONTEXT}" list -A -o json', source)
        self.assertIn("EXPECTED_FLEET_SHAS", source)
        self.assertNotIn("Authorization:", source)

    def test_no_workflow_provisions_a_cluster(self):
        # kind is banned (ADR 0011): no workflow may provision a cluster.
        self.assertFalse((ROOT / ".github" / "workflows" / "cluster-acceptance.yml").exists())
        for workflow in (ROOT / ".github" / "workflows").glob("*.yml"):
            source = workflow.read_text()
            self.assertNotIn("kind-action", source, workflow.name)
            self.assertNotIn("kind create cluster", source, workflow.name)


if __name__ == "__main__":
    unittest.main()
