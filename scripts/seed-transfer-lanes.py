#!/usr/bin/env python3
"""Seed network-inventory-planning's Transfer Lane catalogue from site geography.

WHY THIS EXISTS
---------------
network-inventory-planning (NIP) only proposes a transfer along an ENABLED lane
whose origin may send and whose destination may receive (its ADR-0015). The
lane catalogue is NIP's own operator-managed data: no sibling context publishes
it, so a fresh cluster has none and the scheduled rebalance pass can never
propose anything. `seed-transfer-capability.py` decides WHICH sites may send or
receive; this script decides WHICH site-to-site lanes exist, and how costly
they are.

THE RULE (deliberately simple, all derived from real geography)
---------------------------------------------------------------
* Candidates are Active sites whose facility-layout transfer capability says
  origin and/or destination (read live from
  GET /sites/{siteCode}/transfer-capability); a site capable of neither gets no lane.
* For every origin, one directed lane to each of its K nearest destinations
  (default 4) in the SAME COUNTRY and within --max-km (default 2500 km). No
  cross-border lanes: customs make them a different product.
* Distance is the great-circle distance between the site's city centres
  (scripts/data/site-coordinates.json, geocoded from the "(City, ST)" in the
  site name with OpenStreetMap Nominatim, (c) OpenStreetMap contributors, ODbL).
* LeadTime = (1 + ceil(km / 800)) days: one day handling, trucking at 800 km/day.
* UnitHandlingCost = 1 + ceil(km / 400). NIP scores a proposal as
  quantity * UnitPriority - quantity * UnitHandlingCost - lead-time days, so the
  cost is a RELATIVE weight (one point per 400 km on top of a flat 1 for handling),
  not a currency amount.

SEMANTICS
---------
  lane state in NIP                          action
  absent                                     PUT (outcome CREATED, revision 1)
  present, identical                         nothing (no PUT: no revision)
  present, differs (lead time, cost, off)    PUT (outcome UPDATED, revision + 1)
  present but not in the computed set        left alone and listed ("unmanaged"):
                                             an operator may have added it, and
                                             NIP has no DELETE (disable instead)

Idempotent: a second run against an unchanged cluster makes zero writes.

USAGE
-----
    python3 scripts/seed-transfer-lanes.py --dry-run
    python3 scripts/seed-transfer-lanes.py
    python3 scripts/seed-transfer-lanes.py --neighbours 6 --max-km 3000

    # a new site appeared: geocode the ones missing from the data file (1 request/s)
    python3 scripts/seed-transfer-lanes.py --refresh-coordinates

URLs default to Kong on the kind cluster: $FACILITY_LAYOUT_BASE_URL
(http://localhost:8000/api/facility-layout) and $NIP_BASE_URL
(http://localhost:8000/api/network-inventory-planning).

EXIT CODES
----------
  0  every computed lane is at its target (or would be, with --dry-run)
  1  at least one PUT failed (the others are still applied)
  2  the site list, a capability, the lane catalogue or the coordinates file could not be read (nothing written)

Stdlib only.
"""

from __future__ import annotations

import argparse
import json
import math
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

DEFAULT_FACILITY_URL = "http://localhost:8000/api/facility-layout"
DEFAULT_NIP_URL = "http://localhost:8000/api/network-inventory-planning"
DATA_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "data", "site-coordinates.json")
ACTIVE = "Active"
NS_PER_DAY = 86_400 * 1_000_000_000
EARTH_RADIUS_KM = 6371.0088

US_STATES = {
    "AL", "AK", "AZ", "AR", "CA", "CO", "CT", "DC", "FL", "GA", "HI", "ID", "IL", "IN", "IA", "KS", "KY", "LA",
    "ME", "MD", "MA", "MI", "MN", "MS", "MO", "MT", "NE", "NV", "NH", "NJ", "NM", "NY", "NC", "ND", "OH", "OK",
    "OR", "PA", "RI", "SC", "SD", "TN", "TX", "UT", "VT", "VA", "WA", "WV", "WI", "WY",
}
# "(City, XX)" is a US state unless XX is one of these countries (DE is Delaware and Germany: the
# network has no Delaware site, so a two-part ", DE" is Germany).
COUNTRY_OVERRIDES = {"DE"}


class SetupError(RuntimeError):
    """Sites, capabilities or coordinates are unusable: abort before any write (exit 2)."""


class Api:
    """A tiny JSON-over-HTTP client. 4xx/5xx are returned, never raised."""

    def __init__(self, base_url: str, timeout: float = 15.0, retries: int = 2, delay_s: float = 0.5):
        self.base, self.timeout, self.retries, self.delay_s = base_url.rstrip("/"), timeout, retries, delay_s

    def call(self, method: str, path: str, body: dict | None = None):
        data = json.dumps(body).encode() if body is not None else None
        attempt = 0
        while True:
            req = urllib.request.Request(self.base + path, data=data, method=method)
            req.add_header("Accept", "application/json")
            if data is not None:
                req.add_header("Content-Type", "application/json")
            try:
                with urllib.request.urlopen(req, timeout=self.timeout) as resp:
                    return resp.status, _decode(resp.read())
            except urllib.error.HTTPError as e:
                status, decoded = e.code, _decode(e.read())
                if status >= 500 and method == "GET" and attempt < self.retries:
                    attempt += 1
                    time.sleep(self.delay_s)
                    continue
                return status, decoded
            except (urllib.error.URLError, TimeoutError, ConnectionError) as e:
                if attempt < self.retries:
                    attempt += 1
                    time.sleep(self.delay_s)
                    continue
                raise SetupError(f"{method} {self.base + path}: {getattr(e, 'reason', e)}") from e


def _decode(raw: bytes):
    if not raw:
        return None
    try:
        return json.loads(raw)
    except ValueError:
        return {"raw": raw.decode(errors="replace")}


# ------------------------------------------------------------------ geography
def parse_location(name: str) -> dict | None:
    """The trailing "(City, ST)" / "(City, Region, CC)" of a site name, or None.

    "CHA2 - XL (Extra-Large) Fulfillment Center (Chattanooga, TN)" -> Chattanooga, TN;
    "KCVG - Air Hub Gateway (Hebron, KY (CVG airport))" -> Hebron, KY.
    """
    m = re.search(r"\(([^()]*(?:\([^()]*\))?[^()]*)\)\s*$", name or "")
    if not m:
        return None
    loc = re.sub(r"\s*\([^()]*\)", "", m.group(1)).strip()
    parts = [p.strip() for p in loc.split(",")]
    if len(parts) == 2 and parts[1] in US_STATES and parts[1] not in COUNTRY_OVERRIDES:
        return {"city": parts[0], "region": parts[1], "country": "US"}
    if len(parts) == 2 and parts[1] in COUNTRY_OVERRIDES:
        return {"city": parts[0], "region": "", "country": parts[1]}
    if len(parts) == 2:
        return {"city": parts[0], "region": "", "country": parts[1]}
    if len(parts) == 3:
        return {"city": parts[0], "region": parts[1], "country": parts[2]}
    return None


def haversine_km(a: tuple, b: tuple) -> float:
    (la1, lo1), (la2, lo2) = a, b
    p1, p2 = math.radians(la1), math.radians(la2)
    dp, dl = p2 - p1, math.radians(lo2 - lo1)
    h = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 2 * EARTH_RADIUS_KM * math.asin(math.sqrt(h))


def lead_time_days(km: float) -> int:
    return 1 + math.ceil(km / 800)


def unit_handling_cost(km: float) -> int:
    return 1 + math.ceil(km / 400)


def compute_lanes(origins: set, destinations: set, coords: dict, neighbours: int, max_km: float):
    """Directed lanes: each origin to its K nearest same-country destinations within max_km.

    Returns (lanes, isolated): lanes are the NIP Lane bodies sorted by origin then destination;
    isolated are the origins left with no destination.
    """
    lanes, isolated = [], []
    for o in sorted(origins):
        oc = coords[o]
        near = []
        for d in destinations:
            if d == o or coords[d]["country"] != oc["country"]:
                continue
            km = haversine_km((oc["lat"], oc["lon"]), (coords[d]["lat"], coords[d]["lon"]))
            if km <= max_km:
                near.append((km, d))
        near.sort()
        if not near:
            isolated.append(o)
        for km, d in near[:neighbours]:
            lanes.append({
                "Origin": o,
                "Destination": d,
                "LeadTime": lead_time_days(km) * NS_PER_DAY,
                "UnitHandlingCost": unit_handling_cost(km),
                "Enabled": True,
            })
    return lanes, isolated


# ------------------------------------------------------------------ coordinates file
def load_coordinates(path: str = DATA_FILE) -> dict:
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)["sites"]
    except (OSError, ValueError, KeyError) as e:
        raise SetupError(f"cannot read coordinates {path}: {e}") from e


def refresh_coordinates(sites: list, path: str = DATA_FILE, pause_s: float = 1.1, fetch=None) -> list:
    """Geocode every Active site missing from the data file with Nominatim (1 request/s)."""
    try:
        have = load_coordinates(path)
    except SetupError:
        have = {}
    fetch = fetch or _nominatim
    added = []
    for s in sorted(sites, key=lambda x: x["siteCode"]):
        code = s["siteCode"]
        if code in have or s.get("status") != ACTIVE:
            continue
        loc = parse_location(s.get("name", ""))
        if not loc:
            print(f"  skip {code}: no (City, ST) in the site name {s.get('name')!r}")
            continue
        hit = fetch(loc)
        time.sleep(pause_s)
        if not hit:
            print(f"  NOT FOUND {code}: {loc}")
            continue
        have[code] = {**loc, "lat": round(float(hit["lat"]), 4), "lon": round(float(hit["lon"]), 4),
                      "match": str(hit.get("display_name", ""))[:110]}
        added.append(code)
        print(f"  geocoded {code}: {loc['city']}, {loc['region'] or loc['country']} -> {have[code]['lat']}, {have[code]['lon']}")
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        json.dump({
            "_comment": "City-centre coordinates of the network's sites, geocoded from the '(City, ST)' in each "
                        "facility-layout site name with OpenStreetMap Nominatim. (c) OpenStreetMap contributors, ODbL "
                        "1.0. Refreshed by scripts/seed-transfer-lanes.py --refresh-coordinates.",
            "sites": dict(sorted(have.items())),
        }, f, indent=1, ensure_ascii=False)
        f.write("\n")
    return added


def _nominatim(loc: dict):
    cc = {"US": "us", "GB": "gb", "CA": "ca", "BR": "br", "AU": "au", "PL": "pl", "DE": "de"}.get(loc["country"], loc["country"].lower())
    q = {"format": "jsonv2", "limit": 1, "city": loc["city"], "countrycodes": cc}
    if loc["region"]:
        q["state"] = loc["region"]
    free = {"format": "jsonv2", "limit": 1, "countrycodes": cc,
            "q": ", ".join(x for x in (loc["city"], loc["region"], loc["country"]) if x)}
    for params in (q, free):
        url = "https://nominatim.openstreetmap.org/search?" + urllib.parse.urlencode(params)
        req = urllib.request.Request(url, headers={"User-Agent": "warehouse-systems-study/1.0 (seed-transfer-lanes)"})
        try:
            with urllib.request.urlopen(req, timeout=20) as resp:
                found = json.load(resp)
        except urllib.error.HTTPError:
            found = []            # 4xx/5xx for this query: try the free-text form, then give up on the site
        except (urllib.error.URLError, TimeoutError) as e:
            # Not "site not found": the lookup itself is broken (offline, or this Python lacks CA certificates -
            # on macOS run "Install Certificates.command" or use a python3 that has them). Never skip silently.
            raise SetupError(f"Nominatim unreachable: {getattr(e, 'reason', e)}") from e
        except ValueError:
            found = []
        if found:
            return found[0]
        time.sleep(1.1)
    return None


# ------------------------------------------------------------------ main
def read_capabilities(facility: Api):
    status, sites = facility.call("GET", "/sites")
    if status != 200 or not isinstance(sites, list):
        raise SetupError(f"GET /sites -> {status} {sites}")
    origins, destinations = set(), set()
    for s in sites:
        if s.get("status") != ACTIVE:
            continue
        code = s["siteCode"]
        st, cap = facility.call("GET", f"/sites/{urllib.parse.quote(code)}/transfer-capability")
        if st != 200 or not isinstance(cap, dict):
            raise SetupError(f"GET /sites/{code}/transfer-capability -> {st} {cap}")
        if cap.get("transferOriginEnabled"):
            origins.add(code)
        if cap.get("transferDestinationEnabled"):
            destinations.add(code)
    return sites, origins, destinations


def same_lane(have: dict, want: dict) -> bool:
    return all(have.get(k) == want[k] for k in ("LeadTime", "UnitHandlingCost", "Enabled"))


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--facility-url", default=os.environ.get("FACILITY_LAYOUT_BASE_URL", DEFAULT_FACILITY_URL))
    ap.add_argument("--nip-url", default=os.environ.get("NIP_BASE_URL", DEFAULT_NIP_URL))
    ap.add_argument("--neighbours", type=int, default=4, help="destinations per origin (default 4)")
    ap.add_argument("--max-km", type=float, default=2500.0, help="longest lane (default 2500 km)")
    ap.add_argument("--coordinates", default=DATA_FILE)
    ap.add_argument("--dry-run", action="store_true", help="print the plan, write nothing")
    ap.add_argument("--refresh-coordinates", action="store_true",
                    help="geocode sites missing from the coordinates file (Nominatim, 1 request/s) and exit")
    args = ap.parse_args(argv)

    facility, nip = Api(args.facility_url), Api(args.nip_url)
    try:
        if args.refresh_coordinates:
            status, sites = facility.call("GET", "/sites")
            if status != 200 or not isinstance(sites, list):
                raise SetupError(f"GET /sites -> {status} {sites}")
            added = refresh_coordinates(sites, args.coordinates)
            print(f"\nseed-transfer-lanes: {len(added)} site(s) geocoded into {args.coordinates}")
            return 0
        sites, origins, destinations = read_capabilities(facility)
        coords = load_coordinates(args.coordinates)
        # A capable site without coordinates (the simulator SIM1 has no city; a brand-new site is not geocoded
        # yet) gets no lane. It is listed loudly instead of aborting: run --refresh-coordinates for a new site.
        no_coords = sorted((origins | destinations) - set(coords))
        origins, destinations = origins & set(coords), destinations & set(coords)
        status, existing = nip.call("GET", "/v1/transfer-lanes")
        if status != 200 or not isinstance(existing, dict):
            raise SetupError(f"GET /v1/transfer-lanes -> {status} {existing}")
    except SetupError as e:
        print(f"seed-transfer-lanes: {e}", file=sys.stderr)
        return 2

    have = {(e["lane"]["Origin"], e["lane"]["Destination"]): e["lane"] for e in existing.get("lanes", [])}
    want, isolated = compute_lanes(origins, destinations, coords, args.neighbours, args.max_km)
    wanted_keys = {(l["Origin"], l["Destination"]) for l in want}

    created = updated = unchanged = failed = 0
    for lane in want:
        key = (lane["Origin"], lane["Destination"])
        days = lane["LeadTime"] // NS_PER_DAY
        label = f"{lane['Origin']} -> {lane['Destination']}  {days}d  cost {lane['UnitHandlingCost']}"
        if key in have and same_lane(have[key], lane):
            unchanged += 1
            continue
        verb = "UPDATE" if key in have else "CREATE"
        if args.dry_run:
            print(f"  would {verb:<6} {label}")
            created += verb == "CREATE"
            updated += verb == "UPDATE"
            continue
        try:
            st, body = nip.call("PUT", "/v1/transfer-lanes", lane)
        except SetupError as e:
            print(f"  FAILED {label}: {e}")
            failed += 1
            continue
        if st in (200, 201):
            outcome = (body or {}).get("outcome", "")
            print(f"  {verb:<6} {label}  ({outcome or st})")
            created += st == 201
            updated += st == 200 and outcome != "UNCHANGED"
            unchanged += st == 200 and outcome == "UNCHANGED"
        else:
            print(f"  FAILED {label}: {st} {body}")
            failed += 1

    unmanaged = sorted(k for k in have if k not in wanted_keys)
    if unmanaged:
        print("\nlanes in NIP that this rule does not compute (left alone):")
        for o, d in unmanaged:
            print(f"  {o} -> {d}  (enabled={have[(o, d)].get('Enabled')})")
    if no_coords:
        print(f"\nNO LANES for {', '.join(no_coords)}: no coordinates (not in {os.path.basename(args.coordinates)}); "
              f"a real new site needs --refresh-coordinates")
    if isolated:
        print(f"\norigins with no destination in range in their country: {', '.join(isolated)}")
    print(f"\nseed-transfer-lanes: {len(origins)} origins, {len(destinations)} destinations, {len(want)} lanes computed: "
          f"{created} {'would be ' if args.dry_run else ''}created, {updated} {'would be ' if args.dry_run else ''}updated, "
          f"{unchanged} unchanged, {len(unmanaged)} unmanaged, {failed} failed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
