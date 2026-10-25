#!/usr/bin/env python3
"""Derive deployed HTTP surfaces from warehouse-infra Terraform sources."""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path
from typing import NamedTuple


class Inventory(NamedTuple):
    core_apis: tuple[str, ...]
    apis: tuple[str, ...]
    remotes: tuple[str, ...]
    mcps: tuple[str, ...]


def _object_body(source: str, assignment: str) -> str:
    start = source.find(assignment)
    if start < 0:
        raise ValueError(f"Terraform assignment not found: {assignment}")
    opening = source.find("{", start + len(assignment))
    if opening < 0:
        raise ValueError(f"Terraform object has no opening brace: {assignment}")
    depth = 0
    for index in range(opening, len(source)):
        char = source[index]
        if char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                return source[opening + 1 : index]
    raise ValueError(f"Terraform object is not closed: {assignment}")


def _map_keys(path: Path, assignment: str) -> tuple[str, ...]:
    body = _object_body(path.read_text(), assignment)
    return tuple(re.findall(r'^\s*"([a-z0-9-]+)"\s*=\s*\{', body, re.MULTILINE))


def _string_list(path: Path, assignment: str) -> tuple[str, ...]:
    source = path.read_text()
    start = source.find(assignment)
    if start < 0:
        raise ValueError(f"Terraform assignment not found: {assignment}")
    opening = source.find("[", start + len(assignment))
    if opening < 0:
        raise ValueError(f"Terraform list has no opening bracket: {assignment}")
    closing = source.find("]", opening + 1)
    if closing < 0:
        raise ValueError(f"Terraform list is not closed: {assignment}")
    return tuple(re.findall(r'"([a-z0-9-]+)"', source[opening + 1 : closing]))


def _require_dedicated(path: Path, chart_marker: str, context: str) -> None:
    source = path.read_text()
    route_markers = (f"/api/{context}", f"${{var.api_path_prefix}}/{context}")
    missing = []
    if chart_marker not in source:
        missing.append(chart_marker)
    if not any(marker in source for marker in route_markers):
        missing.append(f"API route for {context}")
    if missing:
        raise ValueError(f"{context} dedicated Terraform path is incomplete: missing {', '.join(missing)}")


def load_inventory(root: Path) -> Inventory:
    terraform = root / "terraform"
    core = _map_keys(terraform / "locals.tf", "services =")
    remotes = _map_keys(terraform / "frontends.tf", "frontend_remotes =")
    mcps = _string_list(terraform / "mcp.tf", "mcp_services =")
    if not core:
        raise ValueError("local.services contains no core APIs")
    if set(remotes) != set(core):
        missing = sorted(set(core) - set(remotes))
        extra = sorted(set(remotes) - set(core))
        raise ValueError(f"frontend remote drift: missing={missing}, extra={extra}")
    if set(mcps) != set(core):
        missing = sorted(set(core) - set(mcps))
        extra = sorted(set(mcps) - set(core))
        raise ValueError(f"MCP service drift: missing={missing}, extra={extra}")

    _require_dedicated(
        terraform / "ops-agent.tf", "ops_agent_chart_path", "warehouse-ops-agent"
    )
    _require_dedicated(
        terraform / "network-fulfillment.tf",
        "network_fulfillment_chart_path",
        "network-fulfillment",
    )
    return Inventory(
        core_apis=core,
        apis=core + ("warehouse-ops-agent", "network-fulfillment"),
        remotes=remotes,
        mcps=mcps,
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--root", type=Path, default=Path(__file__).resolve().parents[1]
    )
    parser.add_argument(
        "--kind", choices=("core", "apis", "remotes", "mcps", "json"), default="json"
    )
    args = parser.parse_args()
    try:
        inventory = load_inventory(args.root)
    except (OSError, ValueError) as error:
        print(f"exposure inventory error: {error}", file=sys.stderr)
        return 1

    if args.kind == "json":
        print(json.dumps(inventory._asdict(), indent=2))
    else:
        values = {
            "core": inventory.core_apis,
            "apis": inventory.apis,
            "remotes": inventory.remotes,
            "mcps": inventory.mcps,
        }[args.kind]
        print("\n".join(values))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
