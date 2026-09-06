#!/usr/bin/env python3
"""Seed process-path-management from the (superseded) static YAML catalogue.

WHY THIS EXISTS
---------------
config/process-paths/sortable-fc.yaml was, before process-path-management
existed, the boot-time source of truth read identically by
fulfillment-execution, wes-work-planning and workforce-management. That
file is now SUPERSEDED: those three services source their catalogue from
process-path-management's Kafka topic
(warehouse.process-path-management.events) when
var.deploy_process_path_kafka_source is true.

This script performs the one-way migration of that file's content INTO
process-path-management via its public REST API, so the paths a running
building depends on (PICK/PACK/REBIN/SLAM) exist in the new owner's store
and — critically — get published onto the topic the three consumers
replay.

It is deliberately IDEMPOTENT and safe to re-run:

  * A path that does not exist is created (POST -> 201, publishes
    ProcessPathCreated).
  * A path that exists with identical matchPrefix/requiredCapabilities is
    left completely alone (no PUT, so no spurious ProcessPathUpdated on
    the topic).
  * A path that exists but DIVERGES from the YAML is revised (PUT -> 200,
    publishes ProcessPathUpdated) — the YAML is treated as the authority
    during migration.
  * A path that exists but is DEACTIVATED is reported and skipped, never
    silently resurrected: process-path-management deliberately treats a
    deactivated path as a closed historical record (its own API returns
    422 on a revise), and quietly re-activating one would hide a real
    operator decision. Re-run with --allow-reactivate to opt in loudly.

RE-RUN AFTER A PUBLISHER CHANGE
-------------------------------
This fleet's use cases do Repo.Save THEN Publisher.Publish with no outbox
(a known, separately-tracked systemic gap). A path written while
process-path-management ran with EVENT_PUBLISHER=log therefore exists in
its Postgres store but was NEVER published to Kafka — so a consumer
replaying the topic will not see it. If that has happened, the store and
the topic diverge and this script's normal "already identical, skipping"
behaviour would leave the divergence in place forever.

--republish exists for exactly that case: it forces a republish of every
path in the YAML whose store state already matches, by writing an
explicit no-op-breaking revision and immediately restoring the intended
value. Use it ONLY when you know the store is ahead of the topic; the
default path never republishes anything.

USAGE
-----
    # Against a port-forwarded service (kubectl port-forward svc/... 8080:80)
    ./scripts/seed-process-paths.py --base-url http://localhost:8080

    # Preview without writing anything
    ./scripts/seed-process-paths.py --base-url http://localhost:8080 --dry-run

Exit code is 0 only when every path in the YAML ended up Active in
process-path-management with the YAML's exact definition.
"""

from __future__ import annotations

import argparse
import json
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

# The YAML catalogue is a tiny, fixed-shape document (a `building` string
# and a `paths` list of flat scalar/list fields). Parsing it with a small
# purpose-built reader keeps this script dependency-free -- it has to run
# from a bare `python3` on an operator's machine or in CI without a
# virtualenv, and PyYAML is not guaranteed to be present there.
DEFAULT_CATALOGUE = (
    Path(__file__).resolve().parent.parent / "config" / "process-paths" / "sortable-fc.yaml"
)

# process-path-management publishes to a topic its consumers replay from
# the beginning. A brand-new topic races the broker's own auto-creation:
# the first publish can fail with Unknown Topic Or Partition for up to
# ~1s even though the topic exists moments later. Retry writes briefly.
WRITE_RETRIES = 4
WRITE_RETRY_DELAY_S = 1.0


class SeedError(RuntimeError):
    """A failure that should abort the seed with a non-zero exit code."""


def parse_catalogue(text: str) -> list[dict]:
    """Extract the `paths` entries from the sortable-fc catalogue.

    Understands exactly the shape that file uses: a top-level `paths:`
    key, then a list of `- id: X` entries with `matchPrefix`, `direct`
    and a `requiredCapabilities` list of `- value` items. Comments and
    blank lines are ignored. Anything unexpected raises rather than
    being silently dropped -- a partially-parsed catalogue is exactly
    the failure mode the retired boot-time loader refused to allow.
    """
    paths: list[dict] = []
    current: dict | None = None
    in_paths = False
    in_caps = False

    for raw_line in text.splitlines():
        line = raw_line.split("#", 1)[0].rstrip()
        if not line.strip():
            continue

        stripped = line.strip()
        indent = len(line) - len(line.lstrip())

        if indent == 0:
            # A new top-level key ends the paths block.
            in_paths = stripped.startswith("paths:")
            in_caps = False
            continue

        if not in_paths:
            continue

        if stripped.startswith("- id:"):
            if current is not None:
                paths.append(current)
            current = {
                "pathId": stripped.split(":", 1)[1].strip(),
                "requiredCapabilities": [],
            }
            in_caps = False
            continue

        if current is None:
            raise SeedError(f"catalogue: entry field before any '- id:' -> {stripped!r}")

        if stripped.startswith("matchPrefix:"):
            current["matchPrefix"] = stripped.split(":", 1)[1].strip()
            in_caps = False
        elif stripped.startswith("direct:"):
            current["direct"] = stripped.split(":", 1)[1].strip().lower() == "true"
            in_caps = False
        elif stripped.startswith("requiredCapabilities:"):
            in_caps = True
        elif stripped.startswith("- ") and in_caps:
            current["requiredCapabilities"].append(stripped[2:].strip())
        else:
            raise SeedError(f"catalogue: unrecognised line -> {stripped!r}")

    if current is not None:
        paths.append(current)

    if not paths:
        raise SeedError("catalogue: no paths found")

    for p in paths:
        missing = [k for k in ("pathId", "matchPrefix") if not p.get(k)]
        if missing:
            raise SeedError(f"catalogue: {p.get('pathId', '?')} missing {missing}")
        if not p["requiredCapabilities"]:
            raise SeedError(f"catalogue: {p['pathId']} has empty requiredCapabilities")
        p.setdefault("direct", False)

    return paths


def request(base_url: str, method: str, path: str, body: dict | None = None,
            retries: int = 0) -> tuple[int, object]:
    """Issue one HTTP call, returning (status, decoded-body-or-None).

    4xx responses are returned like any other status (they are meaningful
    control flow here: 404 = absent, 409 = exists), never raised.
    """
    url = base_url.rstrip("/") + path
    data = json.dumps(body).encode() if body is not None else None
    headers = {"Accept": "application/json"}
    if data is not None:
        headers["Content-Type"] = "application/json"

    attempt = 0
    while True:
        req = urllib.request.Request(url, data=data, headers=headers, method=method)
        try:
            with urllib.request.urlopen(req, timeout=15) as resp:
                raw = resp.read()
                return resp.status, (json.loads(raw) if raw else None)
        except urllib.error.HTTPError as e:
            raw = e.read()
            try:
                decoded = json.loads(raw) if raw else None
            except json.JSONDecodeError:
                decoded = {"raw": raw.decode(errors="replace")}
            # A 5xx on a write can be the fresh-topic auto-creation race.
            if e.code >= 500 and attempt < retries:
                attempt += 1
                time.sleep(WRITE_RETRY_DELAY_S)
                continue
            return e.code, decoded
        except urllib.error.URLError as e:
            if attempt < retries:
                attempt += 1
                time.sleep(WRITE_RETRY_DELAY_S)
                continue
            raise SeedError(f"{method} {url}: {e}") from e


def same_definition(existing: dict, desired: dict) -> bool:
    """True when the stored path already matches the YAML exactly.

    requiredCapabilities is compared as an ordered list because that is
    how both the YAML and the API express it; a pure reordering is a real
    (if cosmetic) difference and revising it is harmless.
    """
    return (
        existing.get("matchPrefix") == desired["matchPrefix"]
        and list(existing.get("requiredCapabilities") or []) == desired["requiredCapabilities"]
    )


def seed_one(base_url: str, desired: dict, *, dry_run: bool,
             allow_reactivate: bool, republish: bool) -> str:
    """Reconcile a single path. Returns a short human-readable outcome."""
    path_id = desired["pathId"]
    status, existing = request(base_url, "GET", f"/process-paths/{path_id}")

    if status == 404:
        if dry_run:
            return "would CREATE"
        code, body = request(base_url, "POST", "/process-paths", desired, retries=WRITE_RETRIES)
        if code != 201:
            raise SeedError(f"{path_id}: create failed ({code}): {body}")
        return "CREATED (ProcessPathCreated published)"

    if status != 200 or not isinstance(existing, dict):
        raise SeedError(f"{path_id}: unexpected GET status {status}: {existing}")

    if str(existing.get("status", "")).upper() == "DEACTIVATED":
        if not allow_reactivate:
            return ("SKIPPED - path is DEACTIVATED in process-path-management. "
                    "It will NOT be in any consumer's catalogue. Re-run with "
                    "--allow-reactivate only if reactivating is intended.")
        return ("SKIPPED - DEACTIVATED and --allow-reactivate given, but this API "
                "has no reactivate operation; a deactivated id is permanent. "
                "Define a new pathId instead.")

    revision = {
        "matchPrefix": desired["matchPrefix"],
        "requiredCapabilities": desired["requiredCapabilities"],
    }

    if same_definition(existing, desired):
        if not republish:
            return "unchanged (already identical)"
        if dry_run:
            return "would REPUBLISH (--republish)"
        # A no-op revision is a 200 that deliberately does NOT publish, so
        # force a real change and then restore the intended value. Both
        # writes publish ProcessPathUpdated; the final stored state is
        # exactly the YAML's.
        nudge = {
            "matchPrefix": desired["matchPrefix"] + "-republish-nudge",
            "requiredCapabilities": desired["requiredCapabilities"],
        }
        code, body = request(base_url, "PUT", f"/process-paths/{path_id}", nudge,
                             retries=WRITE_RETRIES)
        if code != 200:
            raise SeedError(f"{path_id}: republish nudge failed ({code}): {body}")
        code, body = request(base_url, "PUT", f"/process-paths/{path_id}", revision,
                             retries=WRITE_RETRIES)
        if code != 200:
            raise SeedError(
                f"{path_id}: republish restore failed ({code}): {body} -- the path is "
                f"LEFT WITH THE NUDGE PREFIX and must be fixed by hand"
            )
        return "REPUBLISHED (ProcessPathUpdated published twice, final state = YAML)"

    if dry_run:
        return (f"would REVISE (stored matchPrefix={existing.get('matchPrefix')!r} "
                f"caps={existing.get('requiredCapabilities')} -> YAML "
                f"{desired['matchPrefix']!r} {desired['requiredCapabilities']})")

    code, body = request(base_url, "PUT", f"/process-paths/{path_id}", revision,
                         retries=WRITE_RETRIES)
    if code != 200:
        raise SeedError(f"{path_id}: revise failed ({code}): {body}")
    return "REVISED (ProcessPathUpdated published)"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--base-url", required=True,
                        help="process-path-management base URL, e.g. http://localhost:8080")
    parser.add_argument("--catalogue", type=Path, default=DEFAULT_CATALOGUE,
                        help=f"path to the YAML catalogue (default: {DEFAULT_CATALOGUE})")
    parser.add_argument("--dry-run", action="store_true",
                        help="report what would change without writing anything")
    parser.add_argument("--allow-reactivate", action="store_true",
                        help="do not treat a DEACTIVATED path as a hard skip")
    parser.add_argument("--republish", action="store_true",
                        help=("force a republish of paths whose stored state already matches "
                              "the YAML (use when the store is ahead of the Kafka topic)"))
    args = parser.parse_args()

    if not args.catalogue.is_file():
        print(f"error: catalogue not found: {args.catalogue}", file=sys.stderr)
        return 2

    try:
        desired_paths = parse_catalogue(args.catalogue.read_text())
    except SeedError as e:
        print(f"error: {e}", file=sys.stderr)
        return 2

    print(f"catalogue : {args.catalogue}")
    print(f"target    : {args.base_url}")
    print(f"paths     : {', '.join(p['pathId'] for p in desired_paths)}")
    if args.dry_run:
        print("mode      : DRY RUN (no writes)")
    if args.republish:
        print("mode      : REPUBLISH (identical paths will be re-published)")
    print()

    failures: list[str] = []
    warnings: list[str] = []
    for desired in desired_paths:
        try:
            outcome = seed_one(args.base_url, desired, dry_run=args.dry_run,
                               allow_reactivate=args.allow_reactivate,
                               republish=args.republish)
        except SeedError as e:
            outcome = f"FAILED - {e}"
            failures.append(desired["pathId"])
        if outcome.startswith("SKIPPED"):
            warnings.append(desired["pathId"])
        print(f"  {desired['pathId']:<12} {outcome}")

    print()
    if failures:
        print(f"FAILED for: {', '.join(failures)}", file=sys.stderr)
        return 1
    if warnings:
        print(f"completed with warnings for: {', '.join(warnings)}", file=sys.stderr)
        return 1
    print("all paths reconciled")
    return 0


if __name__ == "__main__":
    sys.exit(main())
