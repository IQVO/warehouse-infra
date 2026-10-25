#!/usr/bin/env python3
import importlib.util
import json
import subprocess
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "write_fleet_shas.py"


def load_module():
    spec = importlib.util.spec_from_file_location("write_fleet_shas", SCRIPT)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load {SCRIPT}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def make_repo(path: Path) -> str:
    path.mkdir()
    subprocess.run(["git", "init", "-q", "-b", "develop"], cwd=path, check=True)
    subprocess.run(["git", "config", "user.email", "test@example.invalid"], cwd=path, check=True)
    subprocess.run(["git", "config", "user.name", "Test"], cwd=path, check=True)
    (path / "README.md").write_text(path.name)
    subprocess.run(["git", "add", "README.md"], cwd=path, check=True)
    subprocess.run(["git", "commit", "-q", "-m", "fixture"], cwd=path, check=True)
    return subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=path, text=True).strip()


class FleetManifestTest(unittest.TestCase):
    def test_records_exact_full_shas_for_every_requested_repo(self):
        module = load_module()
        with tempfile.TemporaryDirectory() as directory:
            workspace = Path(directory)
            expected = {name: make_repo(workspace / name) for name in ("warehouse-infra", "order-management")}

            manifest = module.build_manifest(workspace, tuple(expected))

        self.assertEqual(expected, {row["repository"]: row["sha"] for row in manifest["repositories"]})
        self.assertEqual(40, len(manifest["repositories"][0]["sha"]))

    def test_exact_expected_snapshot_rejects_missing_extra_or_stale_shas(self):
        module = load_module()
        with tempfile.TemporaryDirectory() as directory:
            workspace = Path(directory)
            expected = {
                name: make_repo(workspace / name)
                for name in ("warehouse-infra", "order-management")
            }
            manifest = module.build_manifest(workspace, tuple(expected))

        self.assertEqual([], module.snapshot_errors(manifest, expected))
        self.assertIn(
            "missing expected repository order-management",
            " ".join(module.snapshot_errors(manifest, {"warehouse-infra": expected["warehouse-infra"]})),
        )
        stale = dict(expected)
        stale["order-management"] = "0" * 40
        self.assertIn("SHA mismatch", " ".join(module.snapshot_errors(manifest, stale)))

    def test_clean_gate_rejects_dirty_checkout(self):
        module = load_module()
        manifest = {
            "repositories": [
                {"repository": "warehouse-infra", "sha": "1" * 40, "dirty": True}
            ]
        }

        self.assertEqual(
            ["dirty repository checkout: warehouse-infra"],
            module.clean_checkout_errors(manifest),
        )


if __name__ == "__main__":
    unittest.main()
