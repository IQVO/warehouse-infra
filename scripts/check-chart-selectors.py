#!/usr/bin/env python3
"""Chart selector conformance check.

Renders every service-owning Helm chart in the fleet with ALL optional
components enabled (analytics/frontend/mcp/a2a), then asserts every rendered
Service selects EXACTLY ONE Deployment.

Why this exists: every chart's `<ctx>.selectorLabels` helper originally
emitted only `app.kubernetes.io/name` + `app.kubernetes.io/instance`,
which are IDENTICAL across a service's OLTP/MCP/projector/reports/frontend
pods. The OLTP Service therefore selected ALL of them -- verified live via
`kubectl get endpointslices`, and a real `curl .../healthz` through Kong
was answered by the wrong (reports) pod. Every chart has since had
`app.kubernetes.io/component: <api|mcp|analytics-reports|frontend|...>`
added to each Deployment's selector.matchLabels + pod template labels +
its own Service's selector, but nothing enforced that convention going
forward -- a new component template that forgets the component label
reintroduces the exact same silent-multi-select bug, and it would NOT be
caught by `helm lint` (lint has no opinion on selector cardinality) or by
`helm template` alone (nothing fails, it just renders a Service that
happens to select more than intended).

Run from anywhere; paths below are relative to `terraform/` (this script
lives in `scripts/`, but is invoked via `cd terraform && python3
../scripts/check-chart-selectors.py` from the Makefile / CI job so the
chart paths match the sibling layout `../../<repo>/charts/<repo>`).

Second assertion (capacity step 3, the agents.colocate ADR): every Service
port with a NAMED targetPort resolves to exactly one containerPort of the
selected Deployment's pod. A pod that runs two containers (mcp + a2a in one
`<ctx>-agents` pod) must not name both ports `http`, or the Service would
silently route to the first container.

Charts that ship both an mcp and an a2a component are rendered twice: as
listed, and again with `agents.colocate=true` (the optional single agents
pod). A chart that has not adopted that value ignores it and renders the
same objects, so the second render is safe before the charts migrate.

Exit 0 if every Service selects exactly one Deployment and every named
targetPort resolves; exit 1 (with the offending Service(s) named) otherwise.
"""
import subprocess
import sys

import yaml

RELEASE_NAME = "chart-conformance-check"

# Every service-owning chart in the fleet, keyed by its path relative to
# terraform/, with the --set flags needed to render every optional
# component that adds its own Deployment+Service pair. Keep this list in
# sync with the application registry in terraform/20-apps/main.tf
# (same discipline the Makefile's CHARTS variable already follows) -- it is
# not auto-discovered.
CHARTS: dict[str, dict[str, str]] = {
    # order-management: cmd/a2a (ADR-0046) refuses to render without a
    # database and the analytics data product's DSN. Dummies, no password.
    "../../order-management/charts/order-management": {
        "a2a.enabled": "true",
        "analytics.enabled": "true", "frontend.enabled": "true", "mcp.enabled": "true",
        "database.url": "postgres://u@example.invalid:5432/orders",
        "analytics.database.projectorUrl": "postgres://p@example.invalid:5432/analytics",
    },
    # inventory-storage and wes-work-planning: every binary runs on real
    # Postgres and real Kafka only, so the chart refuses to render without a
    # database source, kafka brokers and (analytics on) the analytical DSN.
    # Dummies, no password.
    "../../inventory-storage/charts/inventory-storage": {
        "a2a.enabled": "true",
        "analytics.enabled": "true", "frontend.enabled": "true", "mcp.enabled": "true",
        "database.url": "postgres://u@example.invalid:5432/db",
        "kafka.brokers": "kafka.example.invalid:9092",
        "analytics.database.projectorUrl": "postgres://p@example.invalid:5432/a",
    },
    "../../wes-work-planning/charts/wes-work-planning": {
        "a2a.enabled": "true",
        "analytics.enabled": "true", "frontend.enabled": "true", "mcp.enabled": "true",
        "database.url": "postgres://u@example.invalid:5432/db",
        "kafka.brokers": "kafka.example.invalid:9092",
    },
    # fulfillment-execution: every cmd binary (api, mcp, projector) now runs
    # on real Postgres and real Kafka only (ADR-0052: Postgres and Kafka are
    # the only runtime of every cmd binary); give it dummies (no password).
    "../../fulfillment-execution/charts/fulfillment-execution": {
        "a2a.enabled": "true",
        "analytics.enabled": "true", "frontend.enabled": "true", "mcp.enabled": "true",
        "database.url": "postgres://u@example.invalid:5432/db",
        "kafka.brokers": "kafka.example.invalid:9092",
    },
    "../../workforce-management/charts/workforce-management": {
        "a2a.enabled": "true",
        "analytics.enabled": "true", "frontend.enabled": "true", "mcp.enabled": "true",
        # This chart's templates fail to render at all without a database
        # URL or existingSecret -- see fleet skill note "workforce-management's
        # chart refuses to render without a database URL". ADR-0038: Postgres
        # and Kafka are the only runtime, and analytics needs its own DSN.
        "database.url": "postgres://u:***@example.invalid:5432/db",
        "kafka.brokers": "kafka.example.invalid:9092",
        "analytics.database.projectorUrl": "postgres://p@example.invalid:5432/a",
    },
    # facility-layout: ADR 0039 (Postgres and Kafka are the only runtime);
    # analytics needs its own DSN and a stable consumer group too.
    "../../facility-layout/charts/facility-layout": {
        "a2a.enabled": "true",
        "analytics.enabled": "true", "frontend.enabled": "true", "mcp.enabled": "true",
        "database.url": "postgres://u@example.invalid:5432/db",
        "kafka.brokers": "kafka.example.invalid:9092",
        "analytics.database.projectorUrl": "postgres://p@example.invalid:5432/a",
        "analytics.projector.consumerGroup": "facility-layout-analytics",
    },
    # labor-performance: ADR 0034 (Postgres and Kafka are the only runtime);
    # the always-on fulfillment-events consumer needs a stable group id too.
    "../../labor-performance/charts/labor-performance": {
        "a2a.enabled": "true",
        "analytics.enabled": "true", "frontend.enabled": "true", "mcp.enabled": "true",
        "database.url": "postgres://u@example.invalid:5432/db",
        "kafka.brokers": "kafka.example.invalid:9092",
        "config.kafkaConsumerGroup": "labor-performance",
    },
    # process-path-management: ADR 0037 (Postgres and Kafka are the only
    # runtime); give it dummies (no password).
    "../../process-path-management/charts/process-path-management": {
        "a2a.enabled": "true",
        "analytics.enabled": "true", "frontend.enabled": "true", "mcp.enabled": "true",
        "database.url": "postgres://u@example.invalid:5432/db",
        "kafka.brokers": "kafka.example.invalid:9092",
    },
    # warehouse-planning: OLTP api + the optional mcp, frontend (capacity_mfe)
    # and analytics (projector/reports) components. The chart refuses to render
    # without a database source and refuses analytics without a DSN source and
    # kafka (ADR 0016), plus three always-on consumers and the order-management
    # demand projection each need a stable group id / site id, so give it
    # dummies (no password).
    "../../warehouse-planning/charts/warehouse-planning": {
        "a2a.enabled": "true",
        "analytics.enabled": "true", "frontend.enabled": "true", "mcp.enabled": "true",
        "kafka.enabled": "true", "kafka.brokers": "kafka.example.invalid:9092",
        "analytics.database.projectorUrl": "postgres://p@example.invalid:5432/a",
        "database.url": "postgres://u@example.invalid:5432/db",
        "analytics.projector.consumerGroup": "warehouse-planning-analytics",
        "config.laborCapacityConsumerGroup": "warehouse-planning-labor-capacity",
        "config.storageCapacityConsumerGroup": "warehouse-planning-storage-capacity",
        "demand.consumerGroup": "warehouse-planning-demand",
        "dockAppointments.consumerGroup": "warehouse-planning-dock-appointments",
        "observed.consumerGroup": "warehouse-planning-observed-capacity",
        "demand.siteId": "SITE1",
    },
    # product-master: OLTP api + the optional mcp, frontend (productmaster_mfe)
    # and analytics (product-projector/product-reports) components. Same render
    # guards as warehouse-planning (database source; analytics needs a DSN
    # source, kafka and a stable consumer group id; ADR 0010), so give it the
    # same dummies (no password).
    "../../product-master/charts/product-master": {
        "a2a.enabled": "true",
        "analytics.enabled": "true", "frontend.enabled": "true", "mcp.enabled": "true",
        "kafka.enabled": "true", "kafka.brokers": "kafka.example.invalid:9092",
        "analytics.database.projectorUrl": "postgres://p@example.invalid:5432/a",
        "database.url": "postgres://u@example.invalid:5432/db",
        "analytics.projector.consumerGroup": "product-master-analytics",
    },
    # inbound-receiving: OLTP api + the optional mcp, frontend (inbound_mfe)
    # and analytics (inbound-projector/inbound-reports) components. Same render
    # guards as product-master (database source; analytics needs a DSN source
    # and kafka; ADR 0011), plus two always-on consumers each need a stable
    # group id, so give it the same dummies (no password).
    "../../inbound-receiving/charts/inbound-receiving": {
        "a2a.enabled": "true",
        "analytics.enabled": "true", "frontend.enabled": "true", "mcp.enabled": "true",
        "kafka.enabled": "true", "kafka.brokers": "kafka.example.invalid:9092",
        "analytics.database.projectorUrl": "postgres://p@example.invalid:5432/a",
        "database.url": "postgres://u@example.invalid:5432/db",
        "config.productConsumerGroup": "inbound-receiving-product",
        "config.dockDoorConsumerGroup": "inbound-receiving-dock-door",
        # ADR 0012 (chart d17b4f1): the packaging view consumer is
        # mandatory too now -- same dummy treatment as the two above.
        "config.packagingConsumerGroup": "inbound-receiving-packaging",
        "config.dockAppointmentConsumerGroup": "inbound-receiving-dock-appointments",
        # ADR 0021 (dock-to-stock KPI): two more mandatory consumers, same dummy treatment.
        "config.visitArrivalConsumerGroup": "inbound-receiving-visit-arrivals",
        "config.cartonStowConsumerGroup": "inbound-receiving-carton-stows",
    },
    # slotting-optimization: OLTP api + the optional mcp, analytics
    # (projector/reports) and frontend (slotting_mfe) components, all of which
    # warehouse-infra deploys. The chart refuses to render without a database
    # source and kafka brokers (ADR 0011), four always-on consumers each
    # need a stable group id, and analytics needs a DSN source, so give it
    # dummies (no password).
    "../../slotting-optimization/charts/slotting-optimization": {
        "a2a.enabled": "true",
        "mcp.enabled": "true", "frontend.enabled": "true", "analytics.enabled": "true",
        "analytics.url": "postgres://u@example.invalid:5432/analytics",
        "database.url": "postgres://u@example.invalid:5432/db",
        "kafka.brokers": "kafka.example.invalid:9092",
        "config.demandConsumerGroup": "slotting-demand",
        "config.productConsumerGroup": "slotting-product",
        "config.layoutConsumerGroup": "slotting-layout",
        "config.relocationConsumerGroup": "slotting-relocation",
        "config.packLevelConsumerGroup": "slotting-pack-level",
    },
    # pick-face-replenishment and task-interleaving: OLTP api + the optional
    # mcp, analytics (projector/reports) and frontend components, all of which
    # warehouse-infra deploys. Both charts refuse to render without a database
    # source and without Kafka brokers (ADR 0006: Postgres and Kafka are the
    # only runtime), and analytics without a DSN source, so give them dummies
    # (no password).
    "../../pick-face-replenishment/charts/pick-face-replenishment": {
        "a2a.enabled": "true",
        "mcp.enabled": "true", "frontend.enabled": "true", "analytics.enabled": "true",
        "analytics.url": "postgres://u@example.invalid:5432/analytics",
        "database.url": "postgres://u@example.invalid:5432/db",
        "kafka.brokers": "kafka.example.invalid:9092",
    },
    "../../task-interleaving/charts/task-interleaving": {
        "a2a.enabled": "true",
        "mcp.enabled": "true", "frontend.enabled": "true", "analytics.enabled": "true",
        "analytics.url": "postgres://u@example.invalid:5432/analytics",
        "database.url": "postgres://u@example.invalid:5432/db",
        "kafka.brokers": "kafka.example.invalid:9092",
    },
    # returns-processing and exception-management: same shape as
    # pick-face-replenishment/task-interleaving (OLTP api + the optional mcp,
    # analytics projector/reports and frontend components, all of which
    # warehouse-infra deploys). Both charts refuse to render without a
    # database source and without Kafka brokers (real Postgres and real
    # Kafka are the only runtime), and analytics without a DSN source, so
    # give them dummies (no password). Their consumer groups have non-empty
    # chart defaults, so none needs a --set.
    "../../returns-processing/charts/returns-processing": {
        "a2a.enabled": "true",
        "mcp.enabled": "true", "frontend.enabled": "true", "analytics.enabled": "true",
        "analytics.url": "postgres://u@example.invalid:5432/analytics",
        "database.url": "postgres://u@example.invalid:5432/db",
        "kafka.brokers": "kafka.example.invalid:9092",
    },
    "../../exception-management/charts/exception-management": {
        "a2a.enabled": "true",
        "mcp.enabled": "true", "frontend.enabled": "true", "analytics.enabled": "true",
        "analytics.url": "postgres://u@example.invalid:5432/analytics",
        "database.url": "postgres://u@example.invalid:5432/db",
        "kafka.brokers": "kafka.example.invalid:9092",
    },
    # network-inventory-planning: OLTP api + the optional mcp, frontend
    # (nip_mfe) and analytics (projector/reports) components. The chart needs a
    # database source and refuses analytics without a DSN source and kafka, so
    # give it dummies (no password); routing templates are opt-in.
    "../../network-inventory-planning/charts/network-inventory-planning": {
        "a2a.enabled": "true",
        "mcp.enabled": "true", "frontend.enabled": "true", "analytics.enabled": "true",
        "analytics.database.projectorUrl": "postgres://p@example.invalid:5432/a",
        "kafka.enabled": "true",
        "kafka.packLevelConsumerGroup": "nip-pack-level",
        "database.url": "postgres://u@example.invalid:5432/db",
    },
    # The ten retail-network contexts (registered 2026-10-24): each chart's
    # api Deployment plus the optional mcp and frontend components its repo
    # has since merged (same set its ci/all-components-values.yaml renders).
    # Every chart refuses to render without a database source and the Kafka
    # brokers, and each consumer group / sibling-URL / (shipping-and-tracking)
    # crypto key it mandates gets the same dummy its own
    # charts/<ctx>/ci/default-values.yaml uses.
    "../../checkout/charts/checkout": {
        "a2a.enabled": "true",
        "mcp.enabled": "true",
        "database.url": "postgres://u@example.invalid:5432/db",
        "kafka.brokers": "kafka.example.invalid:9092",
        "config.shoppingCartUrl": "http://shopping-cart.example.invalid",
        "config.deliveryPromiseUrl": "http://delivery-promise.example.invalid",
        "config.pricingUrl": "http://pricing.example.invalid",
        "config.customerPaymentsUrl": "http://customer-payments.example.invalid",
        "config.customerOrderingUrl": "http://customer-ordering.example.invalid",
    },
    "../../customer-payments/charts/customer-payments": {
        "a2a.enabled": "true",
        "mcp.enabled": "true",
        "database.url": "postgres://u@example.invalid:5432/db",
        "kafka.brokers": "kafka.example.invalid:9092",
        "config.paymentProviderUrl": "http://payment-provider.example.invalid",
        "config.checkoutConsumerGroup": "customer-payments-checkout",
        "config.orderSourcingConsumerGroup": "customer-payments-order-sourcing",
        "config.shippingAndTrackingConsumerGroup": "customer-payments-shipping-and-tracking",
    },
    "../../pricing/charts/pricing": {
        "mcp.enabled": "true", "a2a.enabled": "true",
        "database.url": "postgres://u@example.invalid:5432/db",
        "kafka.brokers": "kafka.example.invalid:9092",
        "config.offerAvailabilityConsumerGroup": "pricing-offer-availability",
    },
    "../../product-content/charts/product-content": {
        "mcp.enabled": "true", "a2a.enabled": "true",
        "database.url": "postgres://u@example.invalid:5432/db",
        "kafka.brokers": "kafka.example.invalid:9092",
        "config.offerAvailabilityConsumerGroup": "product-content-offer-availability",
    },
    "../../product-discovery/charts/product-discovery": {
        "mcp.enabled": "true", "a2a.enabled": "true",
        "database.url": "postgres://u@example.invalid:5432/db",
        "kafka.brokers": "kafka.example.invalid:9092",
        "config.offerAvailabilityConsumerGroup": "product-discovery-offer-availability",
        "config.productContentConsumerGroup": "product-discovery-product-content",
        "config.pricingConsumerGroup": "product-discovery-pricing",
    },
    "../../shopping-cart/charts/shopping-cart": {
        "mcp.enabled": "true", "a2a.enabled": "true",
        "database.url": "postgres://u@example.invalid:5432/db",
        "kafka.brokers": "kafka.example.invalid:9092",
        "deliveryPromise.url": "http://delivery-promise.example.invalid:8080",
        "config.offerAvailabilityConsumerGroup": "shopping-cart-offer-availability",
        "config.pricingConsumerGroup": "shopping-cart-pricing",
        "config.checkoutConsumerGroup": "shopping-cart-checkout",
    },
    "../../payment-provider-simulator/charts/payment-provider-simulator": {
        "database.url": "postgres://u@example.invalid:5432/db",
    },
    "../../storefront-bff/charts/storefront-bff": {
        "config.productDiscoveryUrl": "http://product-discovery.example.invalid",
        "config.deliveryPromiseUrl": "http://delivery-promise.example.invalid",
        "config.shoppingCartUrl": "http://shopping-cart.example.invalid",
        "config.checkoutUrl": "http://checkout.example.invalid",
        "config.customerOrderingUrl": "http://customer-ordering.example.invalid",
        "config.pricingUrl": "http://pricing.example.invalid",
    },
    "../../storefront-web/charts/storefront-web": {
        "config.bffUrl": "http://storefront-bff.example.invalid",
    },
    "../../customer-ordering/charts/customer-ordering": {
        "a2a.enabled": "true",
        "mcp.enabled": "true", "frontend.enabled": "true",
        "database.url": "postgres://u@example.invalid:5432/db",
        "kafka.brokers": "kafka.example.invalid:9092",
        "config.deliveryPromiseUrl": "http://delivery-promise.example.invalid",
        "config.deliveryPromiseConsumerGroup": "customer-ordering-delivery-promise",
        "config.orderSourcingConsumerGroup": "customer-ordering-order-sourcing",
        "config.shippingConsumerGroup": "customer-ordering-shipping",
    },
    "../../delivery-promise/charts/delivery-promise": {
        "a2a.enabled": "true",
        "mcp.enabled": "true", "frontend.enabled": "true",
        "database.url": "postgres://u@example.invalid:5432/db",
        "kafka.brokers": "kafka.example.invalid:9092",
        "config.consumerGroup": "delivery-promise-consumer",
    },
    "../../last-mile-delivery/charts/last-mile-delivery": {
        "a2a.enabled": "true",
        "mcp.enabled": "true", "frontend.enabled": "true",
        "database.url": "postgres://u@example.invalid:5432/db",
        "kafka.brokers": "kafka.example.invalid:9092",
        "config.linehaulConsumerGroup": "last-mile-delivery-linehaul",
        "config.nodeTopologyConsumerGroup": "last-mile-delivery-node-topology",
        "config.shippingConsumerGroup": "last-mile-delivery-shipping",
    },
    "../../linehaul-transportation/charts/linehaul-transportation": {
        "a2a.enabled": "true",
        "mcp.enabled": "true", "frontend.enabled": "true",
        "database.url": "postgres://u@example.invalid:5432/db",
        "kafka.brokers": "kafka.example.invalid:9092",
        "config.nodeTopologyConsumerGroup": "linehaul-transportation-node-topology",
        "config.orderSourcingConsumerGroup": "linehaul-transportation-order-sourcing",
        "config.shippingAndTrackingConsumerGroup": "linehaul-transportation-shipping-and-tracking",
    },
    "../../node-performance/charts/node-performance": {
        "a2a.enabled": "true",
        "mcp.enabled": "true", "frontend.enabled": "true",
        "database.url": "postgres://u@example.invalid:5432/db",
        "kafka.brokers": "kafka.example.invalid:9092",
        "config.vendorConnectivityConsumerGroup": "node-performance-vendor-connectivity",
        "config.shippingAndTrackingConsumerGroup": "node-performance-shipping-and-tracking",
        "config.deliveryPromiseConsumerGroup": "node-performance-delivery-promise",
        "config.offerAvailabilityConsumerGroup": "node-performance-offer-availability",
        "config.nodeTopologyConsumerGroup": "node-performance-node-topology",
        "config.sellerInboundConsumerGroup": "node-performance-seller-inbound",
    },
    "../../node-topology/charts/node-topology": {
        "a2a.enabled": "true",
        "mcp.enabled": "true", "frontend.enabled": "true",
        "database.url": "postgres://u@example.invalid:5432/db",
        "kafka.brokers": "kafka.example.invalid:9092",
    },
    "../../offer-availability/charts/offer-availability": {
        "a2a.enabled": "true",
        "mcp.enabled": "true", "frontend.enabled": "true",
        "database.url": "postgres://u@example.invalid:5432/db",
        "kafka.brokers": "kafka.example.invalid:9092",
        "config.nodeTopologyConsumerGroup": "offer-availability-node-topology",
        "config.sellerInboundConsumerGroup": "offer-availability-seller-inbound",
        "config.customerReturnsConsumerGroup": "offer-availability-customer-returns",
    },
    "../../order-sourcing/charts/order-sourcing": {
        "a2a.enabled": "true",
        "mcp.enabled": "true", "frontend.enabled": "true",
        "database.url": "postgres://u@example.invalid:5432/db",
        "kafka.brokers": "kafka.example.invalid:9092",
        "config.customerOrderingConsumerGroup": "order-sourcing-customer-ordering",
        "config.deliveryPromiseConsumerGroup": "order-sourcing-delivery-promise",
        "config.lastMileDeliveryConsumerGroup": "order-sourcing-last-mile-delivery",
        "config.linehaulTransportationConsumerGroup": "order-sourcing-linehaul-transportation",
        "config.nodePerformanceConsumerGroup": "order-sourcing-node-performance",
        "config.nodeTopologyConsumerGroup": "order-sourcing-node-topology",
        "config.offerAvailabilityConsumerGroup": "order-sourcing-offer-availability",
        "config.shippingAndTrackingConsumerGroup": "order-sourcing-shipping-and-tracking",
        "config.vendorConnectivityConsumerGroup": "order-sourcing-vendor-connectivity",
    },
    "../../shipping-and-tracking/charts/shipping-and-tracking": {
        "a2a.enabled": "true",
        "mcp.enabled": "true", "frontend.enabled": "true",
        "database.url": "postgres://u@example.invalid:5432/db",
        "kafka.brokers": "kafka.example.invalid:9092",
        "crypto.shipToEncryptionKey": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
        "crypto.stopKeySecret": "ci-dummy-stop-key-secret",
        "config.customerOrderingUrl": "http://customer-ordering.example.invalid",
        "config.vendorConsumerGroup": "shipping-and-tracking-vendor",
        "config.linehaulConsumerGroup": "shipping-and-tracking-linehaul",
        "config.lastmileConsumerGroup": "shipping-and-tracking-lastmile",
        "config.catalogConsumerGroup": "shipping-and-tracking-catalog",
    },
    "../../vendor-connectivity/charts/vendor-connectivity": {
        "a2a.enabled": "true",
        "mcp.enabled": "true", "frontend.enabled": "true",
        "database.url": "postgres://u@example.invalid:5432/db",
        "kafka.brokers": "kafka.example.invalid:9092",
        "config.nodeConsumerGroup": "vendor-connectivity-node",
        "config.inboundConsumerGroup": "vendor-connectivity-inbound",
        "config.packagingConsumerGroup": "vendor-connectivity-packaging",
        "config.listingConsumerGroup": "vendor-connectivity-listing",
        "config.sourcingConsumerGroup": "vendor-connectivity-sourcing",
        "config.customerReturnsConsumerGroup": "vendor-connectivity-customer-returns",
        "config.nodeTopologyUrl": "http://node-topology.example.invalid",
        "config.offerAvailabilityUrl": "http://offer-availability.example.invalid",
        "config.shippingAndTrackingUrl": "http://shipping-and-tracking.example.invalid",
        "config.nodePerformanceUrl": "http://node-performance.example.invalid",
    },
    "../../seller-inbound/charts/seller-inbound": {
        "mcp.enabled": "true", "a2a.enabled": "true",
        "database.url": "postgres://u@example.invalid:5432/db",
        "kafka.brokers": "kafka.example.invalid:9092",
        "config.nodeConsumerGroup": "seller-inbound-node",
        "config.catalogConsumerGroup": "seller-inbound-catalog",
        "config.receiptConsumerGroup": "seller-inbound-receipt",
        "config.sourcingConsumerGroup": "seller-inbound-sourcing",
        "config.ssccCompanyPrefix": "0614141",
    },
    # dock-scheduling and yard-management: OLTP api + the optional mcp, relay,
    # analytics (projector/reports) components and the sweep CronJob(s); no
    # frontend. Both charts refuse to render without a database source and the
    # Kafka brokers (real Postgres and real Kafka are the only runtime), their
    # always-on consumers each need a stable group id, and analytics needs a DSN
    # source (dock-scheduling: analytics.database.projectorUrl; yard-management:
    # analytics.url), so give them dummies (no password).
    "../../dock-scheduling/charts/dock-scheduling": {
        "mcp.enabled": "true", "relay.enabled": "true", "analytics.enabled": "true",
        "analytics.database.projectorUrl": "postgres://p@example.invalid:5432/a",
        "database.url": "postgres://u@example.invalid:5432/db",
        "kafka.brokers": "kafka.example.invalid:9092",
        "config.yardConsumerGroup": "dock-scheduling-yard",
        "config.facilityConsumerGroup": "dock-scheduling-facility",
        "config.asnConsumerGroup": "dock-scheduling-asn",
        "config.cptConsumerGroup": "dock-scheduling-cpt",
    },
    "../../yard-management/charts/yard-management": {
        "mcp.enabled": "true", "relay.enabled": "true", "analytics.enabled": "true",
        "analytics.url": "postgres://u@example.invalid:5432/analytics",
        "database.url": "postgres://u@example.invalid:5432/db",
        "kafka.brokers": "kafka.example.invalid:9092",
        "config.dockSchedulingConsumerGroup": "yard-management-dock-scheduling",
        "config.facilityConsumerGroup": "yard-management-facility",
        "config.inboundReceivingConsumerGroup": "yard-management-inbound-receiving",
    },
    # outbound-shipping: OLTP api (REST + inline outbox relay + six Kafka
    # consumers) + the optional mcp component; no analytics projector/reports,
    # no relay Deployment, no sweep, no frontend. The chart refuses to render
    # without a database source and the Kafka brokers (real Postgres and real
    # Kafka are the only runtime), so give it dummies (no password). Its six
    # consumer groups have non-empty chart defaults, so none needs a --set.
    "../../outbound-shipping/charts/outbound-shipping": {
        "mcp.enabled": "true",
        "database.url": "postgres://u@example.invalid:5432/db",
        "kafka.brokers": "kafka.example.invalid:9092",
    },
    # Single Deployment/Service each, no optional-component toggles that
    # add another pair -- included for completeness/regression coverage,
    # not because they're currently at risk of this specific bug shape.
    "../../warehouse-ops-agent/charts/warehouse-ops-agent": {},
    "../../warehouse-console/charts/warehouse-console": {},
    "../../ecosystem/charts/ecosystem": {},
    # asrs-control (WCS AS/RS controller, plan WCS-02): the api plus the two
    # optional read-only agent components (mcp, a2a; its ADR 0005), each with
    # its own Deployment+Service pair. Real Postgres and real Kafka only, so
    # the chart refuses to render without a database source and brokers.
    # Dummies, no password; the MQTT URL keeps its chart default.
    "../../asrs-control/charts/asrs-control": {
        "mcp.enabled": "true", "a2a.enabled": "true",
        "database.url": "postgres://u@example.invalid:5432/db",
        "kafka.brokers": "kafka.example.invalid:9092",
    },
    # amr-fleet-control (WCS VDA 5050 master control, plan WCS-03): the api plus
    # the two optional read-only agent components (mcp, a2a), standalone and
    # (agents.colocate=true, ADR 0012) as one agents pod. Real Postgres and
    # real Kafka only; dummies, no password; the MQTT URL keeps its default.
    "../../amr-fleet-control/charts/amr-fleet-control": {
        "mcp.enabled": "true", "a2a.enabled": "true",
        "database.url": "postgres://u@example.invalid:5432/db",
        "kafka.brokers": "kafka.example.invalid:9092",
    },
    # equipment-emulator (WCS test infrastructure, not a bounded context):
    # one Deployment+Service, no optional components, no database.
    "../../equipment-emulator/charts/equipment-emulator": {},
    # customer-returns (retail-network bounded context): the api plus the
    # optional read-only agent components (mcp, a2a) and the analytics
    # projector/reports pair, each with its own Deployment (+Service). Real
    # Postgres and real Kafka only: the chart refuses to render without a
    # database source, brokers, the four stable consumer groups, and (analytics
    # on) an analytical DSN and consumer group. Dummies, no password.
    "../../customer-returns/charts/customer-returns": {
        "mcp.enabled": "true", "a2a.enabled": "true", "analytics.enabled": "true",
        "database.url": "postgres://u@example.invalid:5432/db",
        "kafka.brokers": "kafka.example.invalid:9092",
        "config.orderConsumerGroup": "customer-returns-order",
        "config.topologyConsumerGroup": "customer-returns-topology",
        "config.sourcingConsumerGroup": "customer-returns-sourcing",
        "config.vendorConsumerGroup": "customer-returns-vendor",
        "analytics.database.projectorUrl": "postgres://p@example.invalid:5432/a",
        "analytics.projector.consumerGroup": "customer-returns-analytics",
    },
}


def selector_selects_deployment(selector: dict, deployment: dict) -> bool:
    """True if `selector` (a Service's spec.selector) would route traffic
    to `deployment`'s pods -- i.e. every key in the selector matches that
    Deployment's pod template labels, AND the Deployment's own
    selector.matchLabels is fully satisfied by those same pod labels (a
    Deployment can never actually run pods that don't satisfy its own
    selector, so this is really just confirming label agreement both
    ways)."""
    pod_labels = deployment["spec"]["template"]["metadata"]["labels"]
    match_labels = deployment["spec"]["selector"]["matchLabels"]
    if not all(pod_labels.get(k) == v for k, v in selector.items()):
        return False
    if not all(pod_labels.get(k) == v for k, v in match_labels.items()):
        return False
    return True


def resolve_target_port(service_port: dict, deployment: dict) -> list:
    """The containerPorts a NAMED targetPort resolves to in `deployment`'s pod
    (every container's ports whose name equals it). Kubernetes takes the first
    match, so anything other than exactly one is a routing ambiguity or a
    dangling name."""
    name = service_port.get("targetPort")
    containers = deployment["spec"]["template"]["spec"].get("containers") or []
    return [
        f"{c.get('name')}:{p.get('containerPort')}"
        for c in containers
        for p in (c.get("ports") or [])
        if p.get("name") == name
    ]


def check_chart(chart_path: str, extra_set: dict, label: str = "") -> list[str]:
    """Returns a list of human-readable failure lines for this chart (empty
    list = chart is conformant)."""
    where = f"{chart_path}{label}"
    args = ["helm", "template", RELEASE_NAME, chart_path]
    for key, value in extra_set.items():
        args += ["--set", f"{key}={value}"]
    result = subprocess.run(args, capture_output=True, text=True)
    if result.returncode != 0:
        return [f"{where}: helm template failed: {result.stderr.strip()[:500]}"]

    docs = [d for d in yaml.safe_load_all(result.stdout) if d]
    deployments = [d for d in docs if d.get("kind") == "Deployment"]
    services = [d for d in docs if d.get("kind") == "Service"]

    failures = []
    for svc in services:
        selector = (svc.get("spec") or {}).get("selector") or {}
        if not selector:
            continue
        matched = [d for d in deployments if selector_selects_deployment(selector, d)]
        if len(matched) != 1:
            failures.append(
                f"{where}: Service {svc['metadata']['name']} selects "
                f"{len(matched)} Deployment(s) (want exactly 1): "
                f"{[d['metadata']['name'] for d in matched]}"
            )
            continue
        for port in svc["spec"].get("ports") or []:
            if not isinstance(port.get("targetPort"), str):
                continue  # numeric or defaulted: nothing to resolve by name
            hits = resolve_target_port(port, matched[0])
            if len(hits) != 1:
                failures.append(
                    f"{where}: Service {svc['metadata']['name']} port {port.get('port')} "
                    f"targetPort {port['targetPort']!r} resolves to {len(hits)} containerPort(s) "
                    f"of {matched[0]['metadata']['name']} (want exactly 1): {hits}"
                )
    return failures


def renders(extra_set: dict) -> list[tuple[str, dict]]:
    """(label, --set map) pairs to render: the entry as listed, plus the
    agents.colocate render when the entry enables both mcp and a2a."""
    out = [("", extra_set)]
    if extra_set.get("mcp.enabled") == "true" and extra_set.get("a2a.enabled") == "true":
        out.append((" [agents.colocate=true]", {**extra_set, "agents.colocate": "true"}))
    return out


def main() -> int:
    all_failures = []
    count = 0
    for chart_path, extra_set in CHARTS.items():
        for label, sets in renders(extra_set):
            count += 1
            failures = check_chart(chart_path, sets, label)
            if failures:
                all_failures.extend(failures)
            else:
                print(f"OK   {chart_path}{label}")

    if all_failures:
        print()
        print("FAIL — the following Services do not select exactly one Deployment, "
              "or a named targetPort does not resolve to exactly one containerPort:")
        for line in all_failures:
            print(f"  {line}")
        return 1

    print()
    print(f"All {len(CHARTS)} charts conformant ({count} renders): every Service selects exactly "
          "one Deployment and every named targetPort resolves to exactly one containerPort.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
