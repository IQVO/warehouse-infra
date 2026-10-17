#!/usr/bin/env python3
"""Unit tests for scripts/seed-transfer-lanes.py against a fake facility-layout + NIP.

Run from the repo root (stdlib only, no cluster needed):

    python3 scripts/test_seed_transfer_lanes.py

Both fakes are real HTTP servers on 127.0.0.1 serving the contract the seed uses:

  facility-layout  GET /sites, GET /sites/{code}/transfer-capability
  NIP              GET /v1/transfer-lanes, PUT /v1/transfer-lanes (CREATED 201 / UPDATED 200 /
                   UNCHANGED 200, 422 for a lane to itself)
"""
import contextlib
import importlib.util
import io
import json
import os
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DAY = 86_400 * 1_000_000_000


def load_seed():
    path = os.path.join(REPO_ROOT, "scripts", "seed-transfer-lanes.py")
    spec = importlib.util.spec_from_file_location("seed_transfer_lanes", path)
    assert spec is not None and spec.loader is not None, path
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


SEED = load_seed()

# city-centre coordinates, roughly real: three US east-coast sites, one far west, one Canadian
COORDS = {
    "PHL7": {"city": "Philadelphia", "region": "PA", "country": "US", "lat": 39.95, "lon": -75.17},
    "JFK8": {"city": "Staten Island", "region": "NY", "country": "US", "lat": 40.58, "lon": -74.15},
    "BOS7": {"city": "Fall River", "region": "MA", "country": "US", "lat": 41.70, "lon": -71.15},
    "SEA8": {"city": "Kent", "region": "WA", "country": "US", "lat": 47.38, "lon": -122.23},
    "YYZ4": {"city": "Brampton", "region": "ON", "country": "CA", "lat": 43.73, "lon": -79.76},
}
SITES = [{"siteCode": c, "name": c, "status": "Active"} for c in [*COORDS, "DAT3", "SIM1"]]
CAPS = {  # origin, destination
    "PHL7": (True, True), "JFK8": (True, True), "BOS7": (True, False), "SEA8": (True, True),
    "YYZ4": (True, True), "DAT3": (False, False), "SIM1": (True, True),
}


class Fakes:
    def __init__(self):
        self.lanes = {}        # (o, d) -> [lane, revision]
        self.log = []          # (method, path, body)
        self.fail_put = set()  # (o, d) whose PUT answers 500
        self.lock = threading.Lock()

    def handler(self, kind):
        fakes = self

        class H(BaseHTTPRequestHandler):
            def log_message(self, *a):
                pass

            def _send(self, status, body):
                raw = json.dumps(body).encode()
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(raw)))
                self.end_headers()
                self.wfile.write(raw)

            def do_GET(self):
                with fakes.lock:
                    fakes.log.append(("GET", self.path, None))
                    if kind == "facility" and self.path == "/sites":
                        return self._send(200, SITES)
                    if kind == "facility" and self.path.endswith("/transfer-capability"):
                        code = self.path.split("/")[2]
                        o, d = CAPS.get(code, (False, False))
                        return self._send(200, {"siteCode": code, "transferOriginEnabled": o,
                                                "transferDestinationEnabled": d, "capabilityRevision": 1})
                    if kind == "nip" and self.path == "/v1/transfer-lanes":
                        return self._send(200, {"lanes": [{"lane": l, "revision": r, "updatedAt": "2026-10-17T00:00:00Z"}
                                                          for l, r in fakes.lanes.values()]})
                self._send(404, {"status": 404})

            def do_PUT(self):
                body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))) or b"{}")
                with fakes.lock:
                    fakes.log.append(("PUT", self.path, body))
                    key = (body["Origin"], body["Destination"])
                    if key in fakes.fail_put:
                        return self._send(500, {"status": 500})
                    if body["Origin"] == body["Destination"]:
                        return self._send(422, {"status": 422})
                    prev = fakes.lanes.get(key)
                    if prev and prev[0] == body:
                        return self._send(200, {"lane": body, "revision": prev[1], "outcome": "UNCHANGED"})
                    rev = prev[1] + 1 if prev else 1
                    fakes.lanes[key] = [body, rev]
                    return self._send(200 if prev else 201, {"lane": body, "revision": rev,
                                                             "outcome": "UPDATED" if prev else "CREATED"})
        return H


@contextlib.contextmanager
def cluster():
    fakes = Fakes()
    servers = []
    urls = {}
    for kind in ("facility", "nip"):
        srv = ThreadingHTTPServer(("127.0.0.1", 0), fakes.handler(kind))
        threading.Thread(target=srv.serve_forever, daemon=True).start()
        servers.append(srv)
        urls[kind] = f"http://127.0.0.1:{srv.server_address[1]}"
    try:
        yield fakes, urls
    finally:
        for s in servers:
            s.shutdown()
            s.server_close()


def coords_file(coords=None):
    f = tempfile.NamedTemporaryFile("w", suffix=".json", delete=False)
    json.dump({"sites": COORDS if coords is None else coords}, f)
    f.close()
    return f.name


def run(urls, *extra, coords=None):
    out, err = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        code = SEED.main(["--facility-url", urls["facility"], "--nip-url", urls["nip"],
                          "--coordinates", coords or coords_file(), *extra])
    return code, out.getvalue(), err.getvalue()


class GeographyTests(unittest.TestCase):
    def test_location_is_the_last_parenthesis_of_the_site_name(self):
        p = SEED.parse_location
        self.assertEqual(p("BFI4 - Robotics Sortable Fulfillment Center (Kent, WA)"), {"city": "Kent", "region": "WA", "country": "US"})
        self.assertEqual(p("CHA2 - XL (Extra-Large) Fulfillment Center (Chattanooga, TN)")["city"], "Chattanooga")
        self.assertEqual(p("KCVG - Air Hub Gateway (Hebron, KY (CVG airport))"), {"city": "Hebron", "region": "KY", "country": "US"})
        self.assertEqual(p("GRU9 - Sortation Center (Cajamar, SP, BR)"), {"city": "Cajamar", "region": "SP", "country": "BR"})
        self.assertEqual(p("LTN4 - Robotics Sortable Fulfillment Center (Dunstable, GB)"), {"city": "Dunstable", "region": "", "country": "GB"})
        self.assertIsNone(p("Simulated FC"))

    def test_de_is_germany_not_delaware(self):
        self.assertEqual(SEED.parse_location("FRA3 - Robotics Sortable Fulfillment Center (Bad Hersfeld, DE)")["country"], "DE")

    def test_distance_and_the_lane_economics(self):
        km = SEED.haversine_km((39.95, -75.17), (40.58, -74.15))     # Philadelphia - Staten Island
        self.assertTrue(80 < km < 130, km)
        self.assertEqual(SEED.lead_time_days(0.5), 2)
        self.assertEqual(SEED.lead_time_days(801), 3)
        self.assertEqual(SEED.unit_handling_cost(100), 2)
        self.assertEqual(SEED.unit_handling_cost(401), 3)


class ComputeTests(unittest.TestCase):
    def test_k_nearest_same_country_and_never_to_itself(self):
        origins = {"PHL7", "BOS7"}
        dests = {"PHL7", "JFK8", "SEA8", "YYZ4"}
        lanes, isolated = SEED.compute_lanes(origins, dests, COORDS, neighbours=2, max_km=5000)
        pairs = [(l["Origin"], l["Destination"]) for l in lanes]
        self.assertEqual(pairs, [("BOS7", "JFK8"), ("BOS7", "PHL7"), ("PHL7", "JFK8"), ("PHL7", "SEA8")])
        self.assertNotIn("YYZ4", [d for _, d in pairs], "no cross-border lanes")
        self.assertEqual(isolated, [])

    def test_max_km_and_isolated_origins(self):
        lanes, isolated = SEED.compute_lanes({"SEA8", "YYZ4"}, {"PHL7", "JFK8", "YYZ4"}, COORDS, neighbours=4, max_km=1000)
        self.assertEqual(lanes, [])
        self.assertEqual(isolated, ["SEA8", "YYZ4"])

    def test_lane_body_matches_nips_wire_shape(self):
        lane = SEED.compute_lanes({"PHL7"}, {"JFK8"}, COORDS, 4, 2500)[0][0]
        self.assertEqual(set(lane), {"Origin", "Destination", "LeadTime", "UnitHandlingCost", "Enabled"})
        self.assertTrue(lane["Enabled"])
        self.assertEqual(lane["LeadTime"] % DAY, 0)      # whole days, in nanoseconds (Go time.Duration)
        self.assertEqual(lane["LeadTime"], 2 * DAY)


class SeedTests(unittest.TestCase):
    def test_creates_lanes_only_between_capable_sites_then_is_idempotent(self):
        with cluster() as (fakes, urls):
            code, out, _ = run(urls)
            self.assertEqual(code, 0, out)
            for o, d in fakes.lanes:
                self.assertTrue(CAPS[o][0], f"{o} may not send")
                self.assertTrue(CAPS[d][1], f"{d} may not receive")
                self.assertEqual(COORDS[o]["country"], COORDS[d]["country"])
            self.assertIn("NO LANES for SIM1", out)
            self.assertNotIn("DAT3", " ".join(f"{o}{d}" for o, d in fakes.lanes))
            puts = [e for e in fakes.log if e[0] == "PUT"]
            self.assertEqual(len(puts), len(fakes.lanes))
            fakes.log.clear()
            code, out, _ = run(urls)
            self.assertEqual(code, 0)
            self.assertEqual([e for e in fakes.log if e[0] == "PUT"], [], "a second run writes nothing")
            self.assertIn("0 created, 0 updated", out)

    def test_dry_run_writes_nothing(self):
        with cluster() as (fakes, urls):
            code, out, _ = run(urls, "--dry-run")
            self.assertEqual(code, 0)
            self.assertEqual(fakes.lanes, {})
            self.assertIn("would CREATE", out)

    def test_a_drifted_lane_is_updated_and_an_unknown_lane_is_left_alone(self):
        with cluster() as (fakes, urls):
            run(urls)
            fakes.lanes[("PHL7", "JFK8")][0]["UnitHandlingCost"] = 99          # drift
            fakes.lanes[("DAT3", "PHL7")] = [{"Origin": "DAT3", "Destination": "PHL7", "LeadTime": DAY,
                                              "UnitHandlingCost": 1, "Enabled": True}, 1]   # operator's own lane
            fakes.log.clear()
            code, out, _ = run(urls)
            self.assertEqual(code, 0)
            puts = [e[2] for e in fakes.log if e[0] == "PUT"]
            self.assertEqual([(p["Origin"], p["Destination"]) for p in puts], [("PHL7", "JFK8")])
            self.assertEqual(fakes.lanes[("PHL7", "JFK8")][1], 2)
            self.assertIn("DAT3 -> PHL7", out)
            self.assertIn(("DAT3", "PHL7"), fakes.lanes)

    def test_a_disabled_lane_is_re_enabled(self):
        with cluster() as (fakes, urls):
            run(urls)
            fakes.lanes[("PHL7", "JFK8")][0]["Enabled"] = False
            run(urls)
            self.assertTrue(fakes.lanes[("PHL7", "JFK8")][0]["Enabled"])

    def test_a_failed_put_exits_1_but_the_others_land(self):
        with cluster() as (fakes, urls):
            fakes.fail_put.add(("PHL7", "JFK8"))
            code, out, _ = run(urls)
            self.assertEqual(code, 1)
            self.assertIn("FAILED PHL7 -> JFK8", out)
            self.assertGreater(len(fakes.lanes), 0)

    def test_unreadable_inputs_exit_2_and_write_nothing(self):
        with cluster() as (fakes, urls):
            code, _, err = run(urls, coords="/nonexistent/coords.json")
            self.assertEqual(code, 2)
            self.assertIn("cannot read coordinates", err)
            self.assertEqual(fakes.lanes, {})
        code, _, err = run({"facility": "http://127.0.0.1:1", "nip": "http://127.0.0.1:1"})
        self.assertEqual(code, 2)

    def test_neighbours_flag(self):
        with cluster() as (fakes, urls):
            run(urls, "--neighbours", "1")
            out_degree = {}
            for o, _ in fakes.lanes:
                out_degree[o] = out_degree.get(o, 0) + 1
            self.assertTrue(all(n == 1 for n in out_degree.values()), out_degree)


class RefreshCoordinatesTests(unittest.TestCase):
    def test_only_missing_active_sites_are_geocoded(self):
        path = coords_file({"PHL7": COORDS["PHL7"]})
        asked = []

        def fake(loc):
            asked.append(loc["city"])
            return {"lat": "40.0", "lon": "-75.0", "display_name": "x"}

        sites = [{"siteCode": "PHL7", "name": "PHL7 - FC (Philadelphia, PA)", "status": "Active"},
                 {"siteCode": "NEW1", "name": "NEW1 - FC (Scranton, PA)", "status": "Active"},
                 {"siteCode": "OLD1", "name": "OLD1 - FC (Erie, PA)", "status": "Decommissioned"},
                 {"siteCode": "SIM1", "name": "Simulated FC", "status": "Active"}]
        with contextlib.redirect_stdout(io.StringIO()):
            added = SEED.refresh_coordinates(sites, path, pause_s=0, fetch=fake)
        self.assertEqual(added, ["NEW1"])
        self.assertEqual(asked, ["Scranton"])
        self.assertEqual(sorted(SEED.load_coordinates(path)), ["NEW1", "PHL7"])


if __name__ == "__main__":
    unittest.main()
