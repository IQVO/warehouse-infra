#!/usr/bin/env python3
"""Print the build matrix of .github/workflows/publish-images.yml (ADR 0011).

One entry per image terraform/20-apps would build locally for a registry entry
of terraform/apps.yaml -- the same three shapes modules/application knows:

  service   build_image != false   <repo>/Dockerfile          -> <app>
  frontend  frontend_remote set    <repo>/web/Dockerfile      -> <app>-frontend
  site      site: true             <repo>/Dockerfile          -> <app>-frontend

Usage: publish-matrix.py [--apps "a b c"]   (default: every application)
Output: JSON {"include": [{app, owner, kind, dir, name}, ...]} on stdout.
"""
import argparse
import json
import pathlib
import sys

import yaml

REGISTRY = pathlib.Path(__file__).resolve().parent.parent / "terraform" / "apps.yaml"


def entries(apps):
    out = []
    for app, a in apps.items():
        owner = a.get("repo_owner", "claudioed")
        if a.get("build_image", True):
            out.append({"app": app, "owner": owner, "kind": "service", "dir": ".", "name": app})
        if a.get("site", False):
            out.append({"app": app, "owner": owner, "kind": "site", "dir": ".", "name": f"{app}-frontend"})
        elif a.get("frontend_remote"):
            out.append({"app": app, "owner": owner, "kind": "frontend", "dir": "web", "name": f"{app}-frontend"})
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--apps", default="", help="space-separated subset; empty = all")
    args = ap.parse_args()
    apps = yaml.safe_load(REGISTRY.read_text())["applications"]
    wanted = args.apps.split()
    unknown = [w for w in wanted if w not in apps]
    if unknown:
        sys.exit(f"error: not in terraform/apps.yaml: {' '.join(unknown)}")
    chosen = {k: v for k, v in apps.items() if not wanted or k in wanted}
    json.dump({"include": entries(chosen)}, sys.stdout)
    print()


if __name__ == "__main__":
    main()
