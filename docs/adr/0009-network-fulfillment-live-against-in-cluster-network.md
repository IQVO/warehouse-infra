# ADR 0009: network-fulfillment runs live against the in-cluster retail network

## Status

Proposed (2026-10-24). Takes effect when the owner accepts it and the flip pull request (decision 5)
merges. Replaces the "stub, deliberately and permanently" comment in `helm-values/network-fulfillment.yaml`,
a decision recorded only in that comment and in the header of `terraform/10-platform/network-fulfillment.tf`
(ADR 0002 D2 moved the values there but never decided the mode). Complements
[ADR 0005](0005-database-provisioning-by-jobs.md) and [ADR 0004](0004-one-application-registry.md): the ten
retail-network applications are registry entries like any other.

## Context

`network-fulfillment` is the fleet's anti-corruption layer to a retail network. Its values file kept it in
`stub` mode on this cluster for one stated reason: in stub mode it makes no external call and needs no
credentials, so the cluster cannot acknowledge a real retailer's order. That reason fitted a cluster with no
network on it. It does not fit the cluster any more:

- The ten retail-network bounded contexts run here (`warehouse-infra` #127), in the shared `warehouse-systems`
  namespace, each with its own database and its `retailnetwork.<context>.events` topics.
- The Vendor API (`vendor-connectivity`) is in-cluster and, like every REST and MCP surface of the fleet,
  unauthenticated. Live mode takes no credential (the chart's live check asks for URLs and a vendor id, not a
  secret). Nothing leaves the cluster: the "real retailer" the comment feared is an in-cluster simulation
  vendor, `V-WS`.
- The live adapter exists and is on `develop` (`network-fulfillment` ADR 0026 demand loop, ADR 0027 node
  profile, ADR 0028 inbound loop), and its image runs on this cluster since 2026-10-24 (`local-9e1392a28bd4`),
  still with `networkMode: stub`.

With stub left on, the two halves of the system are deployed side by side and never talk: no purchase order
ever reaches the fleet, and nothing the fleet does reaches the network.

## Decision

1. **On this cluster `network-fulfillment` runs `config.networkMode: live`.** `stub` stays the chart default
   and the mode of the unit tests, the local harnesses and any environment without a network. The values
   comment's rule that only a real-network environment sets `networkMode`, in its own values and never in
   this file, is dropped: these values are the simulation environment's, and the simulation environment has
   a network.
2. **The target is the Service, not Kong.** `config.networkBaseUrl` is
   `http://vendor-connectivity.warehouse-systems.svc.cluster.local:80`. The client appends `/vendor/...`, which
   the Service serves at its root; Kong's `/api/vendor-connectivity` prefix is stripped on the way in and has
   no business in a service-to-service call (the OpenAPI `servers.url` also disagrees with the live Kong
   prefix, which is one more reason not to build the URL from it). The vendor account is
   `config.networkVendorId: V-WS`. The inbound loop's three URLs and its consumer group are set with it:
   `inboundReceivingUrl`, `productMasterUrl`, `inboundReceiptConsumerGroup`.
3. **The namespace stays shared.** The network runs in `warehouse-systems`, as `warehouse-infra` #127 deployed
   it. Moving the ten contexts to a namespace of their own is a redeploy of ten live services and is a
   separate decision; nothing here depends on it, and the Service URL above is the only thing it would change.
4. **The dictionary is generated from the network, never typed.** In live mode `networkProductId` is the
   network's listing id (`network-fulfillment` ADR 0026 Decision 4), and the network generates listing ids when
   the seed creates them. `productTranslation.mappings` in the values file is the only place those ids become
   SKUs, and ADR 0027 part 2 inverts it to feed stock. So: `make seed-network-translation` prints the block from
   the live network, and `make seed-network-translation-check` fails when the values file differs from the
   network (a reseeded cluster, or the `ASIN-LOCAL-*` stub fixtures). It is run before the flip and after any
   reseed. A stale dictionary does not crash anything: every purchase-order line fails translation, so the
   order is refused (the adapter reports `UNKNOWN_LISTING` to the network), which is why a check exists.
5. **The flip is one pull request, and merging it is the cluster change.** ArgoCD syncs this repository's
   `develop`, so merging the values change switches the running service. It needs the owner's word, and it
   waits for these, each checkable:
   1. the image with the live adapter, profile worker and inbound loop is applied (done 2026-10-24);
   2. the network is seeded: `make seed-network` has run and `make seed-network-verify` passes, **and the
      seeded fulfillment node's `vendorNodeCode` is the service's own `SITE_ID`** (`site-1`). In live mode the
      service converges its site onto the network node with that code, and adopts the node when it exists. The
      first version of the seed named its node `SIM1`, the facility-layout code of the simulated building,
      which is not the site id this service computes offers for: left alone, the service would register a
      second, empty node `site-1` and leave the seeded one, with the listings, service area and waves,
      unused, and nothing would fail loudly. The seed data is corrected before the seed is run;
   3. `make seed-network-translation-check` passes against the values the PR carries;
   4. the PR sets `networkMode`, `networkBaseUrl`, `networkVendorId`, `inboundReceivingUrl`, `productMasterUrl`,
      `inboundReceiptConsumerGroup` and `networkNodes.nodes` for the one site (`siteCode` = `SITE_ID`),
      **removes `stubDemand.demands`** (the chart refuses to render live with seeded demand) and replaces the
      stub `productTranslation` fixtures with the generated block;
   5. its header comment is rewritten to say what this ADR says, and the header of
      `terraform/10-platform/network-fulfillment.tf` stops pointing at "why networkMode stays stub".
6. **The inventory feed does not gate the flip.** The seed declares stock once, as the stand-in its data file
   names for ADR 0027 part 2. Until the feed ships, quantities on the network are the seed's and do not follow
   the fleet's capacity, so a scenario that saturates a path and expects the listing to shrink cannot pass.
   Purchase orders, acknowledgement, labels, shipment confirmation and the inbound loop do not depend on it.
7. **Rollback is a values revert.** Setting `networkMode` back to `stub` and merging restores the old behaviour;
   the submission ledger and the node map stay in the database. A purchase order acknowledged on the network
   but not yet confirmed when the revert lands is picked up by the reconcile pass on the next flip, not lost.

## Consequences

- Both ecosystems are wired on this cluster for the first time: a checkout reaches the fleet as a purchase
  order, and the fleet's label and shipment confirmation reach the network.
- A merge to this repository's `develop` can now change business behaviour, not only deployment. The flip
  pull request is the only one that carries that weight and is reviewed as such.
- The cluster-run end-to-end scenario for seller inbound plays the fleet's part through the Vendor API with a
  fresh vendor per run. Live `network-fulfillment` acts for `V-WS` only, so the two do not touch, but the
  scenario's remark that the ACL "runs in stub mode there" is out of date after the flip.
- The dictionary becomes a generated artefact that must be regenerated after a reseed. The check target makes
  that visible instead of leaving it to be noticed as rejected orders.
- Open and not decided here: the namespace move (decision 3), the inventory feed (decision 6) and seeding by a
  declarative job instead of an owner-run script.
