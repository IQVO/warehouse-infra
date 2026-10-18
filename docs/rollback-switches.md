# Rollback switches (deliberately off) and how to flip them

The fleet keeps a few synchronous REST edges that are BUILT but switched OFF in
the reference deployment. Each one is the documented rollback path for a live
event-fed edge: flipping it restores a synchronous lookup without redeploying
code.

Every switch is a value in the consumer's `helm-values/<context>.yaml` (ADR 0002
D2, `docs/adr/0002-application-delivery-boundary.md`): a dedicated chart value
where the chart has one, otherwise an `extraEnv` entry. A flip is a values
change: edit the file, check it with `helm template` (see
`helm-values/_README.md`), merge to `develop`, and ArgoCD rolls the pods. No
`terraform apply` is involved, and a revert is a Git revert.

## R6 — inventory-storage -> facility-layout classification lookup

- Live edge it backs up: K4 (`config.locationLookupMode: kafka` in
  `helm-values/inventory-storage.yaml`, rendered to `LOCATION_LOOKUP_MODE`:
  facility events into a local cache).
- Off switch: `permissive` (the chart default) accepts every bin. The documented
  rollback is `config.locationLookupMode: http` plus `config.facilityLayoutBaseUrl:
  http://facility-layout.warehouse-systems.svc.cluster.local:80` (both dedicated
  chart values, so never `extraEnv`), calling
  `GET /locations/{code}/classification` on the stow hot path.
- When to flip: only if the facility-events feed is broken AND stow placement rules
  must keep enforcing (the cache going stale fails open today).

## R10 — workforce-management -> labor-performance performance lookup

- Live edge it backs up: K17 (`LABOR_PERFORMANCE_MODE=kafka-cache`,
  `TaskPerformanceRecorded` into a local cache).
- Off switch: `LABOR_PERFORMANCE_MODE=http` plus `LABOR_PERFORMANCE_BASE_URL`
  (both kept adjacent in `helm-values/workforce-management.yaml`'s `extraEnv` for
  exactly this flip), calling `GET /task-types/{taskType}/performance`.
- When to flip: only if the labor-performance events feed is broken AND
  ProposePathPlan must keep enriching with measured rates.

## Process-path catalogue: Kafka back to the frozen file

- Live: fulfillment-execution, wes-work-planning and workforce-management read the
  catalogue from process-path-management's events (`PATH_CATALOGUE_SOURCE=kafka`
  in each one's `extraEnv`, `pathCatalogue.enabled: false`).
- Rollback, in each of the three files: drop the `PATH_CATALOGUE_SOURCE` entry and
  set `pathCatalogue.enabled: true` with the content of
  `config/process-paths/sortable-fc.yaml` as `pathCatalogue.content`. That file is
  the pre-RELOCATE, pre-intake catalogue (see its header).
- When to flip: only if the process-path-management topic is unusable and the
  three consumers cannot become ready.

## Flipped ON on 2026-10-17 (for the record)

- K19: network-fulfillment `config.eventPublisher: kafka`
  (`helm-values/network-fulfillment.yaml`) — the context's own analytics projector
  and reports read the stream it publishes.
- R8: fulfillment-execution `LOCATION_ROLE_MODE=http`
  (`helm-values/fulfillment-execution.yaml`) — registration-time station-location
  role check; not a rollback switch, a first switch-on.
