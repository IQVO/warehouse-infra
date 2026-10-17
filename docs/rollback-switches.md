# Rollback switches (deliberately off) and how to flip them

The fleet keeps a small number of synchronous REST edges that are BUILT but switched
OFF in the reference deployment. Each is the documented rollback path for a live
event-fed edge: flipping one restores a synchronous lookup without redeploying code.
All of them are env-var driven; a change here needs a `terraform apply` and a pod
roll (the computed extraEnv layer in `services.tf` overrides chart values, so these
live in `terraform/locals.tf`'s `local.sync_edge_env`, never in `helm-values/`).

## R6 — inventory-storage -> facility-layout classification lookup

- Live edge it backs up: K4 (`LOCATION_LOOKUP_MODE=kafka`, facility events into a
  local cache).
- Off switch: `LOCATION_LOOKUP_MODE` unset means `permissive` in the binary; the
  documented rollback is `LOCATION_LOOKUP_MODE=http` plus
  `FACILITY_LAYOUT_BASE_URL`, calling `GET /locations/{code}/classification` on the
  stow hot path.
- When to flip: only if the facility-events feed is broken AND stow placement rules
  must keep enforcing (the cache going stale fails open today).

## R10 — workforce-management -> labor-performance performance lookup

- Live edge it backs up: K17 (`LABOR_PERFORMANCE_MODE=kafka-cache`,
  `TaskPerformanceRecorded` into a local cache).
- Off switch: `LABOR_PERFORMANCE_MODE=http` plus `LABOR_PERFORMANCE_BASE_URL`
  (both kept adjacent in `sync_edge_env` for exactly this flip), calling
  `GET /task-types/{taskType}/performance`.
- When to flip: only if the labor-performance events feed is broken AND
  ProposePathPlan must keep enriching with measured rates.

## Flipped ON on 2026-10-17 (for the record)

- K19: network-fulfillment `eventPublisher = "kafka"` (`terraform/network-fulfillment.tf`)
  — the context's own analytics projector and reports read the stream it publishes.
- R8: fulfillment-execution `LOCATION_ROLE_MODE=http` (`local.sync_edge_env`) —
  registration-time station-location role check; not a rollback switch, a first
  switch-on.
