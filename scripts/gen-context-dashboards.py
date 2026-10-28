#!/usr/bin/env python3
"""Generate the per-bounded-context Grafana dashboards, plus the fleet-wide
Kong API Gateway dashboard, as committed JSON under terraform/dashboards/,
and the per-context Prometheus alert rules as
terraform/alerting/warehouse-alert-rules.json (see build_alert_rules).

This is the SOURCE for those dashboards -- edit the CONTEXTS table (or the
panel builders) below and re-run this script, never hand-edit the generated
JSON files directly (same discipline this repo already applies to
Docusaurus's generated API reference: generated files are a build output,
not a place to patch).

Run from the repo root:

    python3 scripts/gen-context-dashboards.py

Why generated rather than hand-written per context: all eight bounded
contexts share the identical panel shape (Kong gateway RED for that
context's route, this service's own HTTP RED, its Tier-2 business
counter(s), Go runtime) -- see ADR-0009 (order-management) /
ADR-0019 (fulfillment-execution) "standard metrics convention". Only the
service-name regex, Kong route/service label, and business-metric queries
differ per context. Hand-maintaining eight near-identical 900-line JSON
files would drift the moment the shared shape changes; a single generator
keeps that shape enforced by construction.

Metric-name provenance (verified against each service's own
internal/adapters/outbound/telemetry (or internal/observability) package
on origin/develop, not guessed): OTel dotted instrument names become
Prometheus names with dots and hyphens replaced by underscores and a
`_total` suffix appended to counters -- e.g. Go source
`facility.location_slot.registrations` (an Int64Counter) is exactly the
`facility_location_slot_registrations_total` series confirmed live in this
cluster's Prometheus. The same transform is applied by hand below for the
seven other contexts' counters, since not every one has fired yet in this
local cluster to confirm empirically.
"""
import json
import os

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

PROM_DS = {"type": "prometheus", "uid": "prometheus"}
LOKI_DS = {"type": "loki", "uid": "loki"}


def target(expr, ref_id="A", legend=None):
    t = {"refId": ref_id, "datasource": PROM_DS, "expr": expr}
    if legend:
        t["legendFormat"] = legend
    return t


def loki_target(expr, ref_id="A", legend=None):
    t = {"refId": ref_id, "datasource": LOKI_DS, "expr": expr}
    if legend:
        t["legendFormat"] = legend
    return t


def panel(x, y, w, h, title, description, targets, unit="short", ptype="timeseries"):
    return {
        "type": ptype,
        "title": title,
        "description": description,
        "datasource": PROM_DS,
        "gridPos": {"h": h, "w": w, "x": x, "y": y},
        "fieldConfig": {"defaults": {"unit": unit}, "overrides": []},
        "targets": targets,
    }


def logs_panel(x, y, w, h, title, description, targets, ptype="logs", extra_options=None):
    """A Loki-backed panel. ptype='logs' for a raw scrolling log view,
    'timeseries' for a rate-of-log-lines-over-time chart (built on Loki's
    range-query log-line counting, not a Prometheus metric)."""
    p = {
        "type": ptype,
        "title": title,
        "description": description,
        "datasource": LOKI_DS,
        "gridPos": {"h": h, "w": w, "x": x, "y": y},
        "targets": targets,
    }
    if ptype == "logs":
        p["options"] = {
            "showTime": True,
            "showLabels": True,
            "showCommonLabels": False,
            "wrapLogMessage": True,
            "prettifyLogMessage": False,
            "enableLogDetails": True,
            "dedupStrategy": "none",
            "sortOrder": "Descending",
        }
    else:
        p["fieldConfig"] = {"defaults": {"unit": "short"}, "overrides": []}
    if extra_options:
        p["options"] = {**p.get("options", {}), **extra_options}
    return p


def row(y, title):
    return {
        "type": "row",
        "title": title,
        "gridPos": {"h": 1, "w": 24, "x": 0, "y": y},
        "collapsed": False,
        "panels": [],
    }


# ---------------------------------------------------------------------------
# One entry per bounded context. `service_regex` covers every process
# reporting this context's business (OLTP + analytics projector/reports +
# MCP server) even though the naming isn't uniform across the fleet
# (order-management-projector vs. wes-projector vs. fulfillment-projector) --
# see kubectl/Prometheus label_values(service_name) as the ground truth this
# was built from. The Kong `service` label is DERIVED from `key` (see
# kong_service_regex below), never typed per entry: Kong names the service
# behind each chart-rendered HTTPRoute httproute.warehouse-systems.<route>.0,
# where <route> is the context's API route (`<key>`), its MCP route
# (`<key>-mcp`) or its reports route (`<key>-reports`).
# `outbox_lag_metric` (optional) is the context's outbox-lag gauge, only where
# its observability page names one -- it drives the "Transactional outbox"
# row; contexts without one get no such row.
# `loki_app` is the Loki/Alloy `app` label value for this context's pods --
# unlike `service_regex`, this one IS uniform across the fleet: Alloy's
# pipeline (logging.tf) maps `app` straight from the
# `app.kubernetes.io/name` pod label, and every one of this context's
# workloads (OLTP, frontend, mcp, projector, reports) shares that exact
# same label value (verified live: `label_values(app)` in Loki lists
# "order-management" once, covering all 5 of its pods) -- so a plain
# equality match is correct where the Prometheus side needs a regex.
# `business_metrics` is a list of (promql_metric, attribute_label, human
# description) triples -- attribute_label is the low-cardinality outcome/
# type/reason dimension to legend by, or None for a single-outcome counter.
# ---------------------------------------------------------------------------
CONTEXTS = [
    {
        "key": "order-management",
        "title": "Order Management",
        "uid": "warehouse-order-management",
        "service_regex": "order-management.*",
        "loki_app": "order-management",
        # Outbox lag gauge: the order-management observability page names the OTel
        # Float64ObservableGauge `order.outbox.lag_seconds` (age of the oldest unpublished
        # outbox_events row, 0 when drained) -> `order_outbox_lag_seconds` (observed live).
        "outbox_lag_metric": "order_outbox_lag_seconds",
        "business_metrics": [
            (
                "order_orders_received_total",
                "outcome",
                "Orders received at intake, by outcome (accepted or rejected before persistence). A rejected rate climbing relative to accepted means callers are sending intake requests this service's own domain invariants refuse to honor.",
            ),
        ],
    },
    {
        "key": "inventory-storage",
        "title": "Inventory & Storage",
        "uid": "warehouse-inventory-storage",
        "service_regex": "inventory-(storage|projector|reports).*",
        "loki_app": "inventory-storage",
        "business_metrics": [
            (
                "inventory_reservations_total",
                "outcome",
                "Reservations against usable inventory, by outcome (created or revoked). A revoke rate climbing towards the create rate means physical delivery is failing.",
            ),
        ],
    },
    {
        "key": "wes-work-planning",
        "title": "WES — Work Planning & Release",
        "uid": "warehouse-wes-work-planning",
        "service_regex": "wes-(work-planning|projector|reports).*",
        "loki_app": "wes-work-planning",
        # Outbox lag gauge: the wes-work-planning observability page names the OTel
        # Float64ObservableGauge `wes.outbox.lag_seconds` (age of the oldest unpublished
        # outbox_events row, 0 when drained) -> `wes_outbox_lag_seconds` (observed live).
        "outbox_lag_metric": "wes_outbox_lag_seconds",
        "business_metrics": [
            (
                "wes_work_units_released_total",
                "path_id",
                "Work units admitted into a process path's work pool by the release policy, by path.",
            ),
        ],
    },
    {
        "key": "fulfillment-execution",
        "title": "Fulfillment Execution",
        "uid": "warehouse-fulfillment-execution",
        "service_regex": "fulfillment-(execution|projector|reports).*",
        "loki_app": "fulfillment-execution",
        "business_metrics": [
            (
                "fulfillment_tasks_claimed_total",
                "task_type",
                "Tasks leased to a station by claimNext, by task type (Pick|Pack|SLAM|Rebin).",
            ),
            (
                "fulfillment_tasks_completed_total",
                "task_type",
                "Tasks completed by the claiming station, by task type.",
            ),
        ],
    },
    {
        "key": "workforce-management",
        "title": "Workforce Management",
        "uid": "warehouse-workforce-management",
        "service_regex": "workforce-(management|projector|reports).*",
        "loki_app": "workforce-management",
        # Outbox lag gauge: the workforce-management observability page names the OTel
        # Float64ObservableGauge `workforce.outbox.lag_seconds` (age of the oldest unpublished
        # outbox_events row, 0 when drained) -> `workforce_outbox_lag_seconds` (observed live).
        "outbox_lag_metric": "workforce_outbox_lag_seconds",
        "business_metrics": [
            (
                # Source: workforce-management internal/adapters/outbound/
                # telemetry/labor_metrics.go -- the OTel Int64Counter
                # `workforce.labor_assignments`; its attributes have been
                # `outcome`/`reason` since that repo's ADR-0015 conformance pass
                # (they were `workforce.assignment.outcome`/`.reason` before),
                # so grouping by the old `workforce_assignment_outcome` label
                # collapsed the panel into one unlabelled series (gap fix D20).
                "workforce_labor_assignments_total",
                "outcome",
                "Labor assignment attempts, by outcome (accepted/rejected). On rejection the counter also carries `reason` (uncertified, on_break, shift_ended, max_hours_exceeded, associate_not_found, internal_error).",
            ),
        ],
    },
    {
        "key": "facility-layout",
        "title": "Facility Layout",
        "uid": "warehouse-facility-layout",
        "service_regex": "facility-layout.*",
        "loki_app": "facility-layout",
        "business_metrics": [
            (
                "facility_location_slot_registrations_total",
                "outcome",
                "Attempts to register a coded location slot, by outcome (accepted, rejected_by_placement_rule, rejected).",
            ),
        ],
    },
    {
        "key": "labor-performance",
        "title": "Labor Performance",
        "uid": "warehouse-labor-performance",
        "service_regex": "labor-performance.*",
        "loki_app": "labor-performance",
        # Outbox lag gauge: the labor-performance observability page names the OTel
        # Float64ObservableGauge `labor_performance.outbox.lag_seconds` (age of the oldest unpublished
        # outbox_events row, 0 when drained) -> `labor_performance_outbox_lag_seconds` (derived from the instrument name, not yet observed live).
        "outbox_lag_metric": "labor_performance_outbox_lag_seconds",
        "business_metrics": [
            (
                "labor_performance_standards_defined_total",
                "outcome",
                "Attempts to define or revise an engineered labor standard, by outcome (accepted or rejected).",
            ),
        ],
    },
    {
        "key": "process-path-management",
        "title": "Process Path Management",
        "uid": "warehouse-process-path-management",
        "service_regex": "process-path-management.*",
        "loki_app": "process-path-management",
        # Outbox lag gauge: the process-path-management observability page names the OTel
        # Float64ObservableGauge `process_path_management.outbox.lag_seconds` (age of the oldest unpublished
        # outbox_events row, 0 when drained) -> `process_path_management_outbox_lag_seconds` (observed live).
        "outbox_lag_metric": "process_path_management_outbox_lag_seconds",
        "business_metrics": [
            (
                "process_path_management_paths_defined_total",
                "outcome",
                "Attempts to define a new process path, by outcome (accepted or rejected).",
            ),
        ],
    },
    {
        "key": "warehouse-planning",
        "title": "Warehouse Planning",
        "uid": "warehouse-warehouse-planning",
        # OTel service.name: `warehouse-planning` (the api, inboundhttp.
        # DefaultServiceName) and `warehouse-planning-reports` (the analytics
        # reader); the projector and MCP server share the `warehouse-planning`
        # prefix, so one prefix regex covers every process of this context.
        "service_regex": "warehouse-planning.*",
        "loki_app": "warehouse-planning",
        "business_metrics": [
            (
                # Source: warehouse-planning internal/adapters/outbound/
                # telemetry/metrics.go registers the OTel Int64Counter
                # `warehouse_planning.capacity_plans.created` with an `outcome`
                # attribute. The Prometheus name is derived with the rule in this
                # file's docstring (dots -> underscores, `_total` suffix on a
                # counter), not yet observed live in this cluster.
                "warehouse_planning_capacity_plans_created_total",
                "outcome",
                "CreateCapacityPlan attempts, by outcome (created or rejected). A rising rejected share means callers are submitting plans this service's own invariants refuse.",
            ),
        ],
    },
    {
        "key": "network-fulfillment",
        "title": "Network Fulfillment",
        "uid": "warehouse-network-fulfillment",
        # Chart OTEL_SERVICE_NAME values: `network-fulfillment` (api,
        # values.yaml otel.serviceName), `network-fulfillment-mcp`,
        # `netfulfil-projector`, `netfulfil-reports`. FIXED (ADR-0013 Tier-1
        # audit, 2026-10-12, PR IQVO/network-fulfillment#73): otelchi.Middleware
        # + otelchimetric.NewServerRequestDuration are now wired on every HTTP
        # surface, so the HTTP RED row below is live. Still no Tier-2 business
        # counter on the shared OTel path -- circuit_breaker_state{dependency}
        # (ADR 0004) remains on its own private Prometheus registry at GET
        # /metrics with no scrape target, hence business_metrics stays empty.
        "service_regex": "(network-fulfillment|netfulfil).*",
        "loki_app": "network-fulfillment",
        # network-fulfillment publishes no docs site (no Docusaurus config,
        # https://iqvo.github.io/network-fulfillment/ is 404), so its alert
        # rules link the runbook file on GitHub instead.
        "runbook_url": "https://github.com/IQVO/network-fulfillment/blob/develop/docs/operations/runbook.md",
        "business_metrics": [],
    },
    {
        "key": "network-inventory-planning",
        "title": "Network Inventory Planning",
        "uid": "warehouse-network-inventory-planning",
        # FIXED (ADR-0013 Tier-1 audit, 2026-10-12, PR
        # IQVO/network-inventory-planning#33): every chi router (REST API,
        # cmd/mcp, cmd/nip-projector, cmd/nip-reports) now wires the full
        # otelchi RED stack, and telemetry.Setup (the MeterProvider) is now
        # called from all four cmd/ mains instead of only the API's -- so the
        # HTTP RED row and Go-runtime row below are both live. No Tier-2
        # business counter exists yet for this context.
        "service_regex": "network-inventory-planning.*",
        "loki_app": "network-inventory-planning",
        "business_metrics": [],
    },
    {
        "key": "customer-ordering",
        "title": "Customer Ordering",
        "uid": "warehouse-customer-ordering",
        # Retail-network service on the fleet observability standard: Go-runtime and otelchi RED
        # metrics plus the business counter ordering.orders.placed (Prometheus: ordering_orders_placed_total).
        # The Kong route /api/customer-ordering is live but the chart attaches no Kong prometheus plugin, so the
        # Kong rows (including the 5xx panels and alert) stay empty until it does; the pod-restart
        # alerts are live.
        "service_regex": "customer-ordering.*",
        "loki_app": "customer-ordering",
        "runbook_url": "https://github.com/IQVO/customer-ordering/blob/develop/docs/operations/runbook.md",
        "business_metrics": [
            (
                "ordering_orders_placed_total",
                "outcome",
                "Checkout attempts by outcome (placed or rejected; reason says why a rejection happened, as a problem slug such as offer-not-quotable or promise-capacity-exhausted). A falling placed share with a rising offer-not-quotable or promise-capacity-exhausted means shoppers are refused at checkout by delivery promising, not by their own input; a rising internal-error means the service itself is failing.",
            ),
        ],
    },
    {
        "key": "pricing",
        "title": "Pricing",
        "uid": "warehouse-pricing",
        # Storefront-domain service on the fleet observability standard; Kong
        # rows stay empty until the chart attaches a Kong prometheus plugin.
        "service_regex": "pricing.*",
        "loki_app": "pricing",
        "runbook_url": "https://github.com/IQVO/pricing/blob/develop/docs/operations/runbook.md",
        "business_metrics": [
            (
                "pricing_quotes_issued_total",
                "outcome",
                "Price-quote requests by outcome (issued or rejected; reason says why). A falling issued share means shoppers cannot get binding prices; a rising internal-error means the service itself is failing.",
            ),
        ],
    },
    {
        "key": "product-content",
        "title": "Product Content",
        "uid": "warehouse-product-content",
        # Storefront-domain service on the fleet observability standard; Kong
        # rows stay empty until the chart attaches a Kong prometheus plugin.
        "service_regex": "product-content.*",
        "loki_app": "product-content",
        "runbook_url": "https://github.com/IQVO/product-content/blob/develop/docs/operations/runbook.md",
        "business_metrics": [
            (
                "content_products_published_total",
                "outcome",
                "Publish attempts by outcome (published or rejected; reason says why). A falling published share means catalog content is not reaching discovery; a rising internal-error means the service itself is failing.",
            ),
        ],
    },
    {
        "key": "product-discovery",
        "title": "Product Discovery",
        "uid": "warehouse-product-discovery",
        # Storefront-domain service on the fleet observability standard; Kong
        # rows stay empty until the chart attaches a Kong prometheus plugin.
        "service_regex": "product-discovery.*",
        "loki_app": "product-discovery",
        "runbook_url": "https://github.com/IQVO/product-discovery/blob/develop/docs/operations/runbook.md",
        "business_metrics": [
            (
                "discovery_searches_served_total",
                "outcome",
                "Search requests by outcome (served or rejected; reason says why). A falling served share means shoppers cannot find products; a rising internal-error means the service itself is failing.",
            ),
        ],
    },
    {
        "key": "shopping-cart",
        "title": "Shopping Cart",
        "uid": "warehouse-shopping-cart",
        # Storefront-domain service on the fleet observability standard; Kong
        # rows stay empty until the chart attaches a Kong prometheus plugin.
        "service_regex": "shopping-cart.*",
        "loki_app": "shopping-cart",
        "runbook_url": "https://github.com/IQVO/shopping-cart/blob/develop/docs/operations/runbook.md",
        "business_metrics": [
            (
                "cart_lines_added_total",
                "outcome",
                "Add-to-cart attempts by outcome (added or rejected; reason says why). A falling added share means shoppers cannot build carts; a rising internal-error means the service itself is failing.",
            ),
        ],
    },
    {
        "key": "checkout",
        "title": "Checkout",
        "uid": "warehouse-checkout",
        # Storefront-domain service on the fleet observability standard; Kong
        # rows stay empty until the chart attaches a Kong prometheus plugin.
        "service_regex": "checkout.*",
        "loki_app": "checkout",
        "runbook_url": "https://github.com/IQVO/checkout/blob/develop/docs/operations/runbook.md",
        "business_metrics": [],
    },
    {
        "key": "customer-payments",
        "title": "Customer Payments",
        "uid": "warehouse-customer-payments",
        # Storefront-domain service on the fleet observability standard; Kong
        # rows stay empty until the chart attaches a Kong prometheus plugin.
        "service_regex": "customer-payments.*",
        "loki_app": "customer-payments",
        "runbook_url": "https://github.com/IQVO/customer-payments/blob/develop/docs/operations/runbook.md",
        "business_metrics": [],
    },
    {
        "key": "payment-provider-simulator",
        "title": "Payment Provider Simulator",
        "uid": "warehouse-payment-provider-simulator",
        # Storefront-domain service on the fleet observability standard; Kong
        # rows stay empty until the chart attaches a Kong prometheus plugin.
        "service_regex": "payment-provider-simulator.*",
        "loki_app": "payment-provider-simulator",
        "runbook_url": "https://github.com/IQVO/payment-provider-simulator/blob/develop/docs/operations/runbook.md",
        "business_metrics": [],
    },
    {
        "key": "storefront-bff",
        "title": "Storefront BFF",
        "uid": "warehouse-storefront-bff",
        # Storefront-domain service on the fleet observability standard; Kong
        # rows stay empty until the chart attaches a Kong prometheus plugin.
        "service_regex": "storefront-bff.*",
        "loki_app": "storefront-bff",
        "runbook_url": "https://github.com/IQVO/storefront-bff/blob/develop/docs/operations/runbook.md",
        "business_metrics": [],
    },
    {
        "key": "storefront-web",
        "title": "Storefront Web",
        "uid": "warehouse-storefront-web",
        # Storefront-domain service on the fleet observability standard; Kong
        # rows stay empty until the chart attaches a Kong prometheus plugin.
        "service_regex": "storefront-web.*",
        "loki_app": "storefront-web",
        "runbook_url": "https://github.com/IQVO/storefront-web/blob/develop/docs/operations/runbook.md",
        "business_metrics": [],
    },
    {
        "key": "delivery-promise",
        "title": "Delivery Promise",
        "uid": "warehouse-delivery-promise",
        # Retail-network service on the fleet observability standard: Go-runtime and otelchi RED
        # metrics plus the business counter promising.promises.made (Prometheus: promising_promises_made_total).
        # The Kong route /api/delivery-promise is live but the chart attaches no Kong prometheus plugin, so the
        # Kong rows (including the 5xx panels and alert) stay empty until it does; the pod-restart
        # alerts are live.
        "service_regex": "delivery-promise.*",
        "loki_app": "delivery-promise",
        "runbook_url": "https://github.com/IQVO/delivery-promise/blob/develop/docs/operations/runbook.md",
        "business_metrics": [
            (
                "promising_promises_made_total",
                "outcome",
                "Attempts to make a delivery promise by outcome (made or refused; reason says why a refusal happened, as a problem slug such as offer-not-quotable or promise-capacity-exhausted). A falling made share with a rising offer-not-quotable or promise-capacity-exhausted means shoppers are offered dates the network can no longer keep (expired offers, full nodes); a rising internal-error means the service itself is failing.",
            ),
        ],
    },
    {
        "key": "last-mile-delivery",
        "title": "Last-Mile Delivery",
        "uid": "warehouse-last-mile-delivery",
        # Retail-network service on the fleet observability standard: Go-runtime and otelchi RED
        # metrics plus the business counter last_mile_delivery.package.attempted (Prometheus: last_mile_delivery_package_attempted_total).
        # The Kong route /api/last-mile-delivery is live but the chart attaches no Kong prometheus plugin, so the
        # Kong rows (including the 5xx panels and alert) stay empty until it does; the pod-restart
        # alerts are live.
        "service_regex": "last-mile-delivery.*",
        "loki_app": "last-mile-delivery",
        "runbook_url": "https://github.com/IQVO/last-mile-delivery/blob/develop/docs/operations/runbook.md",
        "business_metrics": [
            (
                "last_mile_delivery_package_attempted_total",
                "outcome",
                "Delivery attempts reported on routes, by outcome (delivered, failed or rejected; reason says why a report was rejected, as a problem slug such as route-not-started or already-delivered). A falling delivered share with a rising failed share means packages are not reaching recipients on the first van run (each package gets at most three failed attempts before it returns to its sender); a rising rejected share means driver or dispatch clients report attempts the route cannot take, and a rising internal-error reason means the service itself is failing.",
            ),
        ],
    },
    {
        "key": "linehaul-transportation",
        "title": "Linehaul Transportation",
        "uid": "warehouse-linehaul-transportation",
        # Retail-network service on the fleet observability standard: Go-runtime and otelchi RED
        # metrics plus the business counter linehaul.loads.dispatched (Prometheus: linehaul_loads_dispatched_total).
        # The Kong route /api/linehaul-transportation is live but the chart attaches no Kong prometheus plugin, so the
        # Kong rows (including the 5xx panels and alert) stay empty until it does; the pod-restart
        # alerts are live.
        "service_regex": "linehaul-transportation.*",
        "loki_app": "linehaul-transportation",
        "runbook_url": "https://github.com/IQVO/linehaul-transportation/blob/develop/docs/operations/runbook.md",
        "business_metrics": [
            (
                "linehaul_loads_dispatched_total",
                "outcome",
                "Load dispatch attempts by outcome (dispatched or rejected; reason says why a rejection happened, as a problem slug such as illegal-transition or not-found). A falling dispatched share with a rising illegal-transition means operators try to dispatch loads that were never closed, so freight is not leaving its origin node on schedule; a rising internal-error means the service itself is failing.",
            ),
        ],
    },
    {
        "key": "node-performance",
        "title": "Node Performance",
        "uid": "warehouse-node-performance",
        # Retail-network service on the fleet observability standard: Go-runtime and otelchi RED
        # metrics plus the business counter nodeperformance.scorecards.recomputed (Prometheus: nodeperformance_scorecards_recomputed_total).
        # The Kong route /api/node-performance is live but the chart attaches no Kong prometheus plugin, so the
        # Kong rows (including the 5xx panels and alert) stay empty until it does; the pod-restart
        # alerts are live.
        "service_regex": "node-performance.*",
        "loki_app": "node-performance",
        "runbook_url": "https://github.com/IQVO/node-performance/blob/develop/docs/operations/runbook.md",
        "business_metrics": [
            (
                "nodeperformance_scorecards_recomputed_total",
                "outcome",
                "Scorecards handled by the recompute scheduler, by outcome (recomputed or failed; reason says why a failure happened: concurrent-update or internal-error). A recomputed count that stays flat while nodes keep reporting means grading has stalled and published grades are going stale; a rising concurrent-update means writers contend for the same scorecards but the next run retries them; a rising internal-error means the service itself (usually its database) is failing.",
            ),
        ],
    },
    {
        "key": "node-topology",
        "title": "Node Topology",
        "uid": "warehouse-node-topology",
        # Retail-network service on the fleet observability standard: Go-runtime and otelchi RED
        # metrics plus the business counter topology.nodes.registered (Prometheus: topology_nodes_registered_total).
        # The Kong route /api/node-topology is live but the chart attaches no Kong prometheus plugin, so the
        # Kong rows (including the 5xx panels and alert) stay empty until it does; the pod-restart
        # alerts are live.
        "service_regex": "node-topology.*",
        "loki_app": "node-topology",
        "runbook_url": "https://github.com/IQVO/node-topology/blob/develop/docs/operations/runbook.md",
        "business_metrics": [
            (
                "topology_nodes_registered_total",
                "outcome",
                "Node registrations by outcome (registered or rejected; reason says why a rejection happened, as a problem slug such as vendor-node-code-taken or validation-failed). A rising vendor-node-code-taken or operator-not-allowed-for-node-type means onboarding clients send registrations the network rules refuse, not that the service is failing; a rising internal-error or concurrent-update means the service itself is.",
            ),
        ],
    },
    {
        "key": "offer-availability",
        "title": "Offer & Availability",
        "uid": "warehouse-offer-availability",
        # Retail-network service on the fleet observability standard: Go-runtime and otelchi RED
        # metrics plus the business counter availability.inventory_feeds.applied (Prometheus: availability_inventory_feeds_applied_total).
        # The Kong route /api/offer-availability is live but the chart attaches no Kong prometheus plugin, so the
        # Kong rows (including the 5xx panels and alert) stay empty until it does; the pod-restart
        # alerts are live.
        "service_regex": "offer-availability.*",
        "loki_app": "offer-availability",
        "runbook_url": "https://github.com/IQVO/offer-availability/blob/develop/docs/operations/runbook.md",
        "business_metrics": [
            (
                "availability_inventory_feeds_applied_total",
                "outcome",
                "Inventory feed attempts by outcome (applied, superseded, failed or rejected; reason says why a failed or rejected feed did not apply, as a problem slug such as listing-not-on-node, negative-availability or feed-already-applied). A falling applied share means shoppers see stale availability: a rising superseded means vendors send feeds out of order, a rising failed means vendor data does not match our listings, a rising internal-error means the service itself is failing.",
            ),
        ],
    },
    {
        "key": "order-sourcing",
        "title": "Order Sourcing",
        "uid": "warehouse-order-sourcing",
        # Retail-network service on the fleet observability standard: Go-runtime and otelchi RED
        # metrics plus the business counter sourcing.groups.sourced (Prometheus: sourcing_groups_sourced_total).
        # The Kong route /api/order-sourcing is live but the chart attaches no Kong prometheus plugin, so the
        # Kong rows (including the 5xx panels and alert) stay empty until it does; the pod-restart
        # alerts are live.
        "service_regex": "order-sourcing.*",
        "loki_app": "order-sourcing",
        "runbook_url": "https://github.com/IQVO/order-sourcing/blob/develop/docs/operations/runbook.md",
        "business_metrics": [
            (
                "sourcing_groups_sourced_total",
                "outcome",
                "Shipment groups of placed orders that order sourcing decided on, by outcome: queued (waiting for its release time), released (sent to a node at once, same-day), unsourceable (no node can ship it) or failed (nothing stored; reason says why, for example concurrent-update or internal-error). A rising unsourceable share means the network cannot fulfil what is being promised (stock, lanes or service areas are missing); a rising failed with internal-error means the service itself is failing and orders are not being sourced.",
            ),
        ],
    },
    {
        "key": "shipping-and-tracking",
        "title": "Shipping & Tracking",
        "uid": "warehouse-shipping-and-tracking",
        # Retail-network service on the fleet observability standard: Go-runtime and otelchi RED
        # metrics plus the business counter shipping.labels.issued (Prometheus: shipping_labels_issued_total).
        # The Kong route /api/shipping-and-tracking is live but the chart attaches no Kong prometheus plugin, so the
        # Kong rows (including the 5xx panels and alert) stay empty until it does; the pod-restart
        # alerts are live.
        "service_regex": "shipping-and-tracking.*",
        "loki_app": "shipping-and-tracking",
        "runbook_url": "https://github.com/IQVO/shipping-and-tracking/blob/develop/docs/operations/runbook.md",
        "business_metrics": [
            (
                "shipping_labels_issued_total",
                "outcome",
                "Label-issue attempts by outcome (issued or rejected; reason says why a rejection happened, as a problem slug such as ship-to-unavailable or label-already-issued). A falling issued share with a rising ship-to-unavailable means labels are blocked because customer-ordering cannot be reached, so packages are not entering the network; a rising label-already-issued means the caller is retrying without an Idempotency-Key; a rising internal-error means the service itself is failing.",
            ),
        ],
    },
    {
        "key": "vendor-connectivity",
        "title": "Vendor Connectivity",
        "uid": "warehouse-vendor-connectivity",
        # Retail-network service on the fleet observability standard: Go-runtime and otelchi RED
        # metrics plus the business counter vendor.submissions.processed (Prometheus: vendor_submissions_processed_total).
        # The Kong route /api/vendor-connectivity is live but the chart attaches no Kong prometheus plugin, so the
        # Kong rows (including the 5xx panels and alert) stay empty until it does; the pod-restart
        # alerts are live.
        "service_regex": "vendor-connectivity.*",
        "loki_app": "vendor-connectivity",
        "runbook_url": "https://github.com/IQVO/vendor-connectivity/blob/develop/docs/operations/runbook.md",
        "business_metrics": [
            (
                "vendor_submissions_processed_total",
                "outcome",
                "Vendor transactions (acknowledgements, shipment confirmations, inventory feeds, node registrations and profiles, inbound receipts) that reached an outcome, by outcome (succeeded or failed; reason is the Err code the vendor reads, such as ErrUpstreamUnavailable or ErrSimulatedFailure). A rising failed share means vendors are being told their writes did not apply: ErrUpstreamUnavailable means a neighbour context stopped answering, not that the vendors sent bad data.",
            ),
        ],
    },
    {
        "key": "seller-inbound",
        "title": "Seller Inbound",
        "uid": "warehouse-seller-inbound",
        # Retail-network service on the fleet observability standard: Go-runtime and otelchi RED
        # metrics plus the business counter seller_inbound.shipment.shipped (Prometheus: seller_inbound_shipment_shipped_total).
        # The Kong route /api/seller-inbound is live but the chart attaches no Kong prometheus plugin, so the
        # Kong rows (including the 5xx panels and alert) stay empty until it does; the pod-restart
        # alerts are live.
        "service_regex": "seller-inbound.*",
        "loki_app": "seller-inbound",
        "runbook_url": "https://github.com/IQVO/seller-inbound/blob/develop/docs/operations/runbook.md",
        "business_metrics": [
            (
                "seller_inbound_shipment_shipped_total",
                "outcome",
                "Attempts to ship an inbound shipment by outcome (shipped or rejected; reason says why a rejection happened, as a problem slug such as shipment-not-labelled, seller-suspended or node-cannot-receive). A falling shipped share with a rising shipment-not-labelled means sellers reach the ship step before labelling every carton; a rising node-cannot-receive means destination nodes are refusing stock; a rising internal-error means the service itself is failing.",
            ),
        ],
    },

    {
        "key": "product-master",
        "title": "Product Master",
        "uid": "warehouse-product-master",
        # OTel service.name: `product-master` (cmd/api), `product-master-mcp`
        # (cmd/mcp/router.go mcpServiceName), the projector and reports
        # processes share the `product-master` prefix -- one prefix regex
        # covers every process of this context, same convention as the other
        # apps.yaml-routed services.
        "service_regex": "product-master.*",
        "loki_app": "product-master",
        "business_metrics": [
            (
                # Source: product-master's RegisterProduct use case, behind
                # ports.ProductMetrics / telemetry.ProductMetrics (ADR-0013
                # Tier-2, PR IQVO/product-master#22). Int64Counter, unit
                # {product}.
                "product_master_products_registered_total",
                "outcome",
                "RegisterProduct attempts, by outcome (created, description_changed, or unchanged). A created rate flatlining means SKU onboarding/import has stalled.",
            ),
        ],
    },
    {
        "key": "inbound-receiving",
        "title": "Inbound Receiving",
        "uid": "warehouse-inbound-receiving",
        # OTel service.name: `inbound-receiving` (cmd/api), `inbound-receiving-mcp`
        # (cmd/mcp/router.go mcpServiceName), cmd/inbound-projector and
        # cmd/inbound-reports share the `inbound-receiving` prefix.
        "service_regex": "inbound-receiving.*",
        "loki_app": "inbound-receiving",
        "business_metrics": [
            (
                # Source: inbound-receiving's ReceiveLine use case, behind
                # ports.ReceiptMetrics / telemetry adapter (ADR-0013 Tier-2,
                # PR IQVO/inbound-receiving#15). Int64Counter, unit {unit}.
                "inbound_receiving_receipts_units_received_total",
                "outcome",
                "Units received onto a receipt line, by outcome (good or damaged). Per ADR 0003 only the good share ever becomes stock in inventory-storage, so a rising damaged share is cargo counted at the dock that will never become inventory.",
            ),
        ],
    },
    {
        "key": "slotting-optimization",
        "title": "Slotting Optimization",
        "uid": "warehouse-slotting-optimization",
        # Gap fix D10/D20. OTel service.name: `slotting-optimization`
        # (cmd/api, telemetry.newResource); cmd/mcp shares the prefix. Its
        # observability page (docs/docs/operations/observability.md on
        # origin/develop) states it defines NO business metric and no outbox
        # gauge: only otelchi's http.server.request.duration (no status code)
        # and the Go runtime metrics. So business_metrics stays empty (never
        # invent a metric) and there is no outbox-lag panel; the Kong rows are
        # live (its chart renders kong-plugins.yaml; kongPlugins.prometheus in
        # its values file).
        "service_regex": "slotting-optimization.*",
        "loki_app": "slotting-optimization",
        "business_metrics": [],
    },
    {
        "key": "pick-face-replenishment",
        "title": "Pick-Face Replenishment",
        "uid": "warehouse-pick-face-replenishment",
        # The service exports NO metric today (its observability page on
        # origin/develop: no meter, no OTel SDK, no /metrics, no otelchi), so
        # business_metrics stays empty (never invent a metric), there is no
        # outbox-lag gauge and the HTTP RED and Go-runtime rows stay empty
        # until it instruments itself. The Kong rows are live: the chart
        # renders the Kong prometheus plugin (helm-values/pick-face-replenishment.yaml).
        # service_regex follows the fleet prefix convention.
        "service_regex": "pick-face-replenishment.*",
        "loki_app": "pick-face-replenishment",
        "business_metrics": [],
    },
    {
        "key": "task-interleaving",
        "title": "Task Interleaving",
        "uid": "warehouse-task-interleaving",
        # Same state as pick-face-replenishment: its observability page on
        # origin/develop registers 0 OTel instruments and wires no otelchi, so
        # business_metrics stays empty and there is no outbox-lag gauge; the
        # Kong rows are live (kongPlugins.prometheus in its values file).
        "service_regex": "task-interleaving.*",
        "loki_app": "task-interleaving",
        "business_metrics": [],
    },
    {
        "key": "returns-processing",
        "title": "Returns Processing",
        "uid": "warehouse-returns-processing",
        # Same state as task-interleaving when it was registered: 0 OTel
        # instruments, no otelchi, no outbox-lag gauge, business_metrics
        # empty. One difference, deliberate and temporary: its chart ships no
        # gatewayApi HTTPRoute yet, so the Kong rows (5xx, SLO burn) stay
        # empty until that template lands in IQVO/returns-processing and the
        # route /api/returns-processing exists; pod-restart alerts are live
        # from day one.
        "service_regex": "returns-processing.*",
        "loki_app": "returns-processing",
        "business_metrics": [],
    },
    {
        "key": "exception-management",
        "title": "Exception Management",
        "uid": "warehouse-exception-management",
        # Same state as returns-processing above: 0 OTel instruments, no
        # gauge, empty business_metrics, and no gatewayApi HTTPRoute in its
        # chart yet — the Kong rows light up when /api/exception-management
        # is routed; pod-restart alerts are live from day one.
        "service_regex": "exception-management.*",
        "loki_app": "exception-management",
        "business_metrics": [],
    },
    {
        "key": "warehouse-ops-agent",
        "title": "Warehouse Ops Agent",
        "uid": "warehouse-warehouse-ops-agent",
        # warehouse-ops-agent is a different shape from the database-backed
        # contexts above (ops-agent.tf: no DB, no Kafka, a single process
        # cmd/agent) but it IS routed through Kong at
        # ${api_path_prefix}/warehouse-ops-agent (ops-agent.tf) and DOES emit
        # its own Tier-2-shaped OTel metrics for LLM arbitration (ADR 0004),
        # so it earns a dashboard like every other context rather than being
        # treated purely as the metrics-reader side of its design.
        "service_regex": "warehouse-ops-agent.*",
        "loki_app": "warehouse-ops-agent",
        "business_metrics": [
            (
                # Source: internal/adapters/outbound/telemetry/arbitration_metrics.go
                # -- renamed to the dotted OTel instrument name
                # `ops_agent.llm.arbitrations` in PR
                # IQVO/warehouse-ops-agent#131 (ADR-0013 conformance); the
                # Prometheus-exported series name is unchanged by that rename
                # (dots -> underscores, `_total` suffix on a counter).
                "ops_agent_llm_arbitrations_total",
                "source",
                "LLM-arbitration decisions (ADR 0004), by winning source (deterministic policy vs. model-backed Reasoner). A source shift with no corresponding LLM_MODE config change is worth investigating.",
            ),
            (
                "ops_agent_llm_agreement_total",
                "agree",
                "Valid model plans compared against the deterministic decision, by agreement. This ratio is the shadow-mode rollout gate: agree=true over the total is how confident the fleet is that the model-backed Reasoner can safely replace the deterministic policy.",
            ),
        ],
    },
]


def kong_service_regex(key):
    """PromQL regex for every Kong `service` label of one context: its API,
    MCP and reports routes (httproute.warehouse-systems.<key>[-mcp|-reports].N).

    Dots are matched with `[.]`, never with a backslash escape: inside a
    PromQL double-quoted string a single backslash before `.` is a parse
    error ("unknown escape sequence U+002E"), and that is exactly what the
    previous per-entry regexes put into the generated JSON. Every Kong panel
    of every context dashboard failed that way until gap fix D20 (verified
    against the cluster's Prometheus 3.14);
    scripts/test_gen_context_dashboards.py now rejects any backslash in a
    generated expression.
    """
    return f"httproute[.]warehouse-systems[.]{key}(-mcp|-reports)?[.][0-9]+"


def build_dashboard(ctx):
    svc_re = ctx["service_regex"]
    kong_re = kong_service_regex(ctx["key"])
    loki_app = ctx["loki_app"]
    # Excludes istio-proxy/istio-init noise -- every pod in this fleet has a
    # native sidecar (see kubernetes-deployment.md's Istio note) whose own
    # Envoy access logs would otherwise dominate a raw log panel that is
    # meant to show THIS context's application output.
    loki_selector = f'{{app="{loki_app}", container!~"istio-proxy|istio-init"}}'
    panels = []
    y = 0

    # --- Row: API Gateway (Kong) -------------------------------------------------
    panels.append(row(y, "API Gateway (Kong) — north-south view of this context's route"))
    y += 1
    panels.append(
        panel(
            0, y, 8, 8,
            "Request rate (Kong)",
            "Requests/sec Kong forwarded to this context's routes (API, MCP and reports), by HTTP status code. Kong sees a request even when the upstream pod never got instrumented (e.g. crashed before otelchi ran).",
            [target(
                f'sum by (code) (rate(kong_http_requests_total{{service=~"{kong_re}"}}[5m]))',
                legend="{{code}}",
            )],
            unit="reqps",
        )
    )
    panels.append(
        panel(
            8, y, 8, 8,
            "Error rate (Kong, 5xx)",
            "5xx responses Kong returned or proxied for this context, as a fraction of all requests. A 5xx here with a flat upstream error rate on the service's own panel below means Kong itself (or the network to the upstream) is failing, not the application.",
            [target(
                # `or vector(0)`: with no 5xx at all the numerator is an empty
                # vector, which would render "No data" instead of a healthy 0.
                f'(sum(rate(kong_http_requests_total{{service=~"{kong_re}", code=~"5.."}}[5m])) or vector(0)) '
                f'/ clamp_min(sum(rate(kong_http_requests_total{{service=~"{kong_re}"}}[5m])), 1e-9)',
                legend="5xx ratio",
            )],
            unit="percentunit",
        )
    )
    panels.append(
        panel(
            16, y, 8, 8,
            "Latency p95 (Kong request vs. upstream)",
            "kong_request_latency_ms is the full time Kong spent on the request (queueing + upstream + Kong overhead); kong_upstream_latency_ms isolates just the time waiting on this context's pod. A gap between the two that grows means Kong itself, not the service, is the bottleneck.",
            [
                target(
                    f'histogram_quantile(0.95, sum by (le) (rate(kong_request_latency_ms_bucket{{service=~"{kong_re}"}}[5m])))',
                    ref_id="A", legend="request (Kong total) p95",
                ),
                target(
                    f'histogram_quantile(0.95, sum by (le) (rate(kong_upstream_latency_ms_bucket{{service=~"{kong_re}"}}[5m])))',
                    ref_id="B", legend="upstream (service) p95",
                ),
            ],
            unit="ms",
        )
    )
    y += 8

    # --- Row: this context's own HTTP RED (otelchi) ------------------------------
    panels.append(row(y, "Service HTTP RED (OLTP + projector + reports + MCP)"))
    y += 1
    panels.append(
        panel(
            0, y, 8, 8,
            "Request rate by route",
            f"http_server_request_duration_seconds_count, the otelchi RED metric every fleet service emits per ADR-0009. Filtered to service_name=~\"{svc_re}\" so the OLTP, analytics projector/reports and MCP processes all show up on one panel.",
            [target(
                f'sum by (service_name, http_route) (rate(http_server_request_duration_seconds_count{{service_name=~"{svc_re}"}}[5m]))',
                legend="{{service_name}} {{http_route}}",
            )],
            unit="reqps",
        )
    )
    panels.append(
        panel(
            8, y, 8, 8,
            "5xx rate by Kong route (API / MCP / reports)",
            "5xx responses per second for each of this context's Kong routes (httproute.warehouse-systems.<context>.N is the REST API, <context>-mcp.N the MCP server, <context>-reports.N the analytics reports), so a reports-only or MCP-only outage is not hidden inside a healthy API average. Read from Kong's prometheus plugin, not from the service: otelchi's http.server.request.duration carries no status-code attribute in this fleet (gap fix D20), so the service's own histogram cannot tell a 5xx from a 200.",
            [target(
                f'sum by (service) (rate(kong_http_requests_total{{service=~"{kong_re}", code=~"5.."}}[5m]))',
                legend="{{service}}",
            )],
            unit="reqps",
        )
    )
    panels.append(
        panel(
            16, y, 8, 8,
            "Request duration p95, by process",
            "http.server.request.duration histogram (seconds), the ONLY sanctioned RED-latency source per ADR-0009 -- no service hand-rolls its own HTTP timer.",
            [target(
                f'histogram_quantile(0.95, sum by (service_name, le) (rate(http_server_request_duration_seconds_bucket{{service_name=~"{svc_re}"}}[5m])))',
                legend="{{service_name}} p95",
            )],
            unit="s",
        )
    )
    y += 8

    # --- Row: business metrics ---------------------------------------------------
    if ctx["business_metrics"]:
        panels.append(row(y, f"{ctx['title']} — business metrics (Tier 2, ADR-0009)"))
        y += 1
    bw = 24 // max(len(ctx["business_metrics"]), 1)
    x = 0
    for metric, attr, desc in ctx["business_metrics"]:
        legend_field = f"{{{{{attr}}}}}" if attr else metric
        by_clause = f"by ({attr})" if attr else ""
        panels.append(
            panel(
                x, y, bw, 8,
                metric,
                desc,
                [target(f"sum {by_clause} (rate({metric}[5m]))", legend=legend_field)],
                unit="short",
            )
        )
        x += bw
    if ctx["business_metrics"]:
        y += 8

    # --- Row: transactional outbox (only where a lag gauge exists) --------------
    if ctx.get("outbox_lag_metric"):
        lag_metric = ctx["outbox_lag_metric"]
        panels.append(row(y, "Transactional outbox"))
        y += 1
        panels.append(
            panel(
                0, y, 24, 8,
                "Outbox lag (age of the oldest unpublished event)",
                f"{lag_metric}: seconds since the oldest outbox_events row with published_at IS NULL was written, 0 when the outbox is drained (sampled at each metric collection). A steadily growing value means the relay is not publishing -- Kafka unreachable, or a head row failing until it reaches OUTBOX_MAX_ATTEMPTS and is parked (see this context's runbook for the re-arm SQL). Alert: WarehouseOutboxLagHigh.",
                [target(
                    f'max by (service_name) ({lag_metric}{{service_name=~"{svc_re}"}})',
                    legend="{{service_name}}",
                )],
                unit="s",
            )
        )
        y += 8

    # --- Row: Go runtime (this context's processes only) ------------------------
    panels.append(row(y, "Go runtime (this context's processes)"))
    y += 1
    panels.append(
        panel(
            0, y, 12, 8,
            "Goroutines",
            f"go.goroutine.count for service_name=~\"{svc_re}\". A steady climb with no matching traffic growth is a goroutine leak.",
            [target(
                f'go_goroutine_count{{service_name=~"{svc_re}"}} or runtime_go_goroutines{{service_name=~"{svc_re}"}}',
                legend="{{service_name}}",
            )],
            unit="short",
        )
    )
    panels.append(
        panel(
            12, y, 12, 8,
            "Go memory used",
            f"go.memory.used for service_name=~\"{svc_re}\".",
            [target(
                f'go_memory_used_bytes{{service_name=~"{svc_re}"}} or runtime_go_mem_heap_alloc_bytes{{service_name=~"{svc_re}"}}',
                legend="{{service_name}} {{go_memory_type}}",
            )],
            unit="bytes",
        )
    )
    y += 8

    # --- Row: Logs (Loki, via Alloy tailing pod stdout) --------------------------
    panels.append(row(y, "Logs (this context's pods, application containers only)"))
    y += 1
    panels.append(
        logs_panel(
            0, y, 16, 9,
            "Live log stream",
            f'Raw JSON log lines from every {ctx["title"]} pod (OLTP + frontend + mcp + projector + reports), excluding the istio-proxy/istio-init sidecar containers. Every fleet service writes structured JSON via log/slog with the active trace_id/span_id already embedded (telemetry.WithTraceContext) -- click a line\'s "trace_id" field to pivot into the matching Jaeger trace via the Loki datasource\'s derived-fields link (observability.tf).',
            [loki_target(f'{loki_selector}', legend="{{pod}} / {{container}}")],
            ptype="logs",
        )
    )
    panels.append(
        logs_panel(
            16, y, 8, 9,
            "Log volume by level",
            "Lines per second, split by the `level` label Alloy lifts out of each JSON body's `level` field (logging.tf's stage.json/stage.labels) -- a real Loki label, not a per-line regex, so this is cheap even at high volume. A WARN/ERROR line here with no corresponding change on the HTTP RED error-rate panel above is worth investigating: it means something is going wrong that never surfaces as a failed request (a background consumer, a retried publish, a degraded fallback).",
            [loki_target(
                f'sum by (level) (count_over_time({loki_selector}[$__interval]))',
                legend="{{level}}",
            )],
            ptype="timeseries",
        )
    )
    panels.append(
        logs_panel(
            16, y + 9, 8, 6,
            "Errors and warnings only",
            'Same stream as "Live log stream", filtered to level=~"ERROR|WARN" so a real problem does not scroll off the bottom of a busy INFO-heavy pod.',
            [loki_target(
                f'{{app="{loki_app}", container!~"istio-proxy|istio-init", level=~"ERROR|WARN"}}',
                legend="{{pod}} / {{container}}",
            )],
            ptype="logs",
        )
    )
    y += 15

    return {
        "annotations": {"list": []},
        "editable": True,
        "graphTooltip": 1,
        "title": f"Warehouse — {ctx['title']}",
        "uid": ctx["uid"],
        "tags": ["warehouse", ctx["key"], "bounded-context"],
        "timezone": "browser",
        "time": {"from": "now-30m", "to": "now"},
        "refresh": "30s",
        "schemaVersion": 39,
        "panels": panels,
    }


def build_gateway_overview():
    panels = []
    y = 0
    panels.append(row(y, "Kong Gateway health"))
    y += 1
    panels.append(
        panel(
            0, y, 8, 8,
            "Datastore reachable",
            "kong_datastore_reachable. This chart runs Kong DB-less (env.database=off, see kong.tf), so this reflects Kong's own config-loading health, not an external Postgres/Cassandra dependency.",
            [target("kong_datastore_reachable", legend="{{pod}}")],
            unit="short",
        )
    )
    panels.append(
        panel(
            8, y, 8, 8,
            "Nginx metric/connection errors",
            "kong_nginx_metric_errors_total -- errors internal to Kong's own metrics collection (not request errors). Should stay at zero.",
            [target("sum(rate(kong_nginx_metric_errors_total[5m]))", legend="errors/sec")],
            unit="short",
        )
    )
    panels.append(
        panel(
            16, y, 8, 8,
            "Upstream target health",
            "kong_upstream_target_health: 1 = healthy, per upstream/target. A target stuck at 0 for a Service backing a bounded context's Deployment means Kong has marked every replica of that pod unreachable.",
            [target('kong_upstream_target_health', legend="{{upstream}} {{target}}")],
            unit="short",
        )
    )
    y += 8

    panels.append(row(y, "Traffic by bounded context"))
    y += 1
    panels.append(
        panel(
            0, y, 12, 9,
            "Request rate by context",
            "Requests/sec Kong is forwarding, summed by the Kong Service name (one per bounded context's route -- see the `kind: service` entries of terraform/apps.yaml / Gateway API HTTPRoute-derived Service naming, httproute.warehouse-systems.<context>.0).",
            [target(
                'sum by (service) (rate(kong_http_requests_total[5m]))',
                legend="{{service}}",
            )],
            unit="reqps",
        )
    )
    panels.append(
        panel(
            12, y, 12, 9,
            "5xx error rate by context",
            "5xx responses per bounded context's Kong Service, so one failing context is visible without averaging across the fleet.",
            [target(
                'sum by (service) (rate(kong_http_requests_total{code=~"5.."}[5m]))',
                legend="{{service}}",
            )],
            unit="reqps",
        )
    )
    y += 9

    panels.append(row(y, "Latency"))
    y += 1
    panels.append(
        panel(
            0, y, 12, 9,
            "Upstream latency p95 by context",
            "Time Kong spent waiting on each context's own pod (excludes Kong's own processing overhead) -- the fairest cross-context latency comparison since it isolates the application, not the gateway.",
            [target(
                'histogram_quantile(0.95, sum by (service, le) (rate(kong_upstream_latency_ms_bucket[5m])))',
                legend="{{service}}",
            )],
            unit="ms",
        )
    )
    panels.append(
        panel(
            12, y, 12, 9,
            "Kong-added overhead p95 by context",
            "kong_kong_latency_ms: time Kong itself spends on the request (routing, plugins -- CORS, this Prometheus exporter) excluding the upstream call. A rise here fleet-wide, uncorrelated with any single context, points at the gateway (e.g. plugin config), not a bounded context.",
            [target(
                'histogram_quantile(0.95, sum by (service, le) (rate(kong_kong_latency_ms_bucket[5m])))',
                legend="{{service}}",
            )],
            unit="ms",
        )
    )
    y += 9

    panels.append(row(y, "Bandwidth"))
    y += 1
    panels.append(
        panel(
            0, y, 24, 8,
            "Bandwidth by context and direction",
            "kong_bandwidth_bytes, ingress (client->Kong) vs. egress (Kong->client), by context. Useful for spotting a context whose responses have ballooned in size (e.g. an unpaginated list endpoint).",
            [target(
                'sum by (service, direction) (rate(kong_bandwidth_bytes[5m]))',
                legend="{{service}} {{direction}}",
            )],
            unit="Bps",
        )
    )

    return {
        "annotations": {"list": []},
        "editable": True,
        "graphTooltip": 1,
        "title": "Warehouse — API Gateway (Kong) overview",
        "uid": "warehouse-kong-gateway-overview",
        "tags": ["warehouse", "kong", "gateway"],
        "timezone": "browser",
        "time": {"from": "now-30m", "to": "now"},
        "refresh": "30s",
        "schemaVersion": 39,
        "panels": panels,
    }


def build_logs_overview():
    """Fleet-wide logs dashboard: cross-context error/warning triage and a
    per-app log-volume breakdown, backed entirely by Loki. Complements
    kong-gateway-overview.json (traffic/latency) and go-runtime.json
    (process metrics) with the third observability pillar -- this is the
    dashboard for "something is wrong, which context and which pod" before
    drilling into that context's own dashboard for the metrics detail."""
    # Every fleet app label except the platform/infra pods this dashboard
    # is not about (Kong, Istio, ArgoCD, Kafka, Postgres, the observability
    # stack's own components, the console/ops-agent, ...). Kept as an
    # explicit exclusion list, not an inclusion allowlist, so a NEW bounded
    # context automatically appears here the moment its chart is deployed --
    # see kong-gateway-overview.json's per-context panels for the mirrored
    # inclusion-list approach where that tradeoff runs the other way.
    non_context_apps = "|".join([
        "alloy", "argocd-.*", "grafana", "istiod", "kafka", "kiali", "kong",
        "loki", "opentelemetry-collector", "postgresql", "prometheus",
        "warehouse-console", "warehouse-ops-agent", "web-gateway",
    ])
    # Loki requires at least one POSITIVE (non-negated) matcher in a stream
    # selector -- a selector built purely from `!~` exclusions (app!~"...",
    # container!~"...") is rejected outright with "queries require at least
    # one regexp or equality matcher that does not have an empty-compatible
    # value" (verified against the live Loki instance, not assumed from
    # docs). `app=~".+"` supplies that required positive matcher without
    # narrowing the match at all.
    app_selector = f'{{app=~".+", app!~"{non_context_apps}", container!~"istio-proxy|istio-init"}}'

    panels = []
    y = 0
    panels.append(row(y, "Fleet-wide error triage"))
    y += 1
    panels.append(
        logs_panel(
            0, y, 24, 10,
            "Errors and warnings across every bounded context",
            'level=~"ERROR|WARN" across all 8 bounded-context apps in one stream, newest first -- the fastest way to answer "is anything actively failing right now" without opening 8 separate dashboards. Use the `app` label (shown per line) to identify which context, then switch to that context\'s own dashboard for the metrics/traffic detail.',
            [loki_target(
                f'{{app=~".+", app!~"{non_context_apps}", container!~"istio-proxy|istio-init", level=~"ERROR|WARN"}}',
                legend="{{app}} / {{pod}}",
            )],
            ptype="logs",
        )
    )
    y += 10

    panels.append(row(y, "Log volume"))
    y += 1
    panels.append(
        logs_panel(
            0, y, 12, 9,
            "Total log lines per second, by context",
            "count_over_time summed by app -- a context whose line rate suddenly drops to zero stopped logging (a crash loop or a stuck process), and one that spikes is either under real load or looping on a repeated error.",
            [loki_target(
                f'sum by (app) (count_over_time({app_selector}[$__interval]))',
                legend="{{app}}",
            )],
            ptype="timeseries",
        )
    )
    panels.append(
        logs_panel(
            12, y, 12, 9,
            "Error+warning lines per second, by context",
            "Same breakdown restricted to level=~\"ERROR|WARN\" -- the per-context error RATE, as a log-volume proxy independent of whether that error ever surfaced as an HTTP 5xx (a Kafka consumer failure or a degraded fallback path logs a WARN without ever touching the HTTP RED metrics on the per-context dashboards).",
            [loki_target(
                f'sum by (app) (count_over_time({{app=~".+", app!~"{non_context_apps}", container!~"istio-proxy|istio-init", level=~"ERROR|WARN"}}[$__interval]))',
                legend="{{app}}",
            )],
            ptype="timeseries",
        )
    )

    return {
        "annotations": {"list": []},
        "editable": True,
        "graphTooltip": 1,
        "title": "Warehouse — Logs overview",
        "uid": "warehouse-logs-overview",
        "tags": ["warehouse", "logs", "loki"],
        "timezone": "browser",
        "time": {"from": "now-30m", "to": "now"},
        "refresh": "30s",
        "schemaVersion": 39,
        "panels": panels,
    }


# ---------------------------------------------------------------------------
# Alert rules (gap fix D30), generated from the same CONTEXTS table so every
# context's alerts, dashboard and Kong/outbox metric names can never disagree.
# Written as JSON (valid YAML) to terraform/alerting/warehouse-alert-rules.json
# and loaded by observability.tf into the prometheus-community/prometheus
# chart's serverFiles."alerting_rules.yml" (this cluster runs the plain chart,
# no Prometheus Operator, so a PrometheusRule CRD would be watched by nothing).
#
# Per context, only where the signal exists:
#   - WarehouseKong5xxRatioHigh: Kong's 5xx share per route (API/MCP/reports),
#     the only 5xx source (otelchi records no status code).
#   - WarehouseOutboxLagHigh: the context's outbox-lag gauge > 60 s for 5 m,
#     the threshold its own observability page suggests. Only contexts that
#     export a gauge; no context exports an outbox dead-row (attempt-cap)
#     metric -- that signal is a log line / SQL query only, so no rule.
#   - WarehousePodRestarting: kube-state-metrics'
#     kube_pod_container_status_restarts_total (enabled in observability.tf
#     by the same change).
# No consumer-lag rule: no Kafka exporter runs in this cluster, so no
# consumer-group lag metric exists to alert on.
# Every rule carries annotations.runbook_url: the context's own runbook page.
#
# SLO burn-rate alerts (gaps SLO-1/SLO-2), in a sibling group
# `warehouse-<key>-slo` per context, one pair (fast = critical, slow =
# warning) per SLO and per Kong route:
#   SLO 1, API availability: 99% of Kong requests do not answer 5xx, per day.
#   SLO 2, API latency: 95% of Kong requests have kong_upstream_latency_ms
#          <= 500 ms, per day.
# Prometheus keeps 24 h (retention in observability.tf), so every SLO window
# is ONE DAY, not 28 days. burn = observed bad ratio / (1 - target); the time
# to exhaust the one-day budget is 24 h / burn. Both windows of a pair must
# hold (the long one proves it is real, the short one proves it is still
# happening), and the route needs >= SLO_MIN_REQUESTS requests in the long
# window so one failed request on an idle local route cannot fire a page.
# ---------------------------------------------------------------------------
APPS_NAMESPACE = "warehouse-systems"
GRAFANA_URL = "http://localhost:3000"
KONG_5XX_RATIO_THRESHOLD = 0.05
OUTBOX_LAG_THRESHOLD_SECONDS = 60
POD_RESTARTS_THRESHOLD = 2

AVAILABILITY_SLO_TARGET = 0.99
LATENCY_SLO_TARGET = 0.95
LATENCY_SLO_THRESHOLD_MS = 500
# Kong's histogram has NO le="500" bucket. The real boundaries (Kong 3.9 in
# this cluster, verified on its Prometheus) are 25, 50, 80, 100, 250, 400,
# 700, 1000, 2000, 5000, 10000, 30000, 60000 and +Inf, spelled "400.0".
# 400 is the nearest to 500 ms; a request between 400 and 500 ms counts as
# slow (the alert is slightly stricter than the 500 ms SLO, never laxer).
LATENCY_SLO_BUCKET_LE = "400.0"
BURN_FAST = 14.4  # the whole one-day budget is gone in 24 h / 14.4 = 100 minutes
BURN_SLOW = 3  # ... in 24 h / 3 = 8 hours
SLO_FAST_WINDOWS = ("1h", "5m")  # (long, short)
SLO_SLOW_WINDOWS = ("6h", "30m")
SLO_FAST_FOR = "2m"
SLO_SLOW_FOR = "15m"
SLO_MIN_REQUESTS = 30  # traffic floor over the long window


def runbook_url(ctx):
    return ctx.get("runbook_url", f"https://iqvo.github.io/{ctx['key']}/docs/operations/runbook")


def pod_regex(key):
    """Every pod of one context: the chart's Deployments are all named
    `<release>` or `<release>-<component>` and the release is the context key
    (no context key is a `<other key>-` prefix of another; the test pins it)."""
    return f"{key}-.+"


SLO_WINDOW_WORDS = {
    "1h": "the last hour",
    "5m": "the last 5 minutes",
    "6h": "the last 6 hours",
    "30m": "the last 30 minutes",
}


def _num(x):
    """Short, float-noise-free number for PromQL and annotation text."""
    return f"{round(x, 6):g}"


def exhaustion_words(burn):
    """Time to exhaust the one-day error budget at `burn`: 24 h / burn."""
    minutes = 24 * 60 / burn
    if minutes < 180:
        return f"{_num(minutes)} minutes"
    return f"{_num(minutes / 60)} hours"


def availability_burn_expr(kong_re, burn, windows):
    """5xx burn over both windows AND the traffic floor, per Kong route.
    $value of the alert is the long-window burn (`and` keeps the left side)."""
    budget = round(1 - AVAILABILITY_SLO_TARGET, 6)
    long_w, short_w = windows

    def burn_over(w):
        return (
            f'(sum by (service) (rate(kong_http_requests_total{{service=~"{kong_re}", code=~"5.."}}[{w}])) '
            f'/ sum by (service) (rate(kong_http_requests_total{{service=~"{kong_re}"}}[{w}])) '
            f"/ {_num(budget)} >= {_num(burn)})"
        )

    floor = f'sum by (service) (increase(kong_http_requests_total{{service=~"{kong_re}"}}[{long_w}])) >= {SLO_MIN_REQUESTS}'
    return f"{burn_over(long_w)} and {burn_over(short_w)} and {floor}"


def latency_burn_expr(kong_re, burn, windows):
    """Slow-request burn (1 - share within the le bucket) over both windows
    AND the traffic floor, per Kong route."""
    budget = round(1 - LATENCY_SLO_TARGET, 6)
    long_w, short_w = windows

    def burn_over(w):
        return (
            f'((1 - sum by (service) (rate(kong_upstream_latency_ms_bucket{{service=~"{kong_re}", le="{LATENCY_SLO_BUCKET_LE}"}}[{w}])) '
            f'/ sum by (service) (rate(kong_upstream_latency_ms_count{{service=~"{kong_re}"}}[{w}]))) '
            f"/ {_num(budget)} >= {_num(burn)})"
        )

    floor = f'sum by (service) (increase(kong_upstream_latency_ms_count{{service=~"{kong_re}"}}[{long_w}])) >= {SLO_MIN_REQUESTS}'
    return f"{burn_over(long_w)} and {burn_over(short_w)} and {floor}"


def build_slo_rules(ctx):
    """The four burn-rate alerts of one context (see the section header)."""
    key, title = ctx["key"], ctx["title"]
    kong_re = kong_service_regex(key)
    common = {
        "runbook_url": runbook_url(ctx),
        "dashboard_url": f"{GRAFANA_URL}/d/{ctx['uid']}",
    }
    availability_pct = _num(AVAILABILITY_SLO_TARGET * 100)
    latency_pct = _num(LATENCY_SLO_TARGET * 100)
    rules = []
    for speed, severity, burn, windows, for_ in (
        ("Fast", "critical", BURN_FAST, SLO_FAST_WINDOWS, SLO_FAST_FOR),
        ("Slow", "warning", BURN_SLOW, SLO_SLOW_WINDOWS, SLO_SLOW_FOR),
    ):
        long_w, short_w = windows
        pace = "fast" if speed == "Fast" else "slowly"
        exhaustion = exhaustion_words(burn)
        windows_text = f"over {SLO_WINDOW_WORDS[long_w]} and over {SLO_WINDOW_WORDS[short_w]}"
        budget_text = f"At this burn the whole day's error budget is gone in about {exhaustion}."
        labels = {"context": key, "severity": severity}

        bad_pct = _num(burn * round(1 - AVAILABILITY_SLO_TARGET, 6) * 100)
        rules.append({
            "alert": f"WarehouseApiAvailabilityBurn{speed}",
            "expr": availability_burn_expr(kong_re, burn, windows),
            "for": for_,
            "labels": labels,
            "annotations": {
                "summary": f"{title}: API availability SLO burning {pace} (day's budget gone in ~{exhaustion})",
                "description": (
                    "Kong route {{ $labels.service }} answers 5xx at {{ $value | humanize }}x the rate "
                    f"the one-day {availability_pct}% availability SLO allows, {windows_text} "
                    f"(5xx ratio of {bad_pct}% or more). {budget_text} "
                    f"The alert needs at least {SLO_MIN_REQUESTS} requests in {SLO_WINDOW_WORDS[long_w]}, "
                    "so one failed request on an idle local route cannot fire it."
                ),
                **common,
            },
        })

        slow_pct = _num(burn * round(1 - LATENCY_SLO_TARGET, 6) * 100)
        rules.append({
            "alert": f"WarehouseApiLatencyBurn{speed}",
            "expr": latency_burn_expr(kong_re, burn, windows),
            "for": for_,
            "labels": labels,
            "annotations": {
                "summary": f"{title}: API latency SLO burning {pace} (day's budget gone in ~{exhaustion})",
                "description": (
                    f"Kong route {{{{ $labels.service }}}} is missing the {LATENCY_SLO_THRESHOLD_MS} ms upstream latency target at "
                    "{{ $value | humanize }}x the rate "
                    f"the one-day {latency_pct}% latency SLO allows, {windows_text} "
                    f"(slow ratio of {slow_pct}% or more). {budget_text} "
                    f"Kong's histogram has no {LATENCY_SLO_THRESHOLD_MS} ms bucket, so the nearest boundary, "
                    f"le={LATENCY_SLO_BUCKET_LE} ({_num(float(LATENCY_SLO_BUCKET_LE))} ms), is used: "
                    f"a request between {_num(float(LATENCY_SLO_BUCKET_LE))} and {LATENCY_SLO_THRESHOLD_MS} ms counts as slow. "
                    f"The alert needs at least {SLO_MIN_REQUESTS} requests in {SLO_WINDOW_WORDS[long_w]}, "
                    "so one slow request on an idle local route cannot fire it."
                ),
                **common,
            },
        })
    return rules


def build_alert_rules():
    groups = []
    for ctx in CONTEXTS:
        key = ctx["key"]
        labels = {"context": key, "severity": "warning"}
        common = {
            "runbook_url": runbook_url(ctx),
            "dashboard_url": f"{GRAFANA_URL}/d/{ctx['uid']}",
        }
        kong_re = kong_service_regex(key)
        rules = [{
            "alert": "WarehouseKong5xxRatioHigh",
            "expr": (
                f'sum by (service) (rate(kong_http_requests_total{{service=~"{kong_re}", code=~"5.."}}[5m])) '
                f'/ sum by (service) (rate(kong_http_requests_total{{service=~"{kong_re}"}}[5m])) '
                f"> {KONG_5XX_RATIO_THRESHOLD}"
            ),
            "for": "5m",
            "labels": labels,
            "annotations": {
                "summary": f"{ctx['title']}: more than {int(KONG_5XX_RATIO_THRESHOLD * 100)}% of requests on a Kong route answer 5xx",
                "description": "Kong route {{ $labels.service }} answered 5xx for {{ $value | humanizePercentage }} of its requests over the last 5 minutes (API route = <context>.N, MCP = <context>-mcp.N, reports = <context>-reports.N).",
                **common,
            },
        }]
        if ctx.get("outbox_lag_metric"):
            rules.append({
                "alert": "WarehouseOutboxLagHigh",
                "expr": f'max by (service_name) ({ctx["outbox_lag_metric"]}{{service_name=~"{ctx["service_regex"]}"}}) > {OUTBOX_LAG_THRESHOLD_SECONDS}',
                "for": "5m",
                "labels": labels,
                "annotations": {
                    "summary": f"{ctx['title']}: the transactional outbox is not draining",
                    "description": "The oldest unpublished outbox_events row of {{ $labels.service_name }} is {{ $value | humanizeDuration }} old. Kafka is unreachable or a head row keeps failing until OUTBOX_MAX_ATTEMPTS parks it; downstream contexts stop seeing this context's events. The runbook has the re-arm SQL.",
                    **common,
                },
            })
        rules.append({
            "alert": "WarehousePodRestarting",
            "expr": (
                f'sum by (pod, container) (increase(kube_pod_container_status_restarts_total{{namespace="{APPS_NAMESPACE}", pod=~"{pod_regex(key)}"}}[15m])) '
                f">= {POD_RESTARTS_THRESHOLD}"
            ),
            "for": "0m",
            "labels": labels,
            "annotations": {
                "summary": f"{ctx['title']}: a container is restarting",
                "description": "{{ $labels.pod }}/{{ $labels.container }} restarted {{ $value | humanize }} times in 15 minutes (boot-retry exhaustion, a failed migration, a stopped consumer that exits on purpose, or an OOM kill). Read the previous container's last log lines first.",
                **common,
            },
        })
        groups.append({"name": f"warehouse-{key}", "rules": rules})
        groups.append({"name": f"warehouse-{key}-slo", "rules": build_slo_rules(ctx)})
    return {"groups": groups}


def write_json(path, obj):
    with open(path, "w") as f:
        json.dump(obj, f, indent=2, sort_keys=False)
        f.write("\n")
    print(f"wrote {path}")


def main(repo_root=REPO_ROOT):
    """Write every generated file under `repo_root` (the repo itself by
    default; scripts/test_gen_context_dashboards.py passes a temp dir and
    diffs the result against the committed files)."""
    out_dir = os.path.join(repo_root, "terraform", "dashboards", "contexts")
    os.makedirs(out_dir, exist_ok=True)
    for ctx in CONTEXTS:
        write_json(os.path.join(out_dir, f"{ctx['key']}.json"), build_dashboard(ctx))

    gateway_dir = os.path.join(repo_root, "terraform", "dashboards")
    write_json(os.path.join(gateway_dir, "kong-gateway-overview.json"), build_gateway_overview())
    write_json(os.path.join(gateway_dir, "logs-overview.json"), build_logs_overview())

    alerting_dir = os.path.join(repo_root, "terraform", "alerting")
    os.makedirs(alerting_dir, exist_ok=True)
    write_json(os.path.join(alerting_dir, "warehouse-alert-rules.json"), build_alert_rules())


if __name__ == "__main__":
    main()
