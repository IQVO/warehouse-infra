#!/usr/bin/env python3
"""Write the exact fleet Git SHAs used by cluster acceptance."""
from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

from exposure_inventory import load_inventory


STATIC_REPOSITORIES = (
    "warehouse-console",
    "warehouse-ui-kit",
    "warehouse-docs",
    "e2e-tests",
)


def _git(path: Path, *args: str) -> str:
    result = subprocess.run(
        ["git", *args], cwd=path, capture_output=True, text=True, check=False
    )
    if result.returncode != 0:
        raise ValueError(f"{path}: git {' '.join(args)} failed: {result.stderr.strip()}")
    return result.stdout.strip()


def build_manifest(
    workspace: Path,
    repositories: tuple[str, ...],
    path_overrides: dict[str, Path] | None = None,
) -> dict:
    overrides = path_overrides or {}
    rows = []
    for repository in repositories:
        path = overrides.get(repository, workspace / repository)
        if not path.is_dir():
            raise ValueError(f"missing repository checkout: {repository} ({path})")
        sha = _git(path, "rev-parse", "HEAD")
        if len(sha) != 40:
            raise ValueError(f"{repository}: expected a full 40-character SHA, got {sha}")
        rows.append(
            {
                "repository": repository,
                "sha": sha,
                "ref": _git(path, "rev-parse", "--abbrev-ref", "HEAD"),
                "dirty": bool(_git(path, "status", "--porcelain")),
            }
        )
    return {"schemaVersion": 1, "repositories": rows}


def snapshot_errors(manifest: dict, expected: dict[str, str]) -> list[str]:
    actual = {row["repository"]: row["sha"] for row in manifest["repositories"]}
    errors = []
    for repository in sorted(actual.keys() - expected.keys()):
        errors.append(f"missing expected repository {repository}")
    for repository in sorted(expected.keys() - actual.keys()):
        errors.append(f"expected repository was not checked out: {repository}")
    for repository in sorted(actual.keys() & expected.keys()):
        expected_sha = expected[repository]
        if actual[repository] != expected_sha:
            errors.append(
                f"SHA mismatch for {repository}: expected {expected_sha}, got {actual[repository]}"
            )
    return errors


def clean_checkout_errors(manifest: dict) -> list[str]:
    return [
        f"dirty repository checkout: {row['repository']}"
        for row in manifest["repositories"]
        if row["dirty"]
    ]


def default_repositories(infra_root: Path) -> tuple[str, ...]:
    inventory = load_inventory(infra_root)
    return ("warehouse-infra",) + inventory.apis + STATIC_REPOSITORIES


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--infra-root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--workspace", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument(
        "--expected-json",
        default="",
        help="exact repository-to-SHA JSON map; an empty object records without gating",
    )
    parser.add_argument("--require-clean", action="store_true")
    args = parser.parse_args()
    workspace = args.workspace or args.infra_root.parent
    try:
        manifest = build_manifest(
            workspace,
            default_repositories(args.infra_root),
            {"warehouse-infra": args.infra_root},
        )
        errors = clean_checkout_errors(manifest) if args.require_clean else []
        if args.expected_json:
            expected = json.loads(args.expected_json)
            if not isinstance(expected, dict):
                raise ValueError("expected fleet SHAs must be a JSON object")
            if expected:
                errors.extend(snapshot_errors(manifest, expected))
        if errors:
            raise ValueError("; ".join(errors))
    except (json.JSONDecodeError, OSError, ValueError) as error:
        print(f"fleet SHA manifest error: {error}", file=sys.stderr)
        return 1
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(manifest, indent=2) + "\n")
    print(args.output)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
