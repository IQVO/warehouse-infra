#!/usr/bin/env python3
"""Unit tests for scripts/mcp-conformance-2026-07-28.py against stdlib fakes.

The fakes mimic the three server shapes seen on the wire (go-sdk v1.8.0 spike,
contracts.md S1-S3):
  conforming  Stateless: true -> supportedVersions has 2026-07-28, tools/list works
              without a session, legacy initialize answers 200 and issues no session id.
  default     nil options -> server/discover lists only <= 2025-11-25, tools/list with
              the 2026-07-28 header is HTTP 400 / -32022, legacy initialize issues a session.
  session     a server that demands Mcp-Session-Id on tools/list.
No cluster, no network beyond 127.0.0.1.
"""
from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import sys
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("mcp_conformance", SCRIPTS / "mcp-conformance-2026-07-28.py")
probe = importlib.util.module_from_spec(spec)
sys.modules["mcp_conformance"] = probe
spec.loader.exec_module(probe)

SESSION_SECRET = "SECRET-SESSION-ID-0123456789"
NEW = ["2026-07-28", "2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]
OLD = NEW[1:]

TOOLS_ALL_DECLARED = [
    {"name": "get_staffing_gap", "_meta": {"com.warehouse/authority": "L1"}},
    {"name": "assign_labor", "_meta": {"com.warehouse/authority": "L3"}},
]
TOOLS_PARTIAL = [
    {"name": "get_staffing_gap", "_meta": {"com.warehouse/authority": "L1"}},
    {"name": "list_things"},
    {"name": "bad_level", "_meta": {"com.warehouse/authority": "L5"}},
]


def sse(message: dict) -> bytes:
    return b"event: message\ndata: " + json.dumps(message).encode() + b"\n\n"


class Fake(BaseHTTPRequestHandler):
    modes: dict[str, str] = {}
    tools: dict[str, list] = {}
    seen: list[dict] = []

    def log_message(self, *_):  # keep test output quiet
        pass

    def _send(self, status: int, body: bytes, ctype: str, extra: dict | None = None):
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        for key, value in (extra or {}).items():
            self.send_header(key, value)
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        payload = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))))
        mode = self.modes.get(self.path, "conforming")
        method = payload["method"]
        type(self).seen.append({"path": self.path, "method": method, "payload": payload,
                                "headers": {k.lower(): v for k, v in self.headers.items()}})
        ident = payload.get("id")

        def result(body: dict, as_sse: bool = True):
            msg = {"jsonrpc": "2.0", "id": ident, "result": body}
            if as_sse:
                self._send(200, sse(msg), "text/event-stream")
            else:
                self._send(200, json.dumps(msg).encode(), "application/json")

        def error(status: int, code: int, message: str, data: dict | None = None):
            err = {"code": code, "message": message}
            if data:
                err["data"] = data
            self._send(status, json.dumps({"jsonrpc": "2.0", "id": ident, "error": err}).encode(), "application/json")

        if method == "initialize":
            if mode == "legacy-broken":
                return error(400, -32600, "bad request")
            extra = {"Mcp-Session-Id": SESSION_SECRET} if mode in ("default", "session") else None
            body = {"protocolVersion": "2025-06-18", "capabilities": {}, "serverInfo": {"name": "fake", "version": "0"}}
            msg = json.dumps({"jsonrpc": "2.0", "id": ident, "result": body}).encode()
            return self._send(200, msg, "application/json", extra)

        if method == "server/discover":
            if mode == "default-error":
                return error(400, -32022, 'protocol version "2026-07-28" is not supported by this server',
                             {"supported": OLD, "requested": "2026-07-28"})
            if mode == "default":
                return result({"supportedVersions": OLD, "capabilities": {}})
            return result({"supportedVersions": NEW, "capabilities": {"tools": {}}})

        if method == "tools/list":
            if mode in ("default", "default-error"):
                return error(400, -32022, 'protocol version "2026-07-28" is not supported by this server',
                             {"supported": OLD, "requested": "2026-07-28"})
            if mode == "session":
                return error(400, -32600, "Bad Request: missing Mcp-Session-Id")
            tools = self.tools.get(self.path, TOOLS_ALL_DECLARED)
            if mode == "paged":
                cursor = (payload["params"] or {}).get("cursor")
                if not cursor:
                    return result({"tools": tools[:1], "nextCursor": "c2"}, as_sse=False)
                return result({"tools": tools[1:]}, as_sse=False)
            return result({"tools": tools}, as_sse=(mode != "plain-json"))

        error(404, -32601, "method not found")


class ProbeCase(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.httpd = ThreadingHTTPServer(("127.0.0.1", 0), Fake)
        cls.port = cls.httpd.server_address[1]
        threading.Thread(target=cls.httpd.serve_forever, daemon=True).start()

    @classmethod
    def tearDownClass(cls):
        cls.httpd.shutdown()
        cls.httpd.server_close()

    def setUp(self):
        Fake.modes = {}
        Fake.tools = {}
        Fake.seen = []

    def url(self, path: str) -> str:
        return f"http://127.0.0.1:{self.port}{path}"

    def run_main(self, *args: str) -> tuple[int, str]:
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            code = probe.main(list(args))
        return code, buf.getvalue()

    def run_one(self, mode: str, tools=None, require=False) -> dict:
        Fake.modes["/mcp"] = mode
        if tools is not None:
            Fake.tools["/mcp"] = tools
        return probe.probe("fake", self.url("/mcp"), 5.0, require)


class ConformingServer(ProbeCase):
    def test_conforming_passes_everything(self):
        result = self.run_one("conforming")
        self.assertEqual(result["status"], "PASS", result)
        for check in ("discover", "tools", "authority", "legacy"):
            self.assertEqual(result["checks"][check]["status"], "PASS", check)
        self.assertEqual(result["checks"]["authority"]["declared"], 2)

    def test_plain_json_tools_reply_is_parsed_too(self):
        self.assertEqual(self.run_one("plain-json")["checks"]["tools"]["status"], "PASS")

    def test_request_shape_matches_s3(self):
        self.run_one("conforming")
        stateless = [s for s in Fake.seen if s["method"] in ("server/discover", "tools/list")]
        self.assertEqual([s["method"] for s in stateless], ["server/discover", "tools/list"])
        for call in stateless:
            headers = call["headers"]
            self.assertEqual(headers["content-type"], "application/json")
            self.assertEqual(headers["accept"], "application/json, text/event-stream")
            self.assertEqual(headers["mcp-protocol-version"], "2026-07-28")
            self.assertEqual(headers["mcp-method"], call["method"])
            self.assertNotIn("mcp-session-id", headers)
            self.assertEqual(
                call["payload"]["params"]["_meta"],
                {"io.modelcontextprotocol/protocolVersion": "2026-07-28",
                 "io.modelcontextprotocol/clientCapabilities": {}},
            )
        legacy = [s for s in Fake.seen if s["method"] == "initialize"]
        self.assertEqual(len(legacy), 1)
        self.assertEqual(legacy[0]["payload"]["params"]["protocolVersion"], "2025-06-18")

    def test_paginated_tools_are_followed(self):
        result = self.run_one("paged")
        self.assertEqual(result["checks"]["authority"]["total"], 2)
        self.assertEqual(result["checks"]["tools"]["status"], "PASS")


class DefaultOptionsServer(ProbeCase):
    def test_supported_versions_without_target_fails_with_hint(self):
        result = self.run_one("default")
        self.assertEqual(result["status"], "FAIL")
        discover = result["checks"]["discover"]
        self.assertEqual(discover["status"], "FAIL")
        self.assertIn("lacks 2026-07-28", discover["detail"])
        self.assertIn("Stateless: true", discover["detail"])

    def test_minus_32022_on_stateless_requests_fails_with_hint(self):
        result = self.run_one("default-error")
        for check in ("discover", "tools"):
            self.assertEqual(result["checks"][check]["status"], "FAIL", check)
            self.assertIn("-32022", result["checks"][check]["detail"])
            self.assertIn("Stateless: true", result["checks"][check]["detail"])
        self.assertEqual(result["checks"]["authority"]["status"], "SKIP")
        self.assertEqual(result["checks"]["legacy"]["status"], "PASS")

    def test_legacy_initialize_still_checked_and_session_id_never_printed(self):
        Fake.modes["/mcp"] = "default"
        code, out = self.run_main("--target", f"fake={self.url('/mcp')}")
        self.assertEqual(code, 1)
        self.assertNotIn(SESSION_SECRET, out)
        code, out = self.run_main("--json", "--target", f"fake={self.url('/mcp')}")
        self.assertNotIn(SESSION_SECRET, out)


class SessionDemandingServer(ProbeCase):
    def test_demanded_session_fails_tools(self):
        result = self.run_one("session")
        self.assertEqual(result["checks"]["discover"]["status"], "PASS")
        tools = result["checks"]["tools"]
        self.assertEqual(tools["status"], "FAIL")
        self.assertIn("Mcp-Session-Id", tools["detail"])
        self.assertEqual(result["status"], "FAIL")


class Authority(ProbeCase):
    def test_missing_and_invalid_is_warn_by_default(self):
        result = self.run_one("conforming", TOOLS_PARTIAL)
        authority = result["checks"]["authority"]
        self.assertEqual(authority["status"], "WARN")
        self.assertEqual((authority["declared"], authority["total"]), (1, 3))
        self.assertEqual(authority["missing"], ["list_things"])
        self.assertEqual(authority["invalid"], ["bad_level"])
        self.assertEqual(result["status"], "WARN")

    def test_require_authority_turns_warn_into_fail(self):
        result = self.run_one("conforming", TOOLS_PARTIAL, require=True)
        self.assertEqual(result["checks"]["authority"]["status"], "FAIL")
        self.assertEqual(result["status"], "FAIL")

    def test_exit_codes(self):
        Fake.modes["/mcp"] = "conforming"
        Fake.tools["/mcp"] = TOOLS_PARTIAL
        target = f"fake={self.url('/mcp')}"
        self.assertEqual(self.run_main("--target", target)[0], 0)
        self.assertEqual(self.run_main("--target", target, "--require-authority")[0], 1)

    def test_all_levels_l1_to_l4_are_valid(self):
        tools = [{"name": f"t{i}", "_meta": {"com.warehouse/authority": f"L{i}"}} for i in (1, 2, 3, 4)]
        result = self.run_one("conforming", tools, require=True)
        self.assertEqual(result["checks"]["authority"]["status"], "PASS")


class Legacy(ProbeCase):
    def test_broken_legacy_initialize_fails(self):
        result = self.run_one("legacy-broken")
        self.assertEqual(result["checks"]["legacy"]["status"], "FAIL")
        self.assertEqual(result["status"], "FAIL")


class Cli(ProbeCase):
    def test_table_has_one_row_per_server_and_exit_one_on_any_fail(self):
        Fake.modes["/good"] = "conforming"
        Fake.modes["/old"] = "default"
        code, out = self.run_main("--target", f"good={self.url('/good')}", "--target", f"old={self.url('/old')}")
        self.assertEqual(code, 1)
        rows = {line.split()[0]: line for line in out.splitlines() if line.split()[:1] in (["good"], ["old"])}
        self.assertTrue(rows["good"].rstrip().endswith("PASS"), out)
        self.assertTrue(rows["old"].rstrip().endswith("FAIL"), out)
        self.assertIn("SERVER", out.splitlines()[0])
        self.assertIn("2 server(s), 1 failed", out)

    def test_json_output(self):
        Fake.modes["/mcp"] = "conforming"
        code, out = self.run_main("--json", "--target", f"fake={self.url('/mcp')}")
        data = json.loads(out)
        self.assertEqual(code, 0)
        self.assertTrue(data["ok"])
        self.assertEqual(data["servers"][0]["name"], "fake")
        self.assertEqual(data["servers"][0]["checks"]["discover"]["status"], "PASS")

    def test_unreachable_server_fails_without_hanging(self):
        free = ThreadingHTTPServer(("127.0.0.1", 0), Fake)
        port = free.server_address[1]
        free.server_close()
        code, out = self.run_main("--timeout", "2", "--target", f"down=http://127.0.0.1:{port}/mcp")
        self.assertEqual(code, 1)
        self.assertIn("unreachable", out)

    def test_credentials_in_url_are_not_printed(self):
        Fake.modes["/mcp"] = "conforming"
        code, out = self.run_main("--json", "--target", f"fake=http://user:hunter2@127.0.0.1:{self.port}/mcp")
        self.assertNotIn("hunter2", out)

    def test_bad_target_and_no_target_are_usage_errors(self):
        with contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaises(SystemExit) as ctx:
                probe.main([])
            self.assertEqual(ctx.exception.code, 2)
            with self.assertRaises(SystemExit) as ctx:
                probe.main(["--target", "nourl"])
            self.assertEqual(ctx.exception.code, 2)

    def test_base_derives_targets_from_inventory_source(self):
        with tempfile.TemporaryDirectory() as tmp:
            scripts = Path(tmp) / "scripts"
            scripts.mkdir()
            (scripts / "exposure_inventory.py").write_text(
                "from types import SimpleNamespace\n"
                "def load_inventory(root):\n"
                "    return SimpleNamespace(mcps=('alpha', 'beta'))\n"
            )
            sys.modules.pop("exposure_inventory", None)
            Fake.modes["/api/mcp/alpha"] = "conforming"
            Fake.modes["/api/mcp/beta"] = "default"
            try:
                code, out = self.run_main("--root", tmp, "--base", self.url("/api/mcp/"))
            finally:
                sys.modules.pop("exposure_inventory", None)
                sys.path[:] = [p for p in sys.path if p != str(scripts)]
        self.assertEqual(code, 1)
        self.assertIn("2 server(s), 1 failed", out)
        self.assertEqual({s["path"] for s in Fake.seen}, {"/api/mcp/alpha", "/api/mcp/beta"})

    def test_parse_body_sse_and_json(self):
        message = {"jsonrpc": "2.0", "id": 1, "result": {"a": 1}}
        self.assertEqual(probe.parse_body(sse(message).decode()), message)
        self.assertEqual(probe.parse_body(json.dumps(message)), message)
        self.assertIsNone(probe.parse_body("event: ping\n\n"))
        self.assertIsNone(probe.parse_body(""))


if __name__ == "__main__":
    unittest.main()
