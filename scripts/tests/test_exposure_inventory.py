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
    "workforce-management",
    "facility-layout",
    "labor-performance",
    "process-path-management",
)


def load_module():
    spec = importlib.util.spec_from_file_location("exposure_inventory", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


def write_fixture(root: Path) -> None:
    terraform = root / "terraform"
    terraform.mkdir()
    service_rows = "\n".join(f'    "{name}" = {{ path = "/api/{name}" }}' for name in CORE)
    remote_rows = "\n".join(f'    "{name}" = {{ remote_name = "{name}" }}' for name in CORE)
    (terraform / "locals.tf").write_text(
        textwrap.dedent(
            f"""
            locals {{
              services = {{
            {service_rows}
              }}
            }}
            """
        )
    )
    (terraform / "frontends.tf").write_text(
        textwrap.dedent(
            f"""
            locals {{
              frontend_remotes = var.deploy_frontends ? {{
            {remote_rows}
              }} : {{}}
            }}
            """
        )
    )
    (terraform / "ops-agent.tf").write_text(
        'locals { ops_agent_chart_path = "../../warehouse-ops-agent/charts/warehouse-ops-agent" }\n'
        'output "ops_agent_route" { value = "/api/warehouse-ops-agent" }\n'
    )
    (terraform / "network-fulfillment.tf").write_text(
        'locals { network_fulfillment_chart_path = "../../network-fulfillment/charts/network-fulfillment" }\n'
        'output "network_fulfillment_route" { value = "/api/network-fulfillment" }\n'
    )
    (terraform / "mcp.tf").write_text(
        "locals {\n"
        "  mcp_services = toset([\n"
        + "".join(f'    "{name}",\n' for name in reversed(CORE))
        + "  ])\n}\n"
    )


class ExposureInventoryTest(unittest.TestCase):
    def test_discovers_all_surfaces_from_terraform_sources(self):
        module = load_module()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            write_fixture(root)

            inventory = module.load_inventory(root)

        self.assertEqual(set(CORE), set(inventory.core_apis))
        self.assertEqual(set(CORE), set(inventory.remotes))
        self.assertEqual(set(CORE), set(inventory.mcps))
        self.assertEqual(
            set(CORE) | {"warehouse-ops-agent", "network-fulfillment"},
            set(inventory.apis),
        )

    def test_rejects_mcp_inventory_drift(self):
        module = load_module()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            write_fixture(root)
            (root / "terraform" / "mcp.tf").write_text(
                'locals { mcp_services = toset(["order-management"]) }\n'
            )

            with self.assertRaisesRegex(ValueError, "MCP service drift"):
                module.load_inventory(root)


if __name__ == "__main__":
    unittest.main()
