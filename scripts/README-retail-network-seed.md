# Seeding the retail network (`scripts/seed-retail-network.py`)

The ten retail-network services (namespace `warehouse-systems`, Kong routes
`/api/<context>`) are deployed **empty**: no vendor, no node, no service area, no
catalogue, no stock. A storefront checkout therefore finds no offer and no purchase order
is ever issued. This seed puts the minimum in place so **one order can be quoted, sourced
and turned into a purchase order from ONE fulfillment node** (the simulation site `site-1`).

It is a **stand-in** for the fleet's own supply loop (network-fulfillment ADR 0027:
node profile and inventory feed). When that loop runs, its declarations win: see
[Hand-over to the fleet](#hand-over-to-the-fleet).

> **Not run against any cluster by the PR that added it.** It was built and tested
> against an in-process fake (`make seed-scripts-test`) and probed with GET requests
> only (`--dry-run`, `--verify`). The first real run needs the owner's word.

## Run it (owner)

Prerequisites: the kind cluster is up, the ten services are Ready, Kong answers on
`http://localhost:8000` (`scripts/up.sh`). Stdlib `python3` only; no secrets, no tokens.

```bash
make seed-network-dry-run   # the plan: GETs only, writes nothing
make seed-network           # WRITES to the cluster, then prints the PASS/FAIL table
make seed-network-verify    # any time later: read-only PASS/FAIL table
make seed-network-translation        # READ-ONLY: the product dictionary of network-fulfillment (see below)
make seed-network-translation-check  # READ-ONLY: does helm-values/network-fulfillment.yaml match the network?
```

`RETAIL_NETWORK_BASE_URL` (default `http://localhost:8000/api`) points it elsewhere; each
service is `<base>/<context>`. Equivalent direct calls:

```bash
python3 scripts/seed-retail-network.py --dry-run
python3 scripts/seed-retail-network.py                    # seed, then verify
python3 scripts/seed-retail-network.py --verify --quote   # also one POST /delivery-offers:quote
```

`--quote` is opt-in because `POST /delivery-offers:quote` **persists a short-lived offer**:
it is the only non-GET request `--verify` can send, and without `--quote` it sends none.

Other flags: `--restock` (refeed the seeded quantities even where a feed exists),
`--reassign` (take over a postal prefix that belongs to another station),
`--no-verify`, `--data <file>`, `--settle-seconds`, `--tx-timeout-seconds`.

Exit codes: `0` seeded (or planned) and verified; `1` a write failed, a step was skipped
because of a failure, or a check failed; `2` a service is unreachable or does not answer
JSON (a Kong SPA fallback, a pod not Ready), or the data file is unusable (nothing written).

## What it seeds

The order is the dependency order; node-topology appears twice because a vendor node is
registered through vendor-connectivity (asynchronously) and only then can be activated
and joined by a lane. Counts are for a fresh cluster with the shipped data file.

| # | Context | Seeded through | Count |
|---|---------|----------------|-------|
| 1 | node-topology | `POST /regions`; `POST /nodes` (a network-operated `DELIVERY_STATION`) + `POST /nodes/{id}:activate` | 1 region, 1 station |
| 2 | vendor-connectivity | `POST /vendors` (`V-WS`); `POST /vendor/nodes` (`vendorNodeCode` = `site-1`, network-fulfillment's `SITE_ID`); `PUT /vendor/nodes/{id}/profile` (revision 1); every write is asynchronous and polled via `GET /vendor/transactions/{id}` | 1 vendor, 1 node, 1 profile |
| 3 | node-topology | `POST /nodes/{id}:activate` (the vendor node); `POST /lanes` (node -> station, `GROUND`, 120 min); `PUT /service-areas/{prefix}` (`787`, `786`) | 1 lane, 2 service areas |
| 4 | last-mile-delivery | `POST /waves`: one daily wave per service date, 14 days | 14 waves |
| 5 | offer-availability | `POST /catalog-items` (real fleet SKUs of the e2e product catalogue); `POST /listings` (item x node) | 86 items, 86 listings |
| 6 | vendor-connectivity | `POST /vendor/inventory` (`fullUpdate: true`, `basis: PHYSICAL`, 200 each), relayed to offer-availability | 1 feed |
| 7 | delivery-promise | nothing: the policy is the built-in default `v0` (`GET /promise-policies/current` is only read) | 0 |

A fresh run reports 31 created and 4 updated (2 activations, 1 profile, 1 feed).

Why waves: order-sourcing finds a path only through a delivery wave at the destination
station (no wave, no candidate, the assignment is `UNSOURCEABLE`), and waves are dated.
Re-run the seed (or just `make seed-network`) before the 14-day horizon ends; it only
adds the missing dates. The linehaul PICKUP departures need no seed: linehaul-transportation
generates them itself once the node is ACTIVE with a profile and an outbound lane (`--verify`
reads them). A direct node -> station lane is the allowed `FULFILLMENT_CENTER -> DELIVERY_STATION`
pair, so no sortation centre and no lane schedule are needed.

## Idempotency

Every write is an upsert by **natural key**: GET first, write only when needed, and a
409 on create means "exists". A second run against an unchanged cluster **sends no write
at all** (the unit tests assert it).

| Entity | Natural key | Rule |
|--------|-------------|------|
| region | `code` | absent -> create; `409 region-code-taken` = exists |
| delivery station | type + region + postal code | absent -> create; `PROPOSED` -> activate; any other status is left alone and reported |
| vendor | `vendorId` | absent -> onboard; a suspended vendor is reported, never reinstated |
| fulfillment node | `vendorRef` (`V-WS`, `site-1`) | absent -> register; **an existing node is adopted** (network-fulfillment ADR 0026 adopts, never registers twice) |
| node profile | `profileRevision` | declared only when the node's revision is **lower** than the data file's; a higher one is left alone |
| lane | origin + destination | an OPEN lane = exists; `409 duplicate-lane` = exists |
| service area | postal prefix | same station = exists; another station = reported and left alone (`--reassign` bumps the version) |
| wave | station + date + induct cutoff | an existing non-cancelled wave = exists |
| catalogue item | `title` | absent -> create (the network generates the id) |
| listing | item + node | absent -> create; `409 duplicate-listing` = exists |
| inventory | a listing that was never fed | fed once; a listing that already carries a feed is not overwritten unless `--restock` |

The full feed zeroes every listing of the node it omits, so the feed carries the node's
other listings at their current values.

`Idempotency-Key` is scoped to the run (`seed-rn:<run id>:...`): a retry inside the run
replays, a later run is a fresh attempt. A deterministic key would replay a **failed**
asynchronous transaction for 24 hours and block every retry.

## Hand-over to the fleet

`vendorNodeCode` is network-fulfillment's own `SITE_ID` (`site-1`, set in
`helm-values/network-fulfillment.yaml`), so network-fulfillment in live mode **adopts** the
seeded node instead of registering it. It is NOT `SIM1`, the facility-layout code of the
simulated building: the service converges its `SITE_ID` onto the node with the same code, so
a node seeded as `SIM1` would be left unused while a second, empty `site-1` was registered,
and nothing would fail. A unit test pins the data file to the values file's `SITE_ID`.
The seeded profile is revision 1: the fleet's own declaration (ADR 0027) will be
revision 2 or higher, and the seed never lowers or re-declares over it. Likewise a
listing the fleet has fed is not refed. Bumping a number deliberately is a data-file
change (`profileRevision` + 1), declared exactly once.

## The data file (`scripts/data/retail-network-seed.json`)

Node codes, SKUs, quantities, hours, cutoffs, lane and wave times live there, not in the
script. The SKUs are real SKUs of `e2e-tests` `fixtures/products/fulfilment-products.json`
(dimensions, weight and fragility copied from it). The title is the catalogue's natural key
and the product name a shopper sees in the storefront: the first five items keep their
original SKU-prefixed titles (live identities: renaming one creates a second item), every
later item carries a neutral shopper-facing title (brand and model names removed). Never edit
a title that is already on the network; add a new item instead. The storefront merchandising
of these SKUs (departments, prices, descriptions) is `e2e-tests`
`fixtures/storefront/catalogue.json`, provisioned by `make provision-storefront` there. The
script validates the file before it sends anything (exit 2).

## Verify (`--verify`)

A read-only table, e.g. `vendor V-WS ACTIVE`, `region`, `delivery station ... ACTIVE`,
`service area <prefix> -> <station>`, `node site-1 ACTIVE`, `node site-1 profile (vendor API)`
(revision and handling time as the vendor sees them), `lane ... OPEN`,
`pickup departures of site-1`, `listings of site-1 LIVE with stock` (availableQty per SKU),
`open waves ... (next 3 days)`, `promise policy readable`, and with `--quote` a delivery
quote. After a seed run it is retried a few times because the node views are fed by events.

## The product dictionary of network-fulfillment (`--emit-translation`, `--check-translation`)

network-fulfillment in live mode turns the `networkProductId` of a purchase-order line into
a fleet SKU through **one dictionary**: `productTranslation.mappings` in
`helm-values/network-fulfillment.yaml` (the chart renders it into `PRODUCT_TRANSLATION_FILE`).
In live mode the `networkProductId` **is the network's listing id**, and the inventory feed
(ADR 0027) will invert this same dictionary (SKU -> listing id). The listing ids are
**generated by the network** when this seed creates the listings, so nothing in the repo can
hold them ahead of time, and a reseeded network (fresh kind cluster, new ids) leaves the
dictionary silently stale: every live purchase-order line then fails translation and is
rejected. These two modes read the ids back from the network and close that gap.

**The values file is the only place the dictionary lives.** The seed never writes it: a
person pastes the block, a reviewer sees it in a PR.

```bash
make seed-network-translation > block.yaml   # stdout is the YAML alone, progress goes to stderr
make seed-network-translation-check          # compare helm-values/network-fulfillment.yaml with the network
```

The block, one mapping per SKU of the data file and node, sorted by SKU and then listing id,
to put at the top level of the values file in place of the existing `productTranslation:` block:

```yaml
productTranslation:
  mappings:
    - networkProductId: <listing id of ABO-B000B5KPG8 on site-1>
      sku: ABO-B000B5KPG8
    - networkProductId: <listing id of ABO-B000G0F3CY on site-1>
      sku: ABO-B000G0F3CY
    # ... one pair per SKU
```

**When to run them**

1. After `make seed-network` has put the listings in place and **before the PR that flips
   network-fulfillment to live**: emit, paste, then `make seed-network-translation-check`
   must say `dictionary matches the network (N mappings)`.
2. Again after **any reseed** (a new network hands out new ids), and whenever the data file's
   catalogue or nodes change.
3. They are not part of `make check` (they need the live cluster). Their unit tests are.

**Read-only.** Both modes send GET requests only (the HTTP client refuses any other verb
before it is sent, and a unit test records every request of the fake and asserts only GETs).
They stand alone: no other mode flag (`--dry-run`, `--verify`, `--restock`...) combines with them.

| Mode | Exit 0 | Exit 1 | Exit 2 |
|------|--------|--------|--------|
| `--emit-translation` | the block is on stdout | a node of the data file is not on the network, or a SKU has no catalogue item or no listing: **nothing on stdout**, one stderr line per problem (a partial dictionary must never look complete) | a service is unreachable or the data file is unusable |
| `--check-translation PATH` | one line, `dictionary matches the network (N mappings)` | the dictionary cannot be built (as above, on stderr), or the file differs: the diff on stdout | as above, or the values file is unreadable or not in the shape the parser accepts (it names the line); the network is not touched |

The diff names each difference once: `missing` (the network has the listing, the file has no
mapping), `extra` (the file maps an id the network does not have), `wrong` (a SKU that points
at another listing, which is what a reseed produces, or an id mapped to another SKU). The
stub fixture mappings the values file carries while network-fulfillment runs in stub mode
(ids ending `-LOCAL-<n>`) are flagged as such: they must not survive the flip, and the check
fails while any is present, even next to the right ones.

The standard library has no YAML reader, so `--check-translation` uses a strict hand parser
for the one shape the block has: a top-level `productTranslation:` whose `mappings:` list
(or `mappings: []`) has items of two lines, `networkProductId` and `sku`, as plain or quoted
strings. Everything else in the values file is ignored; anything unexpected inside the block
(flow style, another key, tabs, anchors, a repeated id) is refused with its line number
instead of being guessed at. The emitted block quotes any id a YAML reader could take for
another type (a leading digit, `yes`, ...) so it always reads back as a string.

## Troubleshooting

| Symptom | Meaning |
|---------|---------|
| exit 2, `not a JSON answer` | the Kong route is missing or the pod is not Ready; nothing was written |
| `transaction ... FAILED [ErrXxx]` | the owning context refused the vendor write; read the code, fix the data file, re-run |
| listing `SUPPRESSED` (`NODE_NOT_SELLABLE`) | offer-availability has not seen `NodeActivated` yet; wait and `make seed-network-verify` |
| wave `422 unknown-station` | last-mile-delivery has not seen the station yet; re-run |
| service area `left alone` | the prefix belongs to another station; `--reassign` if that is intended |
| station `is SUSPENDED` | an operator decision; the seed activates only `PROPOSED` nodes |
| `--emit-translation` exit 1, `node site-1 ... is not in node-topology` or `no listing on node site-1` | the network is not seeded (or only partly): run `make seed-network`, then emit again |
| `--check-translation` shows `wrong` / `missing` | the network was reseeded or the values file was pasted from an older run: emit again and replace the block |

## Not seeded on purpose

A customer order (a checkout creates real flow: a separate, explicit e2e step); delivery
service partners and routes (last-mile-delivery, needed only after the label);
node-performance scorecards (measured, not declared); a promise policy (the default is in
code); sortation or air nodes and linehaul lane schedules (multi-leg paths).

## Undoing

The network has no delete. Retire the node with `POST /nodes/{id}:retire`, discontinue the
items with `POST /catalog-items/{id}:discontinue`, close the lane with `POST /lanes/{id}:close`.

## Tests

`make seed-scripts-test` (CI job `seed-scripts`) runs `scripts/test_seed_retail_network.py`
against one in-process HTTP fake of node-topology, vendor-connectivity, offer-availability,
last-mile-delivery, delivery-promise and linehaul-transportation: the full seed, the second
run that writes nothing, dry run and verify (zero non-GET), adoption of an existing node,
revision rules, 409 tolerance, failed and never-finishing transactions, 429, an unreachable
service, DST-correct waves, and the validation of the data file. The product dictionary has
its own tests: the emitted block (sorted, valid, quoting), every way it can be incomplete
(nothing on stdout), the GET-only proof for emit and check, and the check against a match,
a missing, an extra, a wrong and a stub mapping and against malformed values files.
