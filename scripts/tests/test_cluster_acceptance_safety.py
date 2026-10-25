#!/usr/bin/env python3
import os
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "run-cluster-acceptance.sh"


class ClusterAcceptanceSafetyTest(unittest.TestCase):
    def test_provision_refuses_to_touch_a_preexisting_cluster(self):
        with tempfile.TemporaryDirectory() as directory:
            binary_dir = Path(directory)
            fake_kind = binary_dir / "kind"
            fake_kind.write_text(
                "#!/usr/bin/env bash\n"
                "if [[ \"$1 $2\" == \"get clusters\" ]]; then echo warehouse; exit 0; fi\n"
                "echo unexpected-kind-call >&2; exit 91\n"
            )
            fake_kind.chmod(0o755)
            env = os.environ.copy()
            env["PATH"] = f"{binary_dir}:{env['PATH']}"

            result = subprocess.run(
                ["bash", str(SCRIPT), "--provision"],
                cwd=ROOT,
                env=env,
                capture_output=True,
                text=True,
            )

        self.assertNotEqual(0, result.returncode)
        self.assertIn("refusing to modify pre-existing kind cluster", result.stderr)

    def test_orchestrator_has_no_destroy_path(self):
        source = SCRIPT.read_text()
        self.assertNotIn("terraform destroy", source)
        self.assertNotIn("kind delete cluster", source)
        self.assertIn("fleet-shas.json", source)
        self.assertIn("collect_diagnostics", source)

    def test_existing_cluster_mode_has_no_mutating_acceptance_steps(self):
        source = SCRIPT.read_text()
        self.assertIn('if [[ "${MODE}" == "--provision" ]]', source)
        for command in (
            "terraform -chdir=\"${TF_DIR}\" state rm",
            'bash "${INFRA_DIR}/scripts/up.sh"',
            "terraform -chdir=\"${TF_DIR}\" plan",
        ):
            self.assertEqual(1, source.count(command), command)
        self.assertIn('bash "${INFRA_DIR}/scripts/run-mcp-acceptance.sh"', source)
        self.assertIn('helm --kube-context "${CONTEXT}" list -A -o json', source)
        self.assertIn("EXPECTED_FLEET_SHAS", source)
        self.assertNotIn("Authorization:", source)


if __name__ == "__main__":
    unittest.main()
