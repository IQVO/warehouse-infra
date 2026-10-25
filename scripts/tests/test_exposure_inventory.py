#!/usr/bin/env python3
import importlib.util
import tempfile
import textwrap
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "exposure_inventory.py"
CORE = (
    "order-management",
    "inventory-storage",
    "wes-work-planning",
    "fulfillment-execution",
)


def load_module():
    spec = importlib.util.spec_from_file_location("exposure_inventory", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


def write_fixture(root: Path) -> None:
    """The LAYERED layout: terraform/apps.yaml registry + helm-values/."""
    (root / "terraform").mkdir()
    (root / "terraform" / "apps.yaml").write_text(
        "applications:\n"
        + "".join(
            f"""
  {name}:
    kind: service
    database: true
    frontend_remote: {name}_mfe
"""
            for name in CORE
        )
        + """
  network-fulfillment:
    kind: other
    repo_owner: IQVO
    database: true
  warehouse-console:
    kind: other
    deploy_with: frontends
    build_image: false
    site: true
"""
    )
    values = root / "helm-values"
    values.mkdir()
    (values / "_platform.yaml").write_text("kafka:\n  brokers: kafka.example.invalid:9092\n")
    (values / "argocd.yaml").write_text("# platform-owned values, not an application\n")
    for name in CORE:
        (values / f"{name}.yaml").write_text(
            textwrap.dedent(
                f"""
                # {name} values
                config:
                  anything: "x"
                gatewayApi:
                  enabled: true
                  hosts:
                    - path: /api/{name}
                      pathType: PathPrefix
                mcp:
                  enabled: true
                  route:
                    enabled: true
                    path: /api/mcp/{name}
                """
            )
        )
    # A kind: other context that still owns an /api route through its values.
    (values / "network-fulfillment.yaml").write_text(
        textwrap.dedent(
            """
            gatewayApi:
              enabled: true
              hosts:
                - path: /api/network-fulfillment
                  pathType: PathPrefix
            """
        )
    )


class ExposureInventoryTest(unittest.TestCase):
    def test_discovers_all_surfaces_from_the_layered_layout(self):
        module = load_module()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            write_fixture(root)

            inventory = module.load_inventory(root)

        self.assertEqual(set(CORE), set(inventory.core_apis))
        self.assertEqual(set(CORE), set(inventory.remotes))
        self.assertEqual(set(CORE), set(inventory.mcps))
        self.assertEqual(
            set(CORE) | {"network-fulfillment"},
            set(inventory.apis),
        )

    def test_rejects_registry_values_drift(self):
        module = load_module()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            write_fixture(root)
            # A values file whose context never made it into apps.yaml.
            (root / "helm-values" / "ghost-context.yaml").write_text("config: {}\n")

            with self.assertRaisesRegex(ValueError, "without apps.yaml entries"):
                module.load_inventory(root)

    def test_rejects_service_without_values(self):
        module = load_module()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            write_fixture(root)
            (root / "helm-values" / "order-management.yaml").unlink()

            with self.assertRaisesRegex(ValueError, "without helm-values files"):
                module.load_inventory(root)


if __name__ == "__main__":
    unittest.main()
