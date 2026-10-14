#!/usr/bin/env python3
"""Seed every Active site's inter-site transfer capability from its role's default.

WHY THIS EXISTS
---------------
facility-layout keeps transfer capability an explicit, revisioned, per-site
command (its ADR-0035): nothing flips it automatically, and a role change never
touches it (ADR-0037). What the ecosystem needed was the ONE-TIME application of
"capability follows the site's role in the network" (final-gaps decision E2):
FCs that store ambient inventory are origin AND destination, Micro-FCs are
destination only, cross-docks and returns centres are origin only, fresh-grocery
FCs and parcel-network nodes are neither. network-inventory-planning only ever
proposes transfers between sites whose capability allows them.

The table is NOT hard-coded here. facility-layout publishes it as
`GET /site-roles/transfer-defaults`; this script reads it, reads `GET /sites`,
and for every Active site PUTs `/sites/{siteCode}/transfer-capability` with its
role's defaults.

SEMANTICS
---------
  site state                                      action
  Active, capability already == role default      nothing (no PUT: no revision, no event)
  Active, capability differs from role default    PUT the full snapshot -> revision+1, SiteCapabilityChanged
  Active, siteRole UNSPECIFIED (or absent)        NEVER touched; listed as "needs an operator decision"
  Active, role has no row in transfer-defaults    NEVER touched; listed as "needs an operator decision"
  not Active (Decommissioned)                     NEVER touched (its capability is frozen, 409 site-not-active)

A site whose capability was never set reads as capable of nothing at revision 0;
when its role's default is also "neither", it is already at the target and is
left alone (writing would only publish a revision that changes nothing).

Optimistic concurrency (facility-layout ADR-0025/0035): the PUT carries no
version; a concurrent writer makes it lose with 409 `concurrent-modification`.
The script then re-reads the capability and, if it is still not at the target,
re-PUTs (bounded by --retries). If the other writer already set the target, the
re-read turns the site into a no-op. Every other non-200 PUT is a failure.

Idempotent: a second run against an unchanged facility-layout makes zero writes.

USAGE
-----
    # through Kong on the kind cluster (the default base URL)
    python3 scripts/seed-transfer-capability.py --dry-run
    python3 scripts/seed-transfer-capability.py

    # elsewhere (port-forward, another edge)
    python3 scripts/seed-transfer-capability.py --base-url http://localhost:8080

The base URL defaults to $FACILITY_LAYOUT_BASE_URL, then
http://localhost:8000/api/facility-layout.

EXIT CODES
----------
  0  every Active, classified site is at its role's default (or would be, with --dry-run)
  1  at least one site's read or PUT failed (the others are still reconciled)
  2  the defaults table or the site list could not be read / was malformed (nothing written)

Stdlib only: it runs from a bare python3 on an operator's machine or in CI.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

DEFAULT_BASE_URL = "http://localhost:8000/api/facility-layout"
UNSPECIFIED = "UNSPECIFIED"
ACTIVE = "Active"
CONCURRENT_MODIFICATION = "concurrent-modification"


class SetupError(RuntimeError):
    """The defaults table or the site list is unusable: abort before any write (exit 2)."""


class SiteError(RuntimeError):
    """One site could not be reconciled (exit 1; the run continues with the next site)."""


class Api:
    """A tiny JSON-over-HTTP client. 4xx/5xx are returned, never raised."""

    def __init__(self, base_url: str, timeout: float = 10.0, transport_retries: int = 2,
                 retry_delay_s: float = 0.5):
        self.base = base_url.rstrip("/")
        self.timeout = timeout
        self.transport_retries = transport_retries
        self.retry_delay_s = retry_delay_s

    def call(self, method: str, path: str, body: dict | None = None) -> tuple[int, object]:
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
                # Only a GET is retried on 5xx: a PUT that 5xx'd may or may not
                # have applied, and the caller re-reads before deciding again.
                if status >= 500 and method == "GET" and attempt < self.transport_retries:
                    attempt += 1
                    time.sleep(self.retry_delay_s)
                    continue
                return status, decoded
            except (urllib.error.URLError, TimeoutError, ConnectionError) as e:
                if attempt < self.transport_retries:
                    attempt += 1
                    time.sleep(self.retry_delay_s)
                    continue
                reason = getattr(e, "reason", e)
                raise SiteError(f"{method} {self.base + path}: {reason}") from e


def _decode(raw: bytes) -> object:
    if not raw:
        return None
    try:
        return json.loads(raw)
    except ValueError:
        return {"raw": raw.decode(errors="replace")}


def problem_type(body: object) -> str:
    """The last path segment of an RFC 7807 `type` (e.g. concurrent-modification), or ''."""
    if isinstance(body, dict):
        return str(body.get("type") or "").rstrip("/").rsplit("/", 1)[-1]
    return ""


def load_defaults(api: Api) -> dict[str, tuple[bool, bool]]:
    """GET /site-roles/transfer-defaults -> {siteRole: (origin, destination)}."""
    try:
        status, body = api.call("GET", "/site-roles/transfer-defaults")
    except SiteError as e:
        raise SetupError(str(e)) from e
    if status != 200 or not isinstance(body, list):
        raise SetupError(f"GET /site-roles/transfer-defaults -> {status} {body}")
    table: dict[str, tuple[bool, bool]] = {}
    for row in body:
        if not isinstance(row, dict):
            raise SetupError(f"transfer-defaults: row is not an object: {row!r}")
        role = row.get("siteRole")
        origin, dest = row.get("transferOriginEnabled"), row.get("transferDestinationEnabled")
        if not isinstance(role, str) or not role or not isinstance(origin, bool) or not isinstance(dest, bool):
            raise SetupError(f"transfer-defaults: malformed row {row!r}")
        if role == UNSPECIFIED:
            raise SetupError("transfer-defaults: UNSPECIFIED must have no row (facility-layout ADR-0037)")
        if role in table:
            raise SetupError(f"transfer-defaults: duplicate row for {role}")
        table[role] = (origin, dest)
    if not table:
        raise SetupError("transfer-defaults: the table is empty")
    return table


def load_sites(api: Api) -> list[dict]:
    """GET /sites -> the site list, ordered by site code."""
    try:
        status, body = api.call("GET", "/sites")
    except SiteError as e:
        raise SetupError(str(e)) from e
    if status != 200 or not isinstance(body, list):
        raise SetupError(f"GET /sites -> {status} {body}")
    for s in body:
        if not isinstance(s, dict) or not s.get("siteCode"):
            raise SetupError(f"GET /sites: malformed site {s!r}")
    return sorted(body, key=lambda s: s["siteCode"])


def read_capability(api: Api, code: str) -> tuple[bool, bool, int]:
    status, body = api.call("GET", f"/sites/{urllib.parse.quote(code, safe='')}/transfer-capability")
    if status != 200 or not isinstance(body, dict):
        raise SiteError(f"GET transfer-capability -> {status} {body}")
    origin, dest = body.get("transferOriginEnabled"), body.get("transferDestinationEnabled")
    if not isinstance(origin, bool) or not isinstance(dest, bool):
        raise SiteError(f"GET transfer-capability: malformed body {body}")
    return origin, dest, int(body.get("capabilityRevision") or 0)


def fmt(cap: tuple[bool, bool]) -> str:
    return f"origin={'yes' if cap[0] else 'no'} destination={'yes' if cap[1] else 'no'}"


def reconcile_site(api: Api, code: str, target: tuple[bool, bool], *, dry_run: bool,
                   retries: int) -> tuple[str, str]:
    """-> (outcome, detail); outcome is one of noop, would-set, set. Raises SiteError."""
    origin, dest, rev = read_capability(api, code)
    if (origin, dest) == target:
        return "noop", f"already {fmt(target)} (revision {rev})"
    if dry_run:
        return "would-set", f"{fmt((origin, dest))} (revision {rev}) -> {fmt(target)}"
    body = {"transferOriginEnabled": target[0], "transferDestinationEnabled": target[1]}
    path = f"/sites/{urllib.parse.quote(code, safe='')}/transfer-capability"
    for attempt in range(retries + 1):
        status, resp = api.call("PUT", path, body)
        if status == 200 and isinstance(resp, dict):
            got = (resp.get("transferOriginEnabled"), resp.get("transferDestinationEnabled"))
            if got != target:
                raise SiteError(f"PUT returned 200 but the capability is {got}, not {target}")
            return "set", (f"{fmt((origin, dest))} (revision {rev}) -> {fmt(target)} "
                           f"(revision {resp.get('capabilityRevision')})")
        if status == 409 and problem_type(resp) == CONCURRENT_MODIFICATION and attempt < retries:
            # Lost the optimistic-concurrency race: re-read, and stop if the
            # other writer already put the site where we wanted it.
            origin, dest, rev = read_capability(api, code)
            if (origin, dest) == target:
                return "noop", f"already {fmt(target)} (set concurrently, revision {rev})"
            continue
        raise SiteError(f"PUT transfer-capability -> {status} {resp}")
    raise SiteError("PUT transfer-capability: retries exhausted")  # pragma: no cover


def run(api: Api, *, dry_run: bool, retries: int, out=None) -> int:
    out = out if out is not None else sys.stdout
    try:
        defaults = load_defaults(api)
        sites = load_sites(api)
    except SetupError as e:
        print(f"error: {e}", file=out)
        print("seed-transfer-capability: nothing written", file=out)
        return 2

    print(f"target    : {api.base}", file=out)
    print(f"mode      : {'DRY RUN (no writes)' if dry_run else 'apply'}", file=out)
    print(f"defaults  : {len(defaults)} roles", file=out)
    for role, cap in defaults.items():
        print(f"  {role:<28} {fmt(cap)}", file=out)
    print(file=out)

    counts = {"noop": 0, "would-set": 0, "set": 0}
    failed: list[str] = []
    decisions: list[str] = []
    inactive: list[str] = []
    for site in sites:
        code = site["siteCode"]
        status = site.get("status")
        role = site.get("siteRole") or UNSPECIFIED
        if status != ACTIVE:
            inactive.append(code)
            print(f"  {code:<10} skip       {status}: capability is frozen, not touched", file=out)
            continue
        if role == UNSPECIFIED:
            decisions.append(f"{code} (siteRole UNSPECIFIED: set it with PUT /sites/{code}/role)")
            print(f"  {code:<10} DECISION   siteRole UNSPECIFIED: not touched, needs an operator decision", file=out)
            continue
        if role not in defaults:
            decisions.append(f"{code} (siteRole {role} has no row in /site-roles/transfer-defaults)")
            print(f"  {code:<10} DECISION   siteRole {role} has no default: not touched", file=out)
            continue
        try:
            outcome, detail = reconcile_site(api, code, defaults[role], dry_run=dry_run, retries=retries)
        except SiteError as e:
            failed.append(code)
            print(f"  {code:<10} FAILED     {role}: {e}", file=out)
            continue
        counts[outcome] += 1
        label = {"noop": "unchanged", "would-set": "would SET", "set": "SET"}[outcome]
        print(f"  {code:<10} {label:<10} {role}: {detail}", file=out)

    print(file=out)
    if decisions:
        print("sites needing an operator decision (never written by this seed):", file=out)
        for d in decisions:
            print(f"  - {d}", file=out)
    summary = (f"seed-transfer-capability: {counts['set']} set, {counts['would-set']} would set, "
               f"{counts['noop']} unchanged, {len(decisions)} need a decision, "
               f"{len(inactive)} not active, {len(failed)} failed")
    print(summary, file=out)
    if failed:
        print(f"FAILED for: {', '.join(failed)} (re-run after fixing; converged sites are no-ops)", file=out)
        return 1
    return 0


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--base-url", default=os.environ.get("FACILITY_LAYOUT_BASE_URL") or DEFAULT_BASE_URL,
                    help=f"facility-layout base URL (default: $FACILITY_LAYOUT_BASE_URL or {DEFAULT_BASE_URL})")
    ap.add_argument("--dry-run", action="store_true", help="print the plan, write nothing")
    ap.add_argument("--retries", type=int, default=3,
                    help="re-read + re-PUT attempts after a 409 concurrent-modification (default 3)")
    ap.add_argument("--timeout", type=float, default=10.0, help="per-request timeout in seconds (default 10)")
    a = ap.parse_args(argv)
    if a.retries < 0:
        ap.error("--retries must be >= 0")
    return run(Api(a.base_url, timeout=a.timeout), dry_run=a.dry_run, retries=a.retries)


if __name__ == "__main__":
    sys.exit(main())
