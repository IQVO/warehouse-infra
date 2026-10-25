#!/usr/bin/env python3
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "exposure_properties.py"


def load_module():
    spec = importlib.util.spec_from_file_location("exposure_properties", SCRIPT)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load {SCRIPT}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def service(name, selector, service_type="ClusterIP", namespace="warehouse-systems"):
    return {
        "kind": "Service",
        "metadata": {"name": name, "namespace": namespace},
        "spec": {"type": service_type, "selector": selector},
    }


def deployment(name, labels, namespace="warehouse-systems"):
    return {
        "kind": "Deployment",
        "metadata": {"name": name, "namespace": namespace},
        "spec": {
            "selector": {"matchLabels": labels},
            "template": {"metadata": {"labels": labels}},
        },
    }


class ExposurePropertiesTest(unittest.TestCase):
    def test_nginx_policy_ignores_comments_but_rejects_real_api_proxy(self):
        module = load_module()
        documented = """
        # There is deliberately no location /api and no Kong upstream.
        location / { proxy_pass http://$warehouse_console; }
        """
        violation = documented + "\nlocation /api { proxy_pass http://kong; }\n"

        self.assertEqual([], module.nginx_policy_errors(documented))
        self.assertIn("/api location", " ".join(module.nginx_policy_errors(violation)))

    def test_javascript_property_rejects_misleading_200_html(self):
        module = load_module()

        errors = module.javascript_response_errors(
            200, "text/html; charset=utf-8", "<!doctype html><title>shell</title>"
        )

        self.assertTrue(errors)
        self.assertIn("JavaScript", " ".join(errors))

    def test_remote_entry_resolves_a_real_relative_chunk(self):
        module = load_module()
        body = 'import{x}from"./assets/virtual_mf-REMOTE_ENTRY_ID.abc123.js";export{x};'

        chunk = module.resolved_chunk_url(
            "http://localhost/mfes/order-management/remoteEntry.js", body
        )

        self.assertEqual(
            "http://localhost/mfes/order-management/assets/virtual_mf-REMOTE_ENTRY_ID.abc123.js",
            chunk,
        )

    def test_product_services_must_be_cluster_ip_and_nodeports_are_allowlisted(self):
        module = load_module()
        services = [
            service("order-management", {"component": "api"}),
            service("warehouse-ops-agent", {"component": "api"}),
            service("network-fulfillment", {"component": "api"}),
            service("web-gateway", {"component": "web"}, "NodePort"),
            service("surprise", {"component": "api"}, "LoadBalancer"),
        ]

        errors = module.exposure_type_errors(
            services,
            ("order-management", "warehouse-ops-agent", "network-fulfillment"),
            {"warehouse-systems/web-gateway"},
        )

        self.assertIn("warehouse-systems/surprise", " ".join(errors))

    def test_each_api_service_selects_only_its_api_deployment(self):
        module = load_module()
        shared = {"app": "orders"}
        resources = [
            service("order-management", shared),
            deployment("order-management", shared),
            deployment("order-management-reports", shared),
        ]

        errors = module.selector_isolation_errors(resources, ("order-management",))

        self.assertIn("selects 2 Deployments", " ".join(errors))

    def test_kong_routes_cover_every_api_and_never_target_frontends(self):
        module = load_module()
        routes = [
            {
                "kind": "HTTPRoute",
                "metadata": {"name": "order-management", "namespace": "warehouse-systems"},
                "spec": {"rules": [{"backendRefs": [{"name": "order-management"}]}]},
            },
            {
                "kind": "HTTPRoute",
                "metadata": {"name": "inventory-storage", "namespace": "warehouse-systems"},
                "spec": {"rules": [{"backendRefs": [{"name": "inventory-storage-frontend"}]}]},
            },
        ]

        errors = module.route_backend_errors(
            routes, ("order-management", "inventory-storage", "network-fulfillment")
        )

        joined = " ".join(errors)
        self.assertIn("inventory-storage-frontend", joined)
        self.assertIn("network-fulfillment", joined)

    def test_cors_allows_only_the_exact_web_origin(self):
        module = load_module()

        self.assertEqual([], module.cors_errors("http://localhost", "http://localhost", ""))
        self.assertTrue(module.cors_errors("http://localhost", "*", "*"))
        self.assertTrue(
            module.cors_errors(
                "http://localhost", "http://localhost", "http://evil.example"
            )
        )


if __name__ == "__main__":
    unittest.main()
