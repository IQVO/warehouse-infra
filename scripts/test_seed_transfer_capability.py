#!/usr/bin/env python3
"""Unit tests for scripts/seed-transfer-capability.py against a fake facility-layout.

Run from the repo root (stdlib only, no cluster needed):

    python3 scripts/test_seed_transfer_capability.py

The fake is a real HTTP server (http.server on 127.0.0.1, ephemeral port) that
serves the contract the seed relies on, mounted under the Kong prefix
/api/facility-layout exactly as the kind cluster exposes it:

  GET /site-roles/transfer-defaults, GET /sites,
  GET|PUT /sites/{siteCode}/transfer-capability

with facility-layout's semantics: a PUT of the current snapshot is a 200 no-op
(same revision), a differing snapshot advances the revision by one, a
decommissioned site answers 409 site-not-active, and a test can make the next
PUT of a site lose the optimistic-concurrency race (409 concurrent-modification),
optionally with the "other writer" landing a given snapshot first.
"""
import contextlib
import importlib.util
import io
import json
import os
import threading
import unittest
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PREFIX = "/api/facility-layout"
PROBLEM = "https://errors.facility-layout.warehouse-systems.dev/"


def load_seed():
    path = os.path.join(REPO_ROOT, "scripts", "seed-transfer-capability.py")
    spec = importlib.util.spec_from_file_location("seed_transfer_capability", path)
    assert spec is not None and spec.loader is not None, path
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


SEED = load_seed()

DEFAULTS = [
    {"siteRole": "NON_SORTABLE_FC", "transferOriginEnabled": True, "transferDestinationEnabled": True},
    {"siteRole": "MICRO_FC", "transferOriginEnabled": False, "transferDestinationEnabled": True},
    {"siteRole": "INBOUND_CROSS_DOCK", "transferOriginEnabled": True, "transferDestinationEnabled": False},
    {"siteRole": "DELIVERY_STATION", "transferOriginEnabled": False, "transferDestinationEnabled": False},
    {"siteRole": "FRESH_GROCERY_FC", "transferOriginEnabled": False, "transferDestinationEnabled": False},
]


class FakeFacilityLayout:
    """In-memory facility-layout state + request log, served over real HTTP."""

    def __init__(self, sites, capabilities=None, defaults=None):
        self.sites = {s["siteCode"]: dict(s) for s in sites}
        # siteCode -> [origin, destination, revision]; absent = never set (False, False, 0)
        self.caps = {k: list(v) for k, v in (capabilities or {}).items()}
        self.defaults = DEFAULTS if defaults is None else defaults
        self.defaults_status = 200
        self.defaults_reply = None    # a 200 body served verbatim instead of a page (a wrong shape)
        self.sites_reply = None       # same for GET /sites
        self.page_cap = None          # the most rows the server returns per page (None = as asked)
        self.queries = []             # (method, path, raw query string)
        self.log = []                 # (method, path-without-prefix, body)
        self.lose_race = {}           # siteCode -> number of PUTs that answer 409 concurrent-modification
        self.race_winner = {}         # siteCode -> (origin, dest) the concurrent writer lands
        self.put_status = {}          # siteCode -> forced status for every PUT
        self.lock = threading.Lock()

    def capability(self, code):
        o, d, r = self.caps.get(code, [False, False, 0])
        return {"siteCode": code, "transferOriginEnabled": o, "transferDestinationEnabled": d,
                "capabilityRevision": r}

    def apply(self, code, origin, dest):
        o, d, r = self.caps.get(code, [False, False, 0])
        if (o, d) != (origin, dest) or r == 0:
            r += 1
        self.caps[code] = [origin, dest, r]

    def puts(self):
        return [entry for entry in self.log if entry[0] == "PUT"]

    def page(self, rows, query):
        """One keyset page in the fleet envelope {items, nextCursor} (REST guideline, 2026-11-01).

        Like the real collections: only `limit` (1-500) and `cursor` are known query parameters, anything
        else is 400 unknown-query-parameter, and a server may cap the page below what the client asked.
        """
        unknown = sorted(set(query) - {"limit", "cursor"})
        if unknown:
            return 400, {"type": PROBLEM + "unknown-query-parameter", "status": 400}
        try:
            limit = int(query.get("limit", ["100"])[0])
            start = int(query["cursor"][0][1:]) if "cursor" in query else 0
        except (ValueError, IndexError):
            return 400, {"type": PROBLEM + "invalid-cursor", "status": 400}
        if not 1 <= limit <= 500:
            return 400, {"type": PROBLEM + "invalid-limit", "status": 400}
        size = min(limit, self.page_cap or limit)
        body = {"items": rows[start:start + size]}
        if start + size < len(rows):
            body["nextCursor"] = f"c{start + size}"
        return 200, body

    def handle(self, method, path, body):
        path, _, raw_query = path.partition("?")
        query = urllib.parse.parse_qs(raw_query, keep_blank_values=True)
        with self.lock:
            self.log.append((method, path, body))
            self.queries.append((method, path, raw_query))
            if method == "GET" and path == "/site-roles/transfer-defaults":
                if self.defaults_status != 200:
                    return self.defaults_status, self.defaults
                if self.defaults_reply is not None:
                    return 200, self.defaults_reply
                return self.page(self.defaults, query)
            if method == "GET" and path == "/sites":
                if self.sites_reply is not None:
                    return 200, self.sites_reply
                return self.page(list(self.sites.values()), query)
            parts = path.strip("/").split("/")
            if len(parts) == 3 and parts[0] == "sites" and parts[2] == "transfer-capability":
                code = parts[1]
                if code not in self.sites:
                    return 404, {"type": PROBLEM + "not-found", "status": 404}
                if method == "GET":
                    return 200, self.capability(code)
                if method == "PUT":
                    if code in self.put_status:
                        return self.put_status[code], {"type": PROBLEM + "internal-error", "status": self.put_status[code]}
                    if self.sites[code].get("status") != "Active":
                        return 409, {"type": PROBLEM + "site-not-active", "status": 409}
                    if self.lose_race.get(code, 0) > 0:
                        self.lose_race[code] -= 1
                        if code in self.race_winner:
                            self.apply(code, *self.race_winner[code])
                        return 409, {"type": PROBLEM + "concurrent-modification", "status": 409}
                    if not isinstance(body, dict) or not all(
                            isinstance(body.get(k), bool) for k in ("transferOriginEnabled", "transferDestinationEnabled")):
                        return 400, {"type": PROBLEM + "missing-transfer-capability-field", "status": 400}
                    self.apply(code, body["transferOriginEnabled"], body["transferDestinationEnabled"])
                    return 200, self.capability(code)
            return 404, {"type": PROBLEM + "not-found", "status": 404}


def serve(fake):
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, format, *args):  # noqa: A002 - keep test output clean
            pass

        def _dispatch(self, method):
            if not self.path.startswith(PREFIX + "/"):
                self.send_response(404)
                self.end_headers()
                return
            length = int(self.headers.get("Content-Length") or 0)
            raw = self.rfile.read(length) if length else b""
            body = json.loads(raw) if raw else None
            status, payload = fake.handle(method, self.path[len(PREFIX):], body)
            data = json.dumps(payload).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json" if status < 400 else "application/problem+json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def do_GET(self):
            self._dispatch("GET")

        def do_PUT(self):
            self._dispatch("PUT")

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, kwargs={"poll_interval": 0.05}, daemon=True).start()
    return server


def site(code, role, status="Active"):
    return {"siteCode": code, "name": code, "status": status, "siteRole": role}


class SeedTransferCapabilityTest(unittest.TestCase):
    def start(self, fake):
        server = serve(fake)
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        return f"http://127.0.0.1:{server.server_address[1]}{PREFIX}"

    def run_seed(self, base_url, *args):
        out = io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(out):
            code = SEED.main(["--base-url", base_url, "--timeout", "5", *args])
        return code, out.getvalue()

    def fleet(self):
        return FakeFacilityLayout(
            sites=[
                site("ABE8", "NON_SORTABLE_FC"),
                site("MFC1", "MICRO_FC"),
                site("XD01", "INBOUND_CROSS_DOCK"),
                site("DAT3", "DELIVERY_STATION"),
                site("WH1", "UNSPECIFIED"),
                site("WH2", "NON_SORTABLE_FC", status="Decommissioned"),
            ],
            capabilities={
                "MFC1": [False, True, 4],     # already at its default
                "DAT3": [True, True, 2],      # wrongly enabled: must be switched off
                "WH1": [True, False, 1],      # unclassified: must be left as it is
                "WH2": [False, False, 0],     # decommissioned: frozen
            })

    def test_applies_role_defaults_to_active_classified_sites_only(self):
        fake = self.fleet()
        code, out = self.run_seed(self.start(fake))
        self.assertEqual(code, 0, out)
        puts = {path: body for _, path, body in fake.puts()}
        self.assertEqual(puts, {
            "/sites/ABE8/transfer-capability": {"transferOriginEnabled": True, "transferDestinationEnabled": True},
            "/sites/XD01/transfer-capability": {"transferOriginEnabled": True, "transferDestinationEnabled": False},
            "/sites/DAT3/transfer-capability": {"transferOriginEnabled": False, "transferDestinationEnabled": False},
        })
        self.assertEqual(fake.caps["ABE8"], [True, True, 1])
        self.assertEqual(fake.caps["XD01"], [True, False, 1])
        self.assertEqual(fake.caps["DAT3"], [False, False, 3])
        self.assertEqual(fake.caps["MFC1"], [False, True, 4], "a site already at its default is never written")
        self.assertEqual(fake.caps["WH1"], [True, False, 1], "an UNSPECIFIED site is never written")
        self.assertEqual(fake.caps["WH2"], [False, False, 0], "a decommissioned site is never written")
        self.assertIn("WH1 (siteRole UNSPECIFIED", out)
        self.assertIn("needs an operator decision", out)
        self.assertIn("3 set, 0 would set, 1 unchanged, 1 need a decision, 1 not active, 0 failed", out)

    def test_never_reads_or_writes_the_capability_of_unspecified_or_inactive_sites(self):
        fake = self.fleet()
        self.run_seed(self.start(fake))
        touched = {path for _, path, _ in fake.log}
        self.assertNotIn("/sites/WH1/transfer-capability", touched)
        self.assertNotIn("/sites/WH2/transfer-capability", touched)

    def test_second_run_is_a_no_op(self):
        fake = self.fleet()
        base = self.start(fake)
        self.assertEqual(self.run_seed(base)[0], 0)
        before = {k: list(v) for k, v in fake.caps.items()}
        fake.log.clear()
        code, out = self.run_seed(base)
        self.assertEqual(code, 0, out)
        self.assertEqual(fake.puts(), [], "a converged facility-layout must see zero writes")
        self.assertEqual(fake.caps, before)
        self.assertIn("0 set, 0 would set, 4 unchanged", out)

    def test_dry_run_prints_the_plan_and_writes_nothing(self):
        fake = self.fleet()
        code, out = self.run_seed(self.start(fake), "--dry-run")
        self.assertEqual(code, 0, out)
        self.assertEqual(fake.puts(), [])
        self.assertIn("DRY RUN", out)
        self.assertIn("ABE8       would SET  NON_SORTABLE_FC: origin=no destination=no (revision 0) -> "
                      "origin=yes destination=yes", out)
        self.assertIn("DAT3       would SET  DELIVERY_STATION", out)
        self.assertIn("MFC1       unchanged  MICRO_FC", out)
        self.assertIn("0 set, 3 would set, 1 unchanged", out)

    def test_never_set_site_whose_default_is_neither_is_not_written(self):
        fake = FakeFacilityLayout(sites=[site("FG01", "FRESH_GROCERY_FC")])
        code, out = self.run_seed(self.start(fake))
        self.assertEqual(code, 0, out)
        self.assertEqual(fake.puts(), [])
        self.assertNotIn("FG01", fake.caps)

    def test_role_without_a_default_row_is_left_for_an_operator(self):
        fake = FakeFacilityLayout(sites=[site("AIR1", "AIR_HUB_GATEWAY")])
        code, out = self.run_seed(self.start(fake))
        self.assertEqual(code, 0, out)
        self.assertEqual(fake.puts(), [])
        self.assertIn("AIR1 (siteRole AIR_HUB_GATEWAY has no row", out)

    def test_concurrent_modification_is_re_read_and_retried(self):
        fake = FakeFacilityLayout(sites=[site("ABE8", "NON_SORTABLE_FC")])
        fake.lose_race["ABE8"] = 1
        code, out = self.run_seed(self.start(fake))
        self.assertEqual(code, 0, out)
        self.assertEqual(len(fake.puts()), 2)
        self.assertEqual(fake.caps["ABE8"], [True, True, 1])

    def test_concurrent_writer_that_already_set_the_target_stops_the_retry(self):
        fake = FakeFacilityLayout(sites=[site("ABE8", "NON_SORTABLE_FC")])
        fake.lose_race["ABE8"] = 1
        fake.race_winner["ABE8"] = (True, True)
        code, out = self.run_seed(self.start(fake))
        self.assertEqual(code, 0, out)
        self.assertEqual(len(fake.puts()), 1, "after the re-read shows the target, no second PUT")
        self.assertIn("set concurrently", out)

    def test_concurrent_modification_beyond_the_retry_budget_fails(self):
        fake = FakeFacilityLayout(sites=[site("ABE8", "NON_SORTABLE_FC")])
        fake.lose_race["ABE8"] = 10
        code, out = self.run_seed(self.start(fake), "--retries", "2")
        self.assertEqual(code, 1, out)
        self.assertEqual(len(fake.puts()), 3)
        self.assertIn("FAILED for: ABE8", out)

    def test_a_failed_put_exits_non_zero_but_still_reconciles_the_other_sites(self):
        fake = FakeFacilityLayout(sites=[site("ABE8", "NON_SORTABLE_FC"), site("XD01", "INBOUND_CROSS_DOCK")])
        fake.put_status["ABE8"] = 500
        code, out = self.run_seed(self.start(fake))
        self.assertEqual(code, 1, out)
        self.assertEqual(fake.caps["XD01"], [True, False, 1])
        self.assertNotIn("ABE8", fake.caps)
        self.assertIn("ABE8       FAILED", out)
        self.assertEqual(sum(1 for _, p, _ in fake.puts() if p == "/sites/ABE8/transfer-capability"), 1,
                         "a PUT that 5xx'd is never blindly repeated")

    def test_follows_nextcursor_to_the_last_page_of_sites_and_defaults(self):
        fake = self.fleet()
        fake.page_cap = 2          # 6 sites and 5 defaults: three and three pages
        code, out = self.run_seed(self.start(fake))
        self.assertEqual(code, 0, out)
        self.assertEqual({p for _, p, _ in fake.puts()},
                         {"/sites/ABE8/transfer-capability", "/sites/XD01/transfer-capability",
                          "/sites/DAT3/transfer-capability"},
                         "a site or role on a later page must still be reconciled")
        self.assertIn("defaults  : 5 roles", out)
        site_pages = [q for m, p, q in fake.queries if m == "GET" and p == "/sites"]
        self.assertEqual(len(site_pages), 3, site_pages)
        self.assertIn("cursor=c2", site_pages[1])
        self.assertIn("cursor=c4", site_pages[2])

    def test_only_sends_the_declared_collection_parameters(self):
        fake = self.fleet()
        code, out = self.run_seed(self.start(fake))
        self.assertEqual(code, 0, out)       # the fake answers 400 unknown-query-parameter otherwise
        for method, path, raw in fake.queries:
            if path in ("/sites", "/site-roles/transfer-defaults"):
                self.assertEqual(sorted(urllib.parse.parse_qs(raw)), ["limit"], (path, raw))

    def test_a_200_that_is_not_a_page_is_refused_not_read_as_empty(self):
        wrong = {
            "bare array (the retired shape)": [site("ABE8", "NON_SORTABLE_FC")],
            "retired object key": {"sites": [site("ABE8", "NON_SORTABLE_FC")]},
            "items null": {"items": None},
            "items missing": {"nextCursor": "x"},
        }
        for name, reply in wrong.items():
            with self.subTest(sites=name):
                fake = self.fleet()
                fake.sites_reply = reply
                code, out = self.run_seed(self.start(fake))
                self.assertEqual(code, 2, out)
                self.assertEqual(fake.puts(), [])
                self.assertIn("GET /sites", out)
            with self.subTest(defaults=name):
                fake = self.fleet()
                fake.defaults_reply = reply
                code, out = self.run_seed(self.start(fake))
                self.assertEqual(code, 2, out)
                self.assertEqual(fake.puts(), [])
                self.assertIn("transfer-defaults", out)

    def test_a_server_that_never_ends_the_cursor_chain_is_not_followed_forever(self):
        fake = self.fleet()
        fake.sites_reply = {"items": [site("ABE8", "NON_SORTABLE_FC")], "nextCursor": "again"}
        code, out = self.run_seed(self.start(fake))
        self.assertEqual(code, 2, out)
        self.assertEqual(fake.puts(), [])
        self.assertIn("nextCursor", out)

    def test_unreadable_defaults_table_writes_nothing_and_exits_2(self):
        fake = self.fleet()
        fake.defaults_status = 500
        code, out = self.run_seed(self.start(fake))
        self.assertEqual(code, 2, out)
        self.assertEqual(fake.puts(), [])
        self.assertIn("nothing written", out)

    def test_malformed_defaults_row_writes_nothing_and_exits_2(self):
        fake = self.fleet()
        fake.defaults = [{"siteRole": "NON_SORTABLE_FC", "transferOriginEnabled": "yes",
                          "transferDestinationEnabled": True}]
        code, out = self.run_seed(self.start(fake))
        self.assertEqual(code, 2, out)
        self.assertEqual(fake.puts(), [])

    def test_unreachable_facility_layout_exits_2(self):
        server = serve(FakeFacilityLayout(sites=[]))
        port = server.server_address[1]
        server.shutdown()
        server.server_close()
        code, out = self.run_seed(f"http://127.0.0.1:{port}{PREFIX}", "--timeout", "1")
        self.assertEqual(code, 2, out)

    def test_default_base_url_is_kong(self):
        self.assertEqual(SEED.DEFAULT_BASE_URL, "http://localhost:8000/api/facility-layout")


if __name__ == "__main__":
    unittest.main(verbosity=2)
