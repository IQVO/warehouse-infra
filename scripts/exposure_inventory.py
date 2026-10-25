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
    """Derive the deployed surfaces from the LAYERED layout (ADR 0007).

    Sources of truth after the terraform/{00-cluster,10-platform,20-apps}
    refactor: terraform/apps.yaml is the application registry (kind: service
    entries get the /api route; frontend_remote names the module-federation
    remotes), and helm-values/<ctx>.yaml carries each context's own mcp
    block (the charts render the MCP server and its Kong route from it).
    """
    import yaml

    # Platform-owned value files that are not application registrations.
    PLATFORM_VALUES = {"argocd"}
    apps = yaml.safe_load((root / "terraform" / "apps.yaml").read_text())["applications"]
    core = tuple(sorted(name for name, entry in apps.items() if entry.get("kind") == "service"))
    remotes = tuple(sorted(name for name, entry in apps.items() if entry.get("frontend_remote")))
    mcps = []
    for values in sorted((root / "helm-values").glob("*.yaml")):
        if values.name.startswith("_") or values.stem in PLATFORM_VALUES:
            continue
        try:
            parsed = yaml.safe_load(values.read_text()) or {}
        except yaml.YAMLError:
            continue
        if isinstance(parsed.get("mcp"), dict) and parsed["mcp"].get("enabled", True):
            mcps.append(values.stem)
    mcps = tuple(sorted(mcps))
    api_routed = []
    for values in sorted((root / "helm-values").glob("*.yaml")):
        if values.name.startswith("_") or values.stem in PLATFORM_VALUES:
            continue
        try:
            parsed = yaml.safe_load(values.read_text()) or {}
        except yaml.YAMLError:
            continue
        gateway = parsed.get("gatewayApi")
        if isinstance(gateway, dict) and gateway.get("enabled"):
            api_routed.append(values.stem)
    api_routed = tuple(sorted(set(api_routed)))
    if not core:
        raise ValueError("apps.yaml contains no kind: service entries")
    values_files = {p.stem for p in (root / "helm-values").glob("*.yaml") if not p.name.startswith("_")} - PLATFORM_VALUES
    missing_values = sorted(set(core) - values_files)
    if missing_values:
        raise ValueError(f"registry entries without helm-values files: {missing_values}")
    orphan_values = sorted(values_files - set(apps))
    if orphan_values:
        raise ValueError(f"helm-values files without apps.yaml entries: {orphan_values}")
    return Inventory(
        core_apis=core,
        apis=api_routed,
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
