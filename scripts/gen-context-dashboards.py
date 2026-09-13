#!/usr/bin/env python3
"""Generate the per-bounded-context Grafana dashboards, plus the fleet-wide
Kong API Gateway dashboard, as committed JSON under terraform/dashboards/.

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
OUT_DIR = os.path.join(REPO_ROOT, "terraform", "dashboards", "contexts")

PROM_DS = {"type": "prometheus", "uid": "prometheus"}


def target(expr, ref_id="A", legend=None):
    t = {"refId": ref_id, "datasource": PROM_DS, "expr": expr}
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
# was built from. `kong_service_regex` matches the Kong Gateway API service
# object name Terraform generates for that context's route
# (httproute.warehouse-systems.<context>.0), see locals.tf `services` map.
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
        "kong_service_regex": "httproute\\.warehouse-systems\\.order-management\\..*",
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
        "kong_service_regex": "httproute\\.warehouse-systems\\.inventory-storage\\..*",
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
        "kong_service_regex": "httproute\\.warehouse-systems\\.wes-work-planning\\..*",
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
        "kong_service_regex": "httproute\\.warehouse-systems\\.fulfillment-execution\\..*",
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
        "kong_service_regex": "httproute\\.warehouse-systems\\.workforce-management\\..*",
        "business_metrics": [
            (
                "workforce_labor_assignments_total",
                "workforce_assignment_outcome",
                "Labor assignment attempts, by outcome (accepted/rejected) and, on rejection, workforce_assignment_reason (uncertified, on_break, shift_ended, max_hours_exceeded, associate_not_found).",
            ),
        ],
    },
    {
        "key": "facility-layout",
        "title": "Facility Layout",
        "uid": "warehouse-facility-layout",
        "service_regex": "facility-layout.*",
        "kong_service_regex": "httproute\\.warehouse-systems\\.facility-layout\\..*",
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
        "kong_service_regex": "httproute\\.warehouse-systems\\.labor-performance\\..*",
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
        "kong_service_regex": "httproute\\.warehouse-systems\\.process-path-management\\..*",
        "business_metrics": [
            (
                "process_path_management_paths_defined_total",
                "outcome",
                "Attempts to define a new process path, by outcome (accepted or rejected).",
            ),
        ],
    },
]


def build_dashboard(ctx):
    svc_re = ctx["service_regex"]
    kong_re = ctx["kong_service_regex"]
    panels = []
    y = 0

    # --- Row: API Gateway (Kong) -------------------------------------------------
    panels.append(row(y, "API Gateway (Kong) — north-south view of this context's route"))
    y += 1
    panels.append(
        panel(
            0, y, 8, 8,
            "Request rate (Kong)",
            "Requests/sec Kong forwarded to this context's Service, by HTTP status code. Kong sees a request even when the upstream pod never got instrumented (e.g. crashed before otelchi ran).",
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
                f'sum(rate(kong_http_requests_total{{service=~"{kong_re}", code=~"5.."}}[5m])) '
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
            "Error rate (HTTP 5xx, by process)",
            "5xx responses this context's own processes returned, split by which process (OLTP vs. reports vs. MCP) so a reports-only outage doesn't get hidden inside a healthy OLTP average. Two label variants are unioned: newer otelchi/semconv releases in this fleet use http_response_status_code, older ones (riandyrn/otelchi metric package pre-dating the semconv bump) use http_status_code.",
            [target(
                f'sum by (service_name) (rate(http_server_request_duration_seconds_count{{service_name=~"{svc_re}", http_response_status_code=~"5.."}}[5m])) '
                f'or sum by (service_name) (rate(http_server_request_duration_seconds_count{{service_name=~"{svc_re}", http_status_code=~"5.."}}[5m]))',
                legend="{{service_name}}",
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
            "Requests/sec Kong is forwarding, summed by the Kong Service name (one per bounded context's route -- see locals.tf's `services` map / Gateway API HTTPRoute-derived Service naming, httproute.warehouse-systems.<context>.0).",
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


def main():
    os.makedirs(OUT_DIR, exist_ok=True)
    for ctx in CONTEXTS:
        dashboard = build_dashboard(ctx)
        out_path = os.path.join(OUT_DIR, f"{ctx['key']}.json")
        with open(out_path, "w") as f:
            json.dump(dashboard, f, indent=2, sort_keys=False)
            f.write("\n")
        print(f"wrote {out_path}")

    gateway_dir = os.path.join(REPO_ROOT, "terraform", "dashboards")
    gateway_path = os.path.join(gateway_dir, "kong-gateway-overview.json")
    with open(gateway_path, "w") as f:
        json.dump(build_gateway_overview(), f, indent=2, sort_keys=False)
        f.write("\n")
    print(f"wrote {gateway_path}")


if __name__ == "__main__":
    main()
