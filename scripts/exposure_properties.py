#!/usr/bin/env python3
"""Pure exposure-policy properties shared by live scripts and tests."""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path
from urllib.parse import urljoin


EXPOSED_TYPES = {"NodePort", "LoadBalancer"}


def nginx_policy_errors(config: str) -> list[str]:
    body = "\n".join(line.split("#", 1)[0] for line in config.splitlines())
    errors = []
    if re.search(r"location\s+(?:[=~^*]+\s*)?/api(?:/|\s|\{)", body):
        errors.append("web gateway declares an /api location")
    if re.search(r"proxy_pass[^;\n]*kong", body, re.IGNORECASE):
        errors.append("web gateway proxies to Kong")
    upstreams = re.findall(r"set\s+\$upstream_[^\s]+\s+([^;]+)", body)
    # The named exceptions are the two site frontends whose Service is not
    # "<name>-frontend": the console shell and the EventCatalog static site.
    invalid = [
        value
        for value in upstreams
        if "frontend" not in value
        and "warehouse-console" not in value
        and "ecosystem." not in value
    ]
    if invalid:
        errors.append(f"web gateway has non-frontend upstreams: {invalid}")
    return errors


def javascript_response_errors(code: int, content_type: str, body: str) -> list[str]:
    errors = []
    if code != 200:
        errors.append(f"expected HTTP 200, got {code}")
    if "javascript" not in content_type.lower():
        errors.append(f"expected JavaScript content type, got {content_type or '<none>'}")
    lowered = body.lstrip().lower()
    if not body.strip():
        errors.append("JavaScript body is empty")
    elif lowered.startswith("<!doctype html") or lowered.startswith("<html"):
        errors.append("expected JavaScript body, got HTML")
    return errors


def resolved_chunk_url(entry_url: str, body: str) -> str:
    match = re.search(r'["\'](\./[^"\']+\.js(?:\?[^"\']*)?)["\']', body)
    if not match:
        raise ValueError("remoteEntry.js contains no relative JavaScript chunk reference")
    return urljoin(entry_url, match.group(1))


def exposure_type_errors(
    services: list[dict], expected_apis: tuple[str, ...], allowed_exposed: set[str]
) -> list[str]:
    errors = []
    by_key = {
        f"{item.get('metadata', {}).get('namespace', 'default')}/{item.get('metadata', {}).get('name', '')}": item
        for item in services
        if item.get("kind") == "Service"
    }
    for api in expected_apis:
        key = f"warehouse-systems/{api}"
        service_item = by_key.get(key)
        if service_item is None:
            errors.append(f"missing product API Service {key}")
        elif service_item.get("spec", {}).get("type", "ClusterIP") != "ClusterIP":
            errors.append(f"product API Service {key} must be ClusterIP")

    for key, item in by_key.items():
        service_type = item.get("spec", {}).get("type", "ClusterIP")
        if service_type in EXPOSED_TYPES and key not in allowed_exposed:
            errors.append(f"unexpected exposed Service {key} ({service_type})")
    return errors


def _selector_matches(selector: dict, deployment_item: dict) -> bool:
    labels = (
        deployment_item.get("spec", {})
        .get("template", {})
        .get("metadata", {})
        .get("labels", {})
    )
    return bool(selector) and all(labels.get(key) == value for key, value in selector.items())


def selector_isolation_errors(resources: list[dict], expected_apis: tuple[str, ...]) -> list[str]:
    errors = []
    services = {
        (item.get("metadata", {}).get("namespace", "default"), item.get("metadata", {}).get("name")): item
        for item in resources
        if item.get("kind") == "Service"
    }
    deployments = [item for item in resources if item.get("kind") == "Deployment"]
    for api in expected_apis:
        namespace = "warehouse-systems"
        service_item = services.get((namespace, api))
        if service_item is None:
            errors.append(f"missing API Service {namespace}/{api}")
            continue
        selector = service_item.get("spec", {}).get("selector", {})
        matched = [
            item.get("metadata", {}).get("name", "")
            for item in deployments
            if item.get("metadata", {}).get("namespace", "default") == namespace
            and _selector_matches(selector, item)
        ]
        if matched != [api]:
            errors.append(
                f"Service {namespace}/{api} selects {len(matched)} Deployments "
                f"(want only {api}): {matched}"
            )
    return errors


def route_backend_errors(resources: list[dict], expected_apis: tuple[str, ...]) -> list[str]:
    errors = []
    backend_names = []
    for item in resources:
        if item.get("kind") != "HTTPRoute":
            continue
        for rule in item.get("spec", {}).get("rules", []):
            for backend in rule.get("backendRefs", []):
                name = backend.get("name", "")
                backend_names.append(name)
                if name.endswith("-frontend") or name == "warehouse-console":
                    route = item.get("metadata", {}).get("name", "<unnamed>")
                    errors.append(f"HTTPRoute {route} targets frontend backend {name}")
    for api in expected_apis:
        if api not in backend_names:
            errors.append(f"no Kong HTTPRoute targets API Service {api}")
    return errors


def cors_errors(web_origin: str, allowed_origin: str, evil_allowed_origin: str) -> list[str]:
    errors = []
    if allowed_origin != web_origin:
        errors.append(
            f"approved origin must resolve exactly to {web_origin}, got {allowed_origin or '<none>'}"
        )
    if evil_allowed_origin:
        errors.append(f"unapproved origin was granted {evil_allowed_origin}")
    return errors


def _print_errors(errors: list[str]) -> int:
    for error in errors:
        print(error, file=sys.stderr)
    return 1 if errors else 0


def main() -> int:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)

    nginx_parser = subparsers.add_parser("nginx")
    nginx_parser.add_argument("--file", type=Path, required=True)

    js_parser = subparsers.add_parser("javascript")
    js_parser.add_argument("--code", type=int, required=True)
    js_parser.add_argument("--content-type", required=True)
    js_parser.add_argument("--body-file", type=Path, required=True)

    chunk_parser = subparsers.add_parser("chunk")
    chunk_parser.add_argument("--entry-url", required=True)
    chunk_parser.add_argument("--body-file", type=Path, required=True)

    cluster_parser = subparsers.add_parser("cluster")
    cluster_parser.add_argument("--resources-file", type=Path, required=True)
    cluster_parser.add_argument("--apis-file", type=Path, required=True)
    cluster_parser.add_argument("--allow-exposed", action="append", default=[])

    cors_parser = subparsers.add_parser("cors")
    cors_parser.add_argument("--web-origin", required=True)
    cors_parser.add_argument("--allowed-origin", default="")
    cors_parser.add_argument("--evil-allowed-origin", default="")

    args = parser.parse_args()
    if args.command == "nginx":
        return _print_errors(nginx_policy_errors(args.file.read_text()))
    if args.command == "javascript":
        return _print_errors(
            javascript_response_errors(args.code, args.content_type, args.body_file.read_text())
        )
    if args.command == "chunk":
        try:
            print(resolved_chunk_url(args.entry_url, args.body_file.read_text()))
            return 0
        except ValueError as error:
            print(error, file=sys.stderr)
            return 1
    if args.command == "cluster":
        resources = json.loads(args.resources_file.read_text()).get("items", [])
        apis = tuple(line.strip() for line in args.apis_file.read_text().splitlines() if line.strip())
        errors = exposure_type_errors(resources, apis, set(args.allow_exposed))
        errors.extend(selector_isolation_errors(resources, apis))
        errors.extend(route_backend_errors(resources, apis))
        return _print_errors(errors)
    return _print_errors(
        cors_errors(args.web_origin, args.allowed_origin, args.evil_allowed_origin)
    )


if __name__ == "__main__":
    raise SystemExit(main())
