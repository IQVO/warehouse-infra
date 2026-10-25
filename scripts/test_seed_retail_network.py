#!/usr/bin/env python3
"""Unit tests for scripts/seed-retail-network.py against an in-process fake of the retail network.

Run from the repo root (stdlib only, no cluster needed, nothing is ever sent to a real service):

    python3 scripts/test_seed_retail_network.py

The fake is ONE real HTTP server on 127.0.0.1 that serves the contract the seed uses, routed by
the Kong prefix /api/<context>, with the behaviour the specs promise (each service's
apis/openapi.yaml on its develop branch):

  node-topology        regions, nodes (+ :activate), operational profile, lanes, service areas
  vendor-connectivity  vendors, ASYNCHRONOUS node registration / profile / inventory (202 +
                       transactionId, polled), the vendor's node view
  offer-availability   catalogue (keyset paged), listings (LIVE only on an ACTIVE node), feeds
  last-mile-delivery   waves (station must be a delivery station)
  delivery-promise     the default policy v0, the quote
  linehaul-transport.  PICKUP departures of an ACTIVE node with an outbound lane
"""
import contextlib
import copy
import importlib.util
import io
import json
import os
import tempfile
import threading
import unittest
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DATA_FILE = os.path.join(REPO_ROOT, "scripts", "data", "retail-network-seed.json")
NOW = "2026-10-24T16:00:00Z"        # Saturday 11:00 in America/Chicago (CDT, UTC-5)


def load_seed():
    path = os.path.join(REPO_ROOT, "scripts", "seed-retail-network.py")
    spec = importlib.util.spec_from_file_location("seed_retail_network", path)
    assert spec is not None and spec.loader is not None, path
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


SEED = load_seed()


def problem(status, slug, title="problem"):
    return status, {"type": slug, "title": title, "status": status}


class Fake:
    """The retail network, in memory."""

    def __init__(self):
        self.lock = threading.RLock()
        self.log = []                 # (method, path, body, idempotency key)
        self.n = 0
        self.regions, self.nodes, self.lanes, self.areas = [], {}, [], {}
        self.vendors, self.txs, self.idem = {}, {}, {}
        self.items, self.listings, self.waves, self.feeds = [], {}, [], []
        self.once = {}                # (METHOD, path prefix) -> [(status, body, headers)] answered first
        self.always = {}              # (METHOD, path prefix) -> (status, body)
        self.fail_tx = {}             # transaction kind -> error codes
        self.tx_polls = 2
        self.hide_regions = 0         # the next N GET /regions answer [] (the preflight is the first)
        self.page = 2                 # keyset page size, small on purpose

    def next_id(self, prefix):
        self.n += 1
        return f"{prefix}-{self.n}"

    # ---- helpers for the tests
    def writes(self):
        return [e for e in self.log if e[0] != "GET"]

    def node_by_code(self, code):
        return next((n for n in self.nodes.values() if (n.get("vendorRef") or {}).get("vendorNodeCode") == code), None)

    def add_vendor_node(self, code="SIM1", status="PROPOSED", revision=None, region=None):
        region = region or self.add_region()
        nid = self.next_id("node")
        node = {"nodeId": nid, "nodeType": "FULFILLMENT_CENTER", "subtype": "SORTABLE", "operator": "VENDOR",
                "vendorRef": {"vendorId": "V-WS", "vendorNodeCode": code}, "regionId": region["regionId"],
                "timezone": "America/Chicago", "location": {"postalCode": "78701", "countryCode": "US"},
                "capabilities": {"outbound": True}, "status": status}
        if revision:
            node["operationalProfile"] = {"profileRevision": revision, "handlingTimeMinutes": 30, "cutoffs": [{"localTime": "11:00"}]}
        self.nodes[nid] = node
        self.vendors.setdefault("V-WS", {"vendorId": "V-WS", "name": "x", "ackWindowMinutes": 240, "state": "ACTIVE"})
        return node

    def add_region(self, code="SIM-SC"):
        r = next((r for r in self.regions if r["code"] == code), None)
        if not r:
            r = {"regionId": self.next_id("region"), "code": code, "name": "x"}
            self.regions.append(r)
        return r

    # ---- dispatch
    def handle(self, method, raw_path, body, key):
        parsed = urllib.parse.urlsplit(raw_path)
        qu = {k: v[0] for k, v in urllib.parse.parse_qs(parsed.query).items()}
        with self.lock:
            self.log.append((method, raw_path, body, key))
            for (m, prefix), queue in self.once.items():
                if m == method and parsed.path.startswith(prefix) and queue:
                    return queue.pop(0)
            for (m, prefix), (st, b) in self.always.items():
                if m == method and parsed.path.startswith(prefix):
                    return st, b, {}
            parts = parsed.path.strip("/").split("/", 2)           # api, <context>, rest
            ctx, rest = parts[1], "/" + (parts[2] if len(parts) > 2 else "")
            if method != "GET" and key and (method, parsed.path, key) in self.idem:
                return (*self.idem[(method, parsed.path, key)], {})
            out = getattr(self, "c_" + ctx.replace("-", "_"))(method, rest, qu, body)
            status, resp = out[0], out[1]
            if method != "GET" and key and status < 500:
                self.idem[(method, parsed.path, key)] = (status, resp)
            return status, resp, {}

    # ---- node-topology
    def public(self, n, profile=True):
        n = copy.deepcopy(n)
        if not profile:
            n.pop("operationalProfile", None)
        return n

    def c_node_topology(self, m, rest, qu, body):
        p = rest.strip("/").split("/")
        if p == ["regions"]:
            if m == "GET":
                if self.hide_regions:
                    self.hide_regions -= 1
                    return 200, []
                return 200, list(self.regions)
            if any(r["code"] == body.get("code") for r in self.regions):
                return problem(409, "region-code-taken")
            r = {"regionId": self.next_id("region"), "code": body["code"], "name": body["name"]}
            self.regions.append(r)
            return 201, r
        if p == ["nodes"]:
            if m == "GET":
                return 200, {"nodes": [self.public(n, False) for n in self.nodes.values()
                                       if qu.get("type") in (None, n["nodeType"]) and qu.get("region") in (None, n["regionId"])]}
            return self.register_node(body)
        if p[0] == "nodes" and len(p) == 2 and p[1].endswith(":activate"):
            return self.activate(p[1][:-len(":activate")])
        if p[0] == "nodes" and len(p) == 2 and m == "GET":
            return (200, self.public(self.nodes[p[1]])) if p[1] in self.nodes else problem(404, "not-found")
        if p == ["lanes"]:
            if m == "GET":
                return 200, {"lanes": [l for l in self.lanes if qu.get("origin") in (None, l["originNodeId"])
                                       and qu.get("destination") in (None, l["destinationNodeId"])]}
            return self.open_lane(body)
        if p[0] == "service-areas":
            return self.service_area(m, p[1], body)
        raise AssertionError(f"fake node-topology: unhandled {m} {rest}")

    def register_node(self, b):
        if b["operator"] == "VENDOR" and not b.get("vendorRef"):
            return problem(422, "validation-failed")
        if b["nodeType"] in ("DELIVERY_STATION", "SORTATION_CENTER", "AIR_HUB") and b["operator"] != "NETWORK":
            return problem(422, "operator-not-allowed-for-node-type")
        if not any(r["regionId"] == b["regionId"] for r in self.regions):
            return problem(422, "unknown-region")
        if b.get("vendorRef") and self.node_by_code(b["vendorRef"]["vendorNodeCode"]):
            return problem(409, "vendor-node-code-taken")
        nid = self.next_id("node")
        node = {"nodeId": nid, "nodeType": b["nodeType"], "operator": b["operator"], "regionId": b["regionId"],
                "timezone": b["timezone"], "location": b["location"], "capabilities": {}, "status": "PROPOSED"}
        for k in ("subtype", "vendorRef"):
            if b.get(k):
                node[k] = b[k]
        self.nodes[nid] = node
        return 201, self.public(node)

    def activate(self, nid):
        n = self.nodes.get(nid)
        if not n:
            return problem(404, "not-found")
        if n["status"] not in ("PROPOSED", "SUSPENDED"):
            return problem(409, "illegal-transition")
        if n["nodeType"] == "FULFILLMENT_CENTER" and not n.get("operationalProfile"):
            return problem(409, "incomplete-operational-profile")
        n["status"] = "ACTIVE"
        return 200, self.public(n)

    def open_lane(self, b):
        o, d = self.nodes.get(b["originNodeId"]), self.nodes.get(b["destinationNodeId"])
        if not o or not d:
            return problem(404, "not-found")
        if o["status"] != "ACTIVE" or d["status"] != "ACTIVE":
            return problem(409, "lane-endpoint-not-active")
        if (o["nodeType"], d["nodeType"]) != ("FULFILLMENT_CENTER", "DELIVERY_STATION"):
            return problem(422, "lane-type-pair-not-allowed")
        if any(l["originNodeId"] == o["nodeId"] and l["destinationNodeId"] == d["nodeId"] and l["status"] == "OPEN" for l in self.lanes):
            return problem(409, "duplicate-lane")
        lane = {**b, "laneId": self.next_id("lane"), "status": "OPEN"}
        self.lanes.append(lane)
        return 201, lane

    def service_area(self, m, prefix, b):
        cur = self.areas.get(prefix)
        if m == "GET":
            return (200, cur) if cur else problem(404, "not-found")
        st = self.nodes.get(b["deliveryStationNodeId"])
        if not st or st["nodeType"] != "DELIVERY_STATION" or st["status"] != "ACTIVE":
            return problem(409, "not-a-delivery-station")
        if cur and b["assignmentVersion"] <= cur["assignmentVersion"]:
            return problem(409, "stale-assignment-version")
        self.areas[prefix] = {"postalPrefix": prefix, "deliveryStationNodeId": st["nodeId"], "regionId": st["regionId"],
                              "assignmentVersion": b["assignmentVersion"]}
        return 200, self.areas[prefix]

    # ---- vendor-connectivity (asynchronous writes, polled)
    def c_vendor_connectivity(self, m, rest, qu, body):
        p = rest.strip("/").split("/")
        if p[0] == "vendors":
            if m == "POST":
                if body["vendorId"] in self.vendors:
                    return 200, self.vendors[body["vendorId"]]
                self.vendors[body["vendorId"]] = {**body, "state": "ACTIVE"}
                return 201, self.vendors[body["vendorId"]]
            v = self.vendors.get(p[1])
            return (200, v) if v else problem(404, "not-found")
        if p == ["vendor", "nodes"] and m == "POST":
            return self.accept("NODE_REGISTRATION", body)
        if p[:2] == ["vendor", "inventory"]:
            return self.accept("INVENTORY", body)
        if p[:2] == ["vendor", "nodes"] and len(p) == 4 and p[3] == "profile":
            return self.accept("NODE_PROFILE", {**body, "nodeId": p[2]})
        if p[:2] == ["vendor", "nodes"] and len(p) == 3:
            n = self.nodes.get(p[2])
            if not n or (n.get("vendorRef") or {}).get("vendorId") != qu.get("vendorId"):
                return problem(404, "not-found")
            prof = n.get("operationalProfile") or {}
            return 200, {"nodeId": p[2], "vendorId": qu["vendorId"], "vendorNodeCode": n["vendorRef"]["vendorNodeCode"],
                         "nodeType": n["nodeType"], "status": n["status"], "profileRevision": prof.get("profileRevision"),
                         "handlingTimeMinutes": prof.get("handlingTimeMinutes")}
        if p[:2] == ["vendor", "transactions"]:
            tx = self.txs.get(p[2])
            if not tx:
                return problem(404, "not-found")
            tx["polls"] += 1
            if tx["status"] == "PROCESSING" and tx["polls"] >= self.tx_polls:
                self.finish(tx)
            return 200, {k: v for k, v in tx.items() if k not in ("polls", "body")}
        raise AssertionError(f"fake vendor-connectivity: unhandled {m} {rest}")

    def accept(self, kind, body):
        if body.get("vendorId") not in self.vendors:
            return problem(404, "not-found")
        tid = self.next_id("tx")
        self.txs[tid] = {"transactionId": tid, "vendorId": body["vendorId"], "kind": kind, "status": "PROCESSING",
                         "errors": [], "polls": 0, "body": body}
        return 202, {"transactionId": tid}

    def finish(self, tx):
        b, kind = tx["body"], tx["kind"]
        codes = list(self.fail_tx.get(kind, []))
        if not codes:
            if kind == "NODE_REGISTRATION":
                if self.node_by_code(b["vendorNodeCode"]):
                    codes = ["ErrVendorNodeCodeTaken"]
                else:
                    node = {"nodeId": self.next_id("node"), "nodeType": b["nodeType"], "operator": "VENDOR", "regionId": b["regionId"],
                            "vendorRef": {"vendorId": b["vendorId"], "vendorNodeCode": b["vendorNodeCode"]},
                            "timezone": b["timezone"], "location": {"postalCode": b["postalCode"], "countryCode": b["countryCode"]},
                            "capabilities": {}, "status": "PROPOSED"}
                    if b.get("subtype"):
                        node["subtype"] = b["subtype"]
                    self.nodes[node["nodeId"]] = node
                    tx["nodeId"] = node["nodeId"]
            elif kind == "NODE_PROFILE":
                n = self.nodes[b["nodeId"]]
                if b["profileRevision"] <= (n.get("operationalProfile") or {}).get("profileRevision", 0):
                    codes = ["ErrStaleProfileRevision"]
                else:
                    n["operationalProfile"] = {k: v for k, v in b.items() if k not in ("vendorId", "nodeId")}
            else:
                codes = self.apply_feed(b)
        tx["status"] = "FAILURE" if codes else "SUCCESS"
        tx["errors"] = [{"code": c, "message": c} for c in codes]

    def apply_feed(self, b):
        mine = {lid: l for lid, l in self.listings.items() if l["nodeId"] == b["nodeId"]}
        if any(line["listingId"] not in mine for line in b["lines"]):
            return ["ErrListingNotOnNode"]
        self.feeds.append(copy.deepcopy(b))
        fid = self.next_id("feed")
        sent = {line["listingId"]: line for line in b["lines"]}
        for lid, l in mine.items():
            if lid in sent:
                l["availability"] = {"availableQty": sent[lid]["availableQty"], "basis": sent[lid]["basis"], "asOf": b["asOf"], "feedId": fid}
            elif b["fullUpdate"]:
                l["availability"] = {**l["availability"], "availableQty": 0, "asOf": b["asOf"], "feedId": fid}
        return []

    # ---- offer-availability
    def keyset(self, rows, key, qu, field):
        after = qu.get("after")
        rows = sorted(rows, key=lambda r: r[key])
        rows = [r for r in rows if after is None or r[key] > after]
        size = min(int(qu.get("limit", 100)), self.page)
        out = {field: rows[:size]}
        if len(rows) > size:
            out["nextCursor"] = rows[size - 1][key]
        return 200, out

    def c_offer_availability(self, m, rest, qu, body):
        p = rest.strip("/").split("/")
        if p == ["catalog"]:
            return self.keyset(self.items, "catalogItemId", qu, "items")
        if p == ["catalog-items"]:
            if min(body["lengthMm"], body["widthMm"], body["heightMm"], body["weightG"]) < 1:
                return problem(422, "invalid-item-dimensions")
            it = {**body, "catalogItemId": f"item-{len(self.items) + 1:03d}", "state": "ACTIVE"}
            self.items.append(it)
            return 201, it
        if p == ["listings"] and m == "GET":
            rows = [l for l in self.listings.values() if qu.get("nodeId") in (None, l["nodeId"])]
            return self.keyset(rows, "listingId", qu, "listings")
        if p == ["listings"]:
            if any(l["nodeId"] == body["nodeId"] and l["catalogItemId"] == body["catalogItemId"] for l in self.listings.values()):
                return problem(409, "duplicate-listing")
            node = self.nodes.get(body["nodeId"])
            live = bool(node) and node["status"] == "ACTIVE"
            lid = f"lst-{len(self.listings) + 1:03d}"
            l = {"listingId": lid, "catalogItemId": body["catalogItemId"], "nodeId": body["nodeId"],
                 "state": "LIVE" if live else "SUPPRESSED", "availability": {"availableQty": 0, "basis": "UNKNOWN"}}
            if not live:
                l["suppressionReason"] = "NODE_NOT_SELLABLE"
            self.listings[lid] = l
            return 201, l
        raise AssertionError(f"fake offer-availability: unhandled {m} {rest}")

    # ---- last-mile-delivery
    def c_last_mile_delivery(self, m, rest, qu, body):
        if m == "GET":
            return 200, {"items": [w for w in self.waves if w["stationNodeId"] == qu["stationNodeId"] and w["serviceDate"] == qu["serviceDate"]]}
        st = self.nodes.get(body["stationNodeId"])
        if not st or st["nodeType"] != "DELIVERY_STATION":
            return problem(422, "unknown-station")
        if not body["inductCutoffAt"] < body["windowStart"] < body["windowEnd"]:
            return problem(422, "invalid-wave-times")
        w = {**body, "waveId": self.next_id("wave"), "assignedStops": 0, "remainingStops": body["stopCapacity"], "state": "OPEN"}
        self.waves.append(w)
        return 201, w

    # ---- delivery-promise
    def c_delivery_promise(self, m, rest, qu, body):
        if rest == "/promise-policies/current":
            return 200, {"policyVersion": "v0", "version": 0, "offerTtlMinutes": 10, "holdTtlMinutes": 15, "packagesPerOrder": 1,
                         "capacitySharePercent": 100, "orderDeadlines": [], "publishedAt": "0001-01-01T00:00:00Z"}
        if rest == "/delivery-offers:quote":
            served = body["destinationPostalPrefix"] in self.areas
            stocked = all(any(l["catalogItemId"] == line["catalogItemId"] and l["state"] == "LIVE" and l["availability"]["availableQty"] >= line["quantity"]
                              for l in self.listings.values()) for line in body["lines"])
            if served and stocked:
                return 200, {"offers": [{"offerId": "offer-1", "tier": "NEXT_DAY"}, {"offerId": "offer-2", "tier": "STANDARD"}], "unavailable": []}
            return 200, {"offers": [], "unavailable": [{"tier": "STANDARD", "constraint": "DESTINATION_NOT_SERVED" if not served else "ITEM_QUANTITY_NOT_AVAILABLE"}]}
        raise AssertionError(f"fake delivery-promise: unhandled {m} {rest}")

    # ---- linehaul-transportation
    def c_linehaul_transportation(self, m, rest, qu, body):
        n = self.nodes.get(qu.get("origin", ""))
        if n and n["status"] == "ACTIVE" and n.get("operationalProfile") and any(l["originNodeId"] == n["nodeId"] and l["status"] == "OPEN" for l in self.lanes):
            return 200, {"departures": [{"departureId": "dep-1", "kind": "PICKUP", "state": "SCHEDULED", "originNodeId": n["nodeId"]}]}
        return 200, {"departures": []}


@contextlib.contextmanager
def network():
    fake = Fake()

    class H(BaseHTTPRequestHandler):
        def log_message(self, *a):
            pass

        def _do(self):
            raw = self.rfile.read(int(self.headers.get("Content-Length", 0) or 0))
            body = json.loads(raw) if raw else None
            out = fake.handle(self.command, self.path, body, self.headers.get("Idempotency-Key"))
            status, resp, headers = out
            if isinstance(resp, str):                       # a non-JSON answer (a Kong SPA fallback, say)
                payload, ctype = resp.encode(), "text/html"
            else:
                payload, ctype = json.dumps(resp).encode(), "application/problem+json" if status >= 400 else "application/json"
            self.send_response(status)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(payload)))
            for k, v in headers.items():
                self.send_header(k, v)
            self.end_headers()
            self.wfile.write(payload)

        do_GET = do_POST = do_PUT = _do

    srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    try:
        yield fake, f"http://127.0.0.1:{srv.server_address[1]}/api"
    finally:
        srv.shutdown()
        srv.server_close()


def run(base, *extra, now=NOW):
    out, err = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        code = SEED.main(["--base-url", base, "--settle-seconds", "0", "--tx-poll-seconds", "0", "--now", now, *extra])
    return code, out.getvalue(), err.getvalue()


def data_file(mutate):
    with open(DATA_FILE, encoding="utf-8") as src:
        cfg = json.load(src)
    mutate(cfg)
    f = tempfile.NamedTemporaryFile("w", suffix=".json", delete=False)
    json.dump(cfg, f)
    f.close()
    return f.name


class SeedTests(unittest.TestCase):
    def test_seeds_an_empty_network_then_a_second_run_writes_nothing(self):
        with network() as (fake, base):
            code, out, _ = run(base)
            self.assertEqual(code, 0, out)
            self.assertEqual([r["code"] for r in fake.regions], ["SIM-SC"])
            kinds = sorted(n["nodeType"] for n in fake.nodes.values())
            self.assertEqual(kinds, ["DELIVERY_STATION", "FULFILLMENT_CENTER"])
            fc = fake.node_by_code("SIM1")
            self.assertEqual((fc["status"], fc["operationalProfile"]["profileRevision"]), ("ACTIVE", 1))
            self.assertEqual(len(fake.lanes), 1)
            self.assertEqual(sorted(fake.areas), ["786", "787"])
            self.assertEqual(len(fake.waves), 14)
            self.assertEqual(len(fake.items), 5)
            self.assertEqual(len(fake.listings), 5)
            for l in fake.listings.values():
                self.assertEqual((l["state"], l["availability"]["availableQty"], l["availability"]["basis"]), ("LIVE", 200, "PHYSICAL"))
            self.assertEqual(list(fake.vendors), ["V-WS"])
            self.assertNotIn("FAIL", out.split("CHECK")[1].replace("PASS", ""), out)
            self.assertIn("verify: 12/12 checks passed", out)

            fake.log.clear()
            code, out, _ = run(base)
            self.assertEqual(code, 0, out)
            self.assertEqual(fake.writes(), [], "a second run sends no write at all")
            self.assertIn("0 created, 0 updated", out)
            self.assertNotIn("FAILED", out)

    def test_every_write_carries_an_idempotency_key(self):
        with network() as (fake, base):
            run(base)
            writes = fake.writes()
            self.assertGreater(len(writes), 30)
            self.assertTrue(all(w[3] and w[3].startswith("seed-rn:") and len(w[3]) <= 128 for w in writes), [w for w in writes if not w[3]])
            self.assertEqual(len({(w[0], w[1], w[3]) for w in writes}), len(writes), "no two writes share a key")

    def test_dry_run_sends_no_write_and_plans_everything(self):
        with network() as (fake, base):
            code, out, _ = run(base, "--dry-run")
            self.assertEqual(code, 0, out)
            self.assertEqual(fake.writes(), [])
            self.assertEqual((fake.regions, fake.nodes, fake.items), ([], {}, []))
            for what in ("would CREATE   region SIM-SC", "would CREATE   vendor V-WS", "would CREATE   fulfillment node SIM1",
                         "would DECLARE  profile r1 of SIM1", "would ACTIVATE", "would CREATE   lane SIM1 -> DS-SIM-1",
                         "would CREATE   service area 787", "would CREATE   wave DS-SIM-1", "would CREATE   catalogue item ABO-B000B5KPG8",
                         "would CREATE   listing ABO-B000B5KPG8 @ SIM1", "would FEED"):
                self.assertIn(what, out)
            self.assertNotIn("FAILED", out)

    def test_dry_run_of_a_seeded_network_plans_nothing(self):
        with network() as (fake, base):
            run(base)
            fake.log.clear()
            code, out, _ = run(base, "--dry-run")
            self.assertEqual(code, 0, out)
            self.assertNotIn("would", out.replace("would be", ""))
            self.assertEqual(fake.writes(), [])

    def test_verify_is_read_only_fails_on_an_empty_network_and_passes_once_seeded(self):
        with network() as (fake, base):
            code, out, _ = run(base, "--verify")
            self.assertEqual(code, 1, out)
            self.assertIn("FAIL", out)
            self.assertEqual(fake.writes(), [])
            run(base)
            fake.log.clear()
            code, out, _ = run(base, "--verify")
            self.assertEqual(code, 0, out)
            self.assertEqual(fake.writes(), [])
            self.assertIn("pickup departures of SIM1", out)
            self.assertIn("profileRevision 1 (seed 1)", out)
            self.assertIn("ABO-B000B5KPG8=200", out)

    def test_verify_quote_is_the_only_post_and_reports_the_tiers(self):
        with network() as (fake, base):
            run(base)
            fake.log.clear()
            code, out, _ = run(base, "--verify", "--quote")
            self.assertEqual(code, 0, out)
            posts = fake.writes()
            self.assertEqual([(w[0], w[1].split("?")[0]) for w in posts], [("POST", "/api/delivery-promise/delivery-offers:quote")])
            self.assertIn("offers: NEXT_DAY, STANDARD", out)

    def test_verify_fails_when_a_listing_is_not_purchasable(self):
        with network() as (fake, base):
            run(base)
            next(iter(fake.listings.values()))["availability"]["availableQty"] = 0
            code, out, _ = run(base, "--verify")
            self.assertEqual(code, 1)
            self.assertIn("listings of SIM1 LIVE with stock", out)

    # ---- adoption and revisions (the fleet's ADR 0026 / 0027 contract)
    def test_adopts_an_existing_node_with_the_same_vendor_node_code(self):
        with network() as (fake, base):
            node = fake.add_vendor_node("SIM1")
            code, out, _ = run(base)
            self.assertEqual(code, 0, out)
            self.assertEqual([w for w in fake.writes() if w[1].endswith("/vendor/nodes")], [], "never registered a second time")
            self.assertEqual(len([n for n in fake.nodes.values() if n["nodeType"] == "FULFILLMENT_CENTER"]), 1)
            self.assertEqual(fake.node_by_code("SIM1")["nodeId"], node["nodeId"])
            self.assertEqual(fake.nodes[node["nodeId"]]["operationalProfile"]["profileRevision"], 1)
            self.assertIn(f"adopted {node['nodeId']}", out)

    def test_a_higher_declared_revision_is_left_alone(self):
        with network() as (fake, base):
            node = fake.add_vendor_node("SIM1", status="ACTIVE", revision=5)
            code, out, _ = run(base)
            self.assertEqual(code, 0, out)
            self.assertEqual([w for w in fake.writes() if w[1].endswith("/profile")], [])
            self.assertEqual(fake.nodes[node["nodeId"]]["operationalProfile"]["profileRevision"], 5)
            self.assertIn("declared elsewhere, left alone", out)

    def test_bumping_the_revision_in_the_data_file_declares_it_exactly_once(self):
        with network() as (fake, base):
            run(base)
            path = data_file(lambda c: c["fulfillmentNodes"][0]["profile"].update(profileRevision=2, handlingTimeMinutes=90))
            fake.log.clear()
            code, out, _ = run(base, "--data", path)
            self.assertEqual(code, 0, out)
            puts = [w for w in fake.writes() if w[1].endswith("/profile")]
            self.assertEqual(len(puts), 1)
            self.assertEqual((puts[0][2]["profileRevision"], puts[0][2]["vendorId"]), (2, "V-WS"))
            fake.log.clear()
            run(base, "--data", path)
            self.assertEqual(fake.writes(), [])

    # ---- tolerance and failure
    def test_a_409_on_create_is_treated_as_exists(self):
        with network() as (fake, base):
            fake.add_region("SIM-SC")
            fake.hide_regions = 2                   # the preflight and the seed's own read miss the region the POST then finds
            code, out, _ = run(base)
            self.assertEqual(code, 0, out)
            self.assertEqual(len(fake.regions), 1)
            self.assertIn("region-code-taken", out)

    def test_a_failed_vendor_transaction_exits_1_skips_dependents_and_a_rerun_converges(self):
        with network() as (fake, base):
            fake.fail_tx["NODE_REGISTRATION"] = ["ErrOperatorNotAllowedForNodeType"]
            code, out, _ = run(base)
            self.assertEqual(code, 1, out)
            self.assertIn("FAILED   fulfillment node SIM1", out)
            self.assertIn("ErrOperatorNotAllowedForNodeType", out)
            self.assertIn("SKIPPED", out)
            self.assertEqual((fake.lanes, fake.listings), ([], {}), "nothing that needs the node was attempted")
            self.assertEqual(len(fake.regions), 1)
            self.assertEqual(len(fake.items), 5, "independent steps still ran")
            fake.fail_tx.clear()
            # a later run has its own run id, hence fresh idempotency keys: the FAILED transaction is not replayed
            code, out, _ = run(base, now="2026-10-24T16:05:00Z")
            self.assertEqual(code, 0, out)
            self.assertEqual(len(fake.listings), 5)
            self.assertEqual(len(fake.items), 5, "no duplicate catalogue item")

    def test_a_transaction_that_never_finishes_times_out_with_exit_1(self):
        with network() as (fake, base):
            fake.tx_polls = 10 ** 9
            code, out, _ = run(base, "--tx-timeout-seconds", "0")
            self.assertEqual(code, 1)
            self.assertIn("still PROCESSING", out)

    def test_an_unexpected_status_exits_1_and_the_other_items_still_land(self):
        with network() as (fake, base):
            fake.always[("POST", "/api/offer-availability/catalog-items")] = (500, {"type": "boom", "title": "boom", "status": 500})
            code, out, _ = run(base, "--no-verify")
            self.assertEqual(code, 1, out)
            self.assertIn("FAILED   catalogue item ABO-B000B5KPG8", out)
            self.assertEqual(len(fake.waves), 14)
            self.assertEqual(fake.listings, {})

    def test_rate_limit_is_honoured(self):
        with network() as (fake, base):
            fake.once[("POST", "/api/node-topology/regions")] = [(429, {"type": "rate-limited", "title": "x", "status": 429}, {"Retry-After": "0"})]
            code, out, _ = run(base)
            self.assertEqual(code, 0, out)
            self.assertEqual(len(fake.regions), 1)

    def test_an_unreachable_network_exits_2_and_writes_nothing(self):
        code, _, err = run("http://127.0.0.1:1/api")
        self.assertEqual(code, 2)
        self.assertIn("seed-retail-network:", err)

    def test_a_route_that_answers_html_exits_2(self):
        with network() as (fake, base):
            fake.always[("GET", "/api/delivery-promise/promise-policies")] = (200, "<html>SPA fallback</html>")
            code, _, err = run(base)
            self.assertEqual(code, 2)
            self.assertIn("not a JSON answer", err)
            self.assertEqual(fake.writes(), [])

    def test_a_suspended_station_is_not_reactivated(self):
        with network() as (fake, base):
            run(base)
            ds = next(n for n in fake.nodes.values() if n["nodeType"] == "DELIVERY_STATION")
            ds["status"] = "SUSPENDED"
            fake.log.clear()
            code, out, _ = run(base, "--no-verify")
            self.assertEqual(code, 1)
            self.assertIn("is SUSPENDED", out)
            self.assertEqual([w for w in fake.writes() if "activate" in w[1]], [])

    # ---- inventory
    def test_only_never_fed_listings_are_fed_and_restock_refeeds(self):
        with network() as (fake, base):
            run(base)
            lid = sorted(fake.listings)[0]
            fake.listings[lid]["availability"] = {"availableQty": 7, "basis": "THROUGHPUT_CONSTRAINED", "asOf": "2026-10-24T17:00:00Z", "feedId": "fleet-1"}
            fake.log.clear()
            code, out, _ = run(base)
            self.assertEqual(code, 0, out)
            self.assertEqual([w for w in fake.writes() if w[1].endswith("/vendor/inventory")], [])
            self.assertEqual(fake.listings[lid]["availability"]["availableQty"], 7, "the fleet's number is not overwritten")
            code, out, _ = run(base, "--restock", now="2026-10-24T16:05:00Z")
            self.assertEqual(code, 0, out)
            self.assertEqual(len([w for w in fake.writes() if w[1].endswith("/vendor/inventory")]), 1)
            self.assertEqual(fake.listings[lid]["availability"]["availableQty"], 200)

    def test_the_full_feed_carries_the_nodes_other_listings_at_their_current_values(self):
        with network() as (fake, base):
            node = fake.add_vendor_node("SIM1")
            fake.items.append({"catalogItemId": "item-other", "title": "somebody else's item", "state": "ACTIVE",
                               "lengthMm": 1, "widthMm": 1, "heightMm": 1, "weightG": 1, "hazmat": False, "fragile": False})
            fake.listings["lst-other"] = {"listingId": "lst-other", "catalogItemId": "item-other", "nodeId": node["nodeId"], "state": "LIVE",
                                          "availability": {"availableQty": 42, "basis": "PHYSICAL", "asOf": "2026-10-24T10:00:00Z", "feedId": "f0"}}
            code, out, _ = run(base)
            self.assertEqual(code, 0, out)
            self.assertEqual(len(fake.feeds), 1)
            self.assertTrue(fake.feeds[0]["fullUpdate"])
            self.assertEqual(fake.listings["lst-other"]["availability"]["availableQty"], 42, "not zeroed by the full update")
            self.assertEqual(sorted(l["listingId"] for l in fake.listings.values()).count("lst-other"), 1)

    def test_listings_on_a_node_the_view_has_not_activated_yet_are_reported_by_verify(self):
        with network() as (fake, base):
            run(base)
            for l in fake.listings.values():
                l["state"], l["suppressionReason"] = "SUPPRESSED", "NODE_NOT_SELLABLE"
            code, out, _ = run(base, "--verify")
            self.assertEqual(code, 1)
            self.assertIn("SUPPRESSED", out)

    # ---- service areas
    def test_a_prefix_owned_by_another_station_is_left_alone_unless_reassign(self):
        with network() as (fake, base):
            run(base)
            other = fake.next_id("node")
            fake.nodes[other] = {**next(n for n in fake.nodes.values() if n["nodeType"] == "DELIVERY_STATION"), "nodeId": other,
                                 "location": {"postalCode": "00000", "countryCode": "US"}}
            fake.areas["787"]["deliveryStationNodeId"] = other
            fake.log.clear()
            code, out, _ = run(base, "--no-verify")
            self.assertEqual(code, 1, out)
            self.assertIn("left alone", out)
            self.assertEqual([w for w in fake.writes() if "service-areas" in w[1]], [])
            code, out, _ = run(base, "--reassign")
            self.assertEqual(code, 0, out)
            self.assertEqual(fake.areas["787"]["assignmentVersion"], 2)
            self.assertNotEqual(fake.areas["787"]["deliveryStationNodeId"], other)

    # ---- waves
    def test_waves_are_in_station_local_time_across_the_dst_change(self):
        with network() as (fake, base):
            run(base)
            by_day = {w["serviceDate"]: w for w in fake.waves}
            self.assertEqual(sorted(by_day)[0], "2026-10-24")
            self.assertEqual(sorted(by_day)[-1], "2026-11-06")
            w = by_day["2026-10-26"]                # CDT, UTC-5
            self.assertEqual((w["inductCutoffAt"], w["windowStart"], w["windowEnd"]), ("2026-10-26T10:00:00Z", "2026-10-26T14:00:00Z", "2026-10-27T02:00:00Z"))
            w = by_day["2026-11-02"]                # CST, UTC-6 (DST ended on 2026-11-01)
            self.assertEqual((w["inductCutoffAt"], w["windowStart"], w["windowEnd"]), ("2026-11-02T11:00:00Z", "2026-11-02T15:00:00Z", "2026-11-03T03:00:00Z"))
            self.assertEqual(w["stopCapacity"], 500)

    def test_a_later_run_extends_the_horizon_and_creates_only_the_new_waves(self):
        with network() as (fake, base):
            run(base)
            fake.log.clear()
            code, out, _ = run(base, now="2026-10-27T16:00:00Z")
            self.assertEqual(code, 0, out)
            self.assertEqual(len(fake.waves), 17)
            self.assertEqual({w[0] for w in fake.writes()}, {"POST"})
            self.assertEqual({w[1] for w in fake.writes()}, {"/api/last-mile-delivery/waves"})

    def test_a_wave_whose_window_has_ended_is_not_scheduled(self):
        with network() as (fake, base):
            code, out, _ = run(base, "--no-verify", now="2026-10-25T03:00:00Z")      # Saturday 22:00 local: today's window (09-21) is over
            self.assertEqual(code, 0, out)
            self.assertEqual(sorted(w["serviceDate"] for w in fake.waves)[0], "2026-10-25")
            self.assertEqual(len(fake.waves), 13)

    def test_the_wave_times_follow_the_data_file(self):
        day = SEED.dt.date(2026, 10, 26)
        tz = SEED.tzinfo("America/Chicago")
        waves = {"inductCutoffLocal": "04:30", "windowStartLocal": "08:00", "windowEndLocal": "12:00"}
        got = SEED.wave_times(day, tz, waves)
        self.assertEqual([SEED.iso(t) for t in got], ["2026-10-26T09:30:00Z", "2026-10-26T13:00:00Z", "2026-10-26T17:00:00Z"])


# ---- network-fulfillment's product dictionary: --emit-translation / --check-translation (read only)
SKUS = ["ABO-B000B5KPG8", "ABO-B000G0F3CY", "ABO-B000IK09WG", "ABO-B000SLW522", "ABO-B000UGZD9M"]    # the data file's, sorted
PAIRS = [(f"lst-{n:03d}", sku) for n, sku in enumerate(SKUS, 1)]     # what a freshly seeded fake hands out, in order
VALUES_PATH = os.path.join(REPO_ROOT, "helm-values", "network-fulfillment.yaml")


def block(pairs):
    """The productTranslation block of a values file, written by the test (not by the code under test)."""
    return "productTranslation:\n  mappings:\n" + "".join(f"    - networkProductId: {i}\n      sku: {s}\n" for i, s in pairs)


@contextlib.contextmanager
def seeded():
    """A fake network already seeded with the shipped data file, request log cleared."""
    with network() as (fake, base):
        code, out, _ = run(base)
        assert code == 0, out
        fake.log.clear()
        yield fake, base


class ValuesFileCase(unittest.TestCase):
    def values(self, text, around=True):
        """A Helm values file with `text` in the middle of unrelated keys; its path."""
        body = "config:\n  networkMode: stub\n" + text + "service:\n  port: 80\n" if around else text
        f = tempfile.NamedTemporaryFile("w", suffix=".yaml", delete=False)
        f.write(body)
        f.close()
        self.addCleanup(os.unlink, f.name)
        return f.name


class EmitTranslationTests(ValuesFileCase):
    def test_prints_the_paste_ready_block_for_every_sku_and_nothing_else_on_stdout(self):
        with seeded() as (fake, base):
            code, out, err = run(base, "--emit-translation")
            self.assertEqual(code, 0, err)
            self.assertEqual(out, "productTranslation:\n"
                                  "  mappings:\n"
                                  "    - networkProductId: lst-001\n      sku: ABO-B000B5KPG8\n"
                                  "    - networkProductId: lst-002\n      sku: ABO-B000G0F3CY\n"
                                  "    - networkProductId: lst-003\n      sku: ABO-B000IK09WG\n"
                                  "    - networkProductId: lst-004\n      sku: ABO-B000SLW522\n"
                                  "    - networkProductId: lst-005\n      sku: ABO-B000UGZD9M\n")
            self.assertIn("lst-001", err, "progress goes to stderr")
            self.assertEqual(SEED.parse_translation_file(self.values(out)), PAIRS, "the block is valid and reads back")

    def test_the_output_is_sorted_by_sku_then_listing_id_and_a_sku_on_two_nodes_maps_twice(self):
        def two_nodes_reversed(cfg):
            cfg["catalog"].reverse()                       # listing ids now run against the sku order
            cfg["fulfillmentNodes"].append({**copy.deepcopy(cfg["fulfillmentNodes"][0]), "vendorNodeCode": "SIM2"})
        path = data_file(two_nodes_reversed)
        with network() as (fake, base):
            code, out, _ = run(base, "--data", path)
            self.assertEqual(code, 0, out)
            fake.log.clear()
            code, out, err = run(base, "--emit-translation", "--data", path)
            self.assertEqual(code, 0, err)
            got = SEED.parse_translation_file(self.values(out))
            self.assertEqual(got, sorted(got, key=lambda m: (m[1], m[0])))
            self.assertEqual(len(got), 10)
            self.assertEqual(got[:2], [("lst-005", "ABO-B000B5KPG8"), ("lst-010", "ABO-B000B5KPG8")])
            self.assertEqual(got[-2:], [("lst-001", "ABO-B000UGZD9M"), ("lst-006", "ABO-B000UGZD9M")])

    def test_a_sku_without_a_listing_prints_nothing_names_it_and_exits_1(self):
        with seeded() as (fake, base):
            del fake.listings["lst-003"]
            code, out, err = run(base, "--emit-translation")
            self.assertEqual((code, out), (1, ""), "a partial dictionary must never look complete")
            self.assertIn("ABO-B000IK09WG: no listing on node SIM1", err)
            self.assertNotIn("ABO-B000B5KPG8: no listing", err)

    def test_every_problem_gets_its_own_line_on_stderr(self):
        with seeded() as (fake, base):
            del fake.listings["lst-001"]
            del fake.listings["lst-005"]
            code, out, err = run(base, "--emit-translation")
            self.assertEqual((code, out), (1, ""))
            self.assertIn("ABO-B000B5KPG8: no listing", err)
            self.assertIn("ABO-B000UGZD9M: no listing", err)

    def test_an_unknown_node_prints_nothing_and_exits_1(self):
        with network() as (fake, base):
            code, out, err = run(base, "--emit-translation")                  # nothing seeded
            self.assertEqual((code, out), (1, ""))
            self.assertIn("fulfillment node SIM1 (vendor V-WS) is not in node-topology", err)
            fake.add_vendor_node("SIM2")                                     # another node does not stand in for it
            code, out, err = run(base, "--emit-translation")
            self.assertEqual((code, out), (1, ""))
            self.assertIn("SIM1", err)

    def test_a_missing_or_discontinued_catalogue_item_is_a_problem_too(self):
        with seeded() as (fake, base):
            fake.items[1]["state"] = "DISCONTINUED"
            del fake.items[0]
            code, out, err = run(base, "--emit-translation")
            self.assertEqual((code, out), (1, ""))
            self.assertIn("ABO-B000B5KPG8: catalogue item", err)
            self.assertIn("ABO-B000G0F3CY: catalogue item", err)

    def test_a_failing_read_is_a_problem_not_a_dictionary(self):
        with seeded() as (fake, base):
            fake.always[("GET", "/api/offer-availability/listings")] = (500, {"type": "boom", "title": "boom", "status": 500})
            code, out, err = run(base, "--emit-translation")
            self.assertEqual((code, out), (1, ""))
            self.assertIn("GET /listings", err)

    def test_an_unreachable_network_exits_2_with_nothing_on_stdout(self):
        code, out, err = run("http://127.0.0.1:1/api", "--emit-translation")
        self.assertEqual((code, out), (2, ""))
        self.assertIn("seed-retail-network:", err)

    def test_emit_and_check_send_nothing_but_gets_whatever_the_network_looks_like(self):
        path = None
        for prepare in ("seeded", "empty", "no-listing"):
            with (seeded() if prepare != "empty" else network()) as (fake, base):
                if prepare == "no-listing":
                    del fake.listings["lst-002"]
                path = path or self.values(block(PAIRS))
                for args in (("--emit-translation",), ("--check-translation", path)):
                    fake.log.clear()
                    run(base, *args)
                    self.assertGreater(len(fake.log), 5, (prepare, args))
                    self.assertEqual({e[0] for e in fake.log}, {"GET"}, (prepare, args))
                    self.assertEqual(fake.writes(), [])

    def test_the_translation_client_refuses_every_write_verb_without_sending_it(self):
        api = SEED.Api("http://127.0.0.1:1/api", read_only=True)          # nothing listens there
        for verb in ("POST", "PUT", "PATCH", "DELETE"):
            with self.assertRaisesRegex(SEED.SetupError, "read-only"):
                api.call(verb, "/anything", {"x": 1}, "key")

    def test_the_modes_stand_alone(self):
        with network() as (fake, base):
            for mode in (["--emit-translation"], ["--check-translation", "x.yaml"]):
                for other in (["--restock"], ["--reassign"], ["--dry-run"], ["--verify"], ["--quote"], ["--no-verify"],
                              ["--emit-translation"] if mode[0] != "--emit-translation" else ["--check-translation", "y.yaml"]):
                    code, out, err = run(base, *mode, *other)
                    self.assertEqual((code, out), (2, ""), (mode, other))
                    self.assertIn("seed-retail-network: --emit-translation and --check-translation stand alone", err)
            self.assertEqual(fake.log, [], "rejected before any request")


class CheckTranslationTests(ValuesFileCase):
    def check(self, base, text, around=True):
        return run(base, "--check-translation", self.values(text, around))

    def test_a_dictionary_that_matches_says_so_in_one_line(self):
        with seeded() as (fake, base):
            code, out, err = self.check(base, block(PAIRS))
            self.assertEqual((code, out), (0, "dictionary matches the network (5 mappings)\n"), err)

    def test_the_order_of_the_file_does_not_matter(self):
        with seeded() as (fake, base):
            code, out, _ = self.check(base, block(list(reversed(PAIRS))))
            self.assertEqual((code, out), (0, "dictionary matches the network (5 mappings)\n"))

    def test_a_missing_mapping_is_named(self):
        with seeded() as (fake, base):
            code, out, _ = self.check(base, block(PAIRS[:2] + PAIRS[3:]))
            self.assertEqual(code, 1)
            self.assertIn("dictionary DIFFERS from the network", out)
            self.assertIn("  missing  lst-003 -> ABO-B000IK09WG", out)
            self.assertNotIn("extra", out)
            self.assertNotIn("matches", out)

    def test_an_extra_mapping_is_named(self):
        with seeded() as (fake, base):
            code, out, _ = self.check(base, block(PAIRS + [("lst-999", "ABO-ZZZ")]))
            self.assertEqual(code, 1)
            self.assertIn("  extra    lst-999 -> ABO-ZZZ", out)
            self.assertNotIn("missing", out)

    def test_a_second_id_for_a_known_sku_is_extra_not_wrong(self):
        with seeded() as (fake, base):
            code, out, _ = self.check(base, block(PAIRS + [("lst-999", "ABO-B000G0F3CY")]))
            self.assertEqual(code, 1)
            self.assertIn("  extra    lst-999 -> ABO-B000G0F3CY", out)
            self.assertNotIn("wrong", out)

    def test_a_mapping_that_points_at_another_listing_is_named_once(self):
        with seeded() as (fake, base):
            stale = [("lst-777" if i == "lst-002" else i, s) for i, s in PAIRS]       # a reseeded network hands out new ids
            code, out, _ = self.check(base, block(stale))
            self.assertEqual(code, 1)
            self.assertIn("  wrong    ABO-B000G0F3CY: the file points at listing lst-777, the network has lst-002", out)
            self.assertNotIn("missing", out)
            self.assertNotIn("extra", out)

    def test_an_id_mapped_to_another_sku_is_named(self):
        with seeded() as (fake, base):
            swapped = [("lst-001", "ABO-B000G0F3CY"), ("lst-002", "ABO-B000B5KPG8")] + PAIRS[2:]
            code, out, _ = self.check(base, block(swapped))
            self.assertEqual(code, 1)
            self.assertIn("  wrong    lst-001: the file maps it to sku ABO-B000G0F3CY, the network's listing is for sku ABO-B000B5KPG8", out)
            self.assertIn("  wrong    lst-002: the file maps it to sku ABO-B000B5KPG8, the network's listing is for sku ABO-B000G0F3CY", out)

    def test_the_stub_fixture_mappings_are_flagged_as_not_surviving_the_flip(self):
        with seeded() as (fake, base):
            stub = [("NET-LOCAL-1", "sku-1"), ("NET-LOCAL-2", "sku-2")]
            code, out, _ = self.check(base, block(stub))                       # the values file as it ships today
            self.assertEqual(code, 1)
            for want in ("  extra    NET-LOCAL-1 -> sku-1", "  extra    NET-LOCAL-2 -> sku-2", "stub fixture"):
                self.assertIn(want, out)
            self.assertEqual(out.count("  missing  "), 5)
            code, out, _ = self.check(base, block(PAIRS + stub))               # real ids are not enough: the stubs must go
            self.assertEqual(code, 1)
            self.assertIn("stub fixture", out)
            self.assertNotIn("missing", out)

    def test_an_empty_list_differs_by_everything_missing(self):
        with seeded() as (fake, base):
            code, out, _ = self.check(base, "productTranslation:\n  mappings: []\n")
            self.assertEqual(code, 1)
            self.assertEqual(out.count("  missing  "), 5)

    def test_an_incomplete_network_fails_the_check_with_the_problems_on_stderr(self):
        with seeded() as (fake, base):
            del fake.listings["lst-004"]
            code, out, err = self.check(base, block(PAIRS))
            self.assertEqual((code, out), (1, ""))
            self.assertIn("ABO-B000SLW522: no listing on node SIM1", err)

    def test_a_malformed_file_exits_2_names_the_line_and_reads_nothing_from_the_network(self):
        cases = {
            "no productTranslation": "config:\n  networkMode: stub\n",
            "productTranslation twice": block(PAIRS[:1]) + block(PAIRS[:1]),
            "inline mapping": "productTranslation: {mappings: []}\n",
            "no mappings key": "productTranslation:\n  other: 1\n",
            "mappings inline map": "productTranslation:\n  mappings: {a: b}\n",
            "flow-style item": "productTranslation:\n  mappings:\n    - {networkProductId: a, sku: b}\n",
            "item without sku": "productTranslation:\n  mappings:\n    - networkProductId: a\n",
            "item without id": "productTranslation:\n  mappings:\n    - sku: a\n",
            "unknown key in item": block(PAIRS[:1]) + "      note: x\n",
            "unknown key beside mappings": block(PAIRS[:1]) + "  file: products.json\n",
            "bare scalar item": "productTranslation:\n  mappings:\n    - lst-001\n",
            "empty value": "productTranslation:\n  mappings:\n    - networkProductId:\n      sku: a\n",
            "tab indentation": "productTranslation:\n  mappings:\n\t- networkProductId: a\n\t  sku: b\n",
            "unterminated quote": "productTranslation:\n  mappings:\n    - networkProductId: 'a\n      sku: b\n",
            "escape in double quotes": 'productTranslation:\n  mappings:\n    - networkProductId: "a\\n"\n      sku: b\n',
            "same id twice": block([("lst-001", "a"), ("lst-001", "b")]),
            "same key twice": "productTranslation:\n  mappings:\n    - networkProductId: a\n      networkProductId: b\n",
            "anchor": "productTranslation:\n  mappings:\n    - networkProductId: &x a\n      sku: b\n",
            "text after a quote": "productTranslation:\n  mappings:\n    - networkProductId: 'a' b\n      sku: b\n",
        }
        with network() as (fake, base):
            for name, text in cases.items():
                with self.subTest(name):
                    path = self.values(text, around=False)
                    code, out, err = run(base, "--check-translation", path)
                    self.assertEqual((code, out), (2, ""), err)
                    self.assertIn("seed-retail-network:", err)
                    self.assertIn(path, err)
            code, out, err = run(base, "--check-translation", "/nonexistent/values.yaml")
            self.assertEqual((code, out), (2, ""))
            self.assertIn("cannot read values file /nonexistent/values.yaml", err)
            self.assertEqual(fake.log, [], "the file is read before the network is touched")


class TranslationFileTests(ValuesFileCase):
    def parse(self, text, around=True):
        return SEED.parse_translation_file(self.values(text, around))

    def test_it_reads_comments_quotes_blank_lines_and_the_list_at_the_key_indent(self):
        text = ("# the dictionary\n"
                "productTranslation:   # curated\n"
                "\n"
                "  mappings:\n"
                "  # a note between\n"
                "  - networkProductId: lst-001   # trailing\n"
                "    sku: ABO-1\n"
                "\n"
                "  - sku: \"ABO-2\"\n"
                "    networkProductId: '12345'\n"
                "  - networkProductId: 'it''s'\n"
                "    sku: 'a: b # not a comment'\n")
        self.assertEqual(self.parse(text), [("lst-001", "ABO-1"), ("12345", "ABO-2"), ("it's", "a: b # not a comment")])

    def test_an_empty_list_and_a_block_ending_at_the_end_of_the_file(self):
        self.assertEqual(self.parse("productTranslation:\n  mappings: []\n"), [])
        self.assertEqual(self.parse("a: 1\nproductTranslation:\n  mappings:\n    - networkProductId: x\n      sku: y", around=False), [("x", "y")])

    def test_only_the_top_level_key_counts(self):
        text = "nested:\n  productTranslation:\n    mappings:\n      - networkProductId: no\n        sku: no\n" + block([("x", "y")])
        self.assertEqual(self.parse(text), [("x", "y")])

    def test_the_shipped_values_file_parses(self):
        got = SEED.parse_translation_file(VALUES_PATH)
        self.assertTrue(got and all(len(m) == 2 and all(m) for m in got), got)

    def test_what_is_written_reads_back_for_ids_that_need_quoting(self):
        odd = [("12345", "a"), ("0192f3-aa", "b"), ("yes", "c"), ("Null", "d"), ("a: b", "e"), ("it's", "f"), ("#x", "g"),
               (" pad ", "h"), ("1e5", "i"), ("0x1F", "j"), ("lst-001", "k"), ("a.b_c-d", "l"), ("12:30", "m")]
        text = SEED.render_translation(odd)
        self.assertEqual(self.parse(text), odd)
        lines = text.splitlines()
        self.assertIn("    - networkProductId: lst-001", lines)           # plain when it is unambiguous
        self.assertIn("    - networkProductId: '12345'", lines)           # a number-looking id must stay a string
        self.assertIn("    - networkProductId: 'yes'", lines)
        self.assertIn("    - networkProductId: 'it''s'", lines)

    def test_a_value_the_values_file_cannot_hold_is_refused(self):
        with self.assertRaises(ValueError):
            SEED.render_translation([("line\nbreak", "a")])


class UnitTests(unittest.TestCase):
    def test_slug_reads_a_bare_slug_and_a_problem_url(self):
        self.assertEqual(SEED.slug({"type": "duplicate-lane"}), "duplicate-lane")
        self.assertEqual(SEED.slug({"type": "https://retailnetwork.example/problems/book-closed"}), "book-closed")
        self.assertEqual(SEED.slug(None), "")
        self.assertEqual(SEED.slug({"raw": "x"}), "")

    def test_qs_drops_empty_parameters_and_encodes(self):
        self.assertEqual(SEED.qs(a=None), "")
        self.assertEqual(SEED.qs(a="x y", b=None, c=1), "?a=x+y&c=1")
        self.assertEqual(SEED.q("a/b:c"), "a%2Fb%3Ac")

    def test_dry_ids_are_recognised(self):
        self.assertTrue(SEED.is_dry("dry:ds:X"))
        self.assertFalse(SEED.is_dry("node-1"))


class DataFileTests(unittest.TestCase):
    def test_the_shipped_data_file_is_valid_and_complete(self):
        cfg = SEED.load_config(DATA_FILE)
        self.assertEqual(cfg["vendor"]["vendorId"], "V-WS")
        self.assertEqual([f["vendorNodeCode"] for f in cfg["fulfillmentNodes"]], ["SIM1"], "vendorNodeCode = the fleet site code (ADR 0026 adoption)")
        self.assertEqual(cfg["fulfillmentNodes"][0]["profile"]["profileRevision"], 1)
        skus = [i["sku"] for i in cfg["catalog"]]
        self.assertEqual(len(skus), len(set(skus)))
        self.assertTrue(all(s.startswith("ABO-") for s in skus), "real SKUs of the e2e product catalogue, not invented ones")
        self.assertTrue(all(i["title"].startswith(i["sku"]) and i["availableQty"] > 0 for i in cfg["catalog"]))

    def test_the_profile_is_consistent_with_node_topologys_rules(self):
        prof = SEED.load_config(DATA_FILE)["fulfillmentNodes"][0]["profile"]
        self.assertGreater(prof["handlingTimeMinutes"], 0)
        self.assertGreaterEqual(len(prof["cutoffs"]), 1)
        for c in prof["cutoffs"]:                    # every cutoff inside the hours of every operating day
            for hours in prof["operatingHoursByDay"].values():
                self.assertTrue(hours["start"] <= c["localTime"] <= hours["end"], c)

    def test_a_broken_data_file_exits_2_and_writes_nothing(self):
        cases = [lambda c: c["catalog"].append(dict(c["catalog"][0])),                       # duplicate sku/title
                 lambda c: c["catalog"][0].update(availableQty=0),                           # not purchasable
                 lambda c: c["fulfillmentNodes"][0]["lane"].update(toStation="NOPE"),
                 lambda c: c["fulfillmentNodes"][0]["profile"].update(profileRevision=0),
                 lambda c: c["deliveryStations"][0].update(timezone="Mars/Olympus"),
                 lambda c: c.pop("waves")]
        with network() as (fake, base):
            for mutate in cases:
                code, _, err = run(base, "--data", data_file(mutate))
                self.assertEqual(code, 2, err)
                self.assertIn("seed-retail-network:", err)
            code, _, err = run(base, "--data", "/nonexistent/seed.json")
            self.assertEqual(code, 2)
            self.assertEqual(fake.writes(), [])


if __name__ == "__main__":
    unittest.main()
