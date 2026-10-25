package main

import "testing"

func TestProbeMatrixCoversEveryBoundedContextWithReadOnlyCalls(t *testing.T) {
	want := map[string]string{
		"order-management":        "get_promise_health",
		"inventory-storage":       "get_inventory_flow_accuracy_report",
		"wes-work-planning":       "get_release_throughput_report",
		"fulfillment-execution":   "diagnose_stuck_tasks",
		"workforce-management":    "propose_path_heads",
		"facility-layout":         "list_sites",
		"labor-performance":       "get_task_type_utilization",
		"process-path-management": "list_process_paths",
	}
	if len(probes) != len(want) {
		t.Fatalf("probe count = %d, want %d", len(probes), len(want))
	}
	for service, tool := range want {
		probe, ok := probes[service]
		if !ok {
			t.Errorf("missing probe for %s", service)
			continue
		}
		if probe.tool != tool {
			t.Errorf("%s tool = %q, want %q", service, probe.tool, tool)
		}
		if probe.resultField == "" {
			t.Errorf("%s has no result-shape field", service)
		}
	}
}

func TestUnknownServiceIsRejected(t *testing.T) {
	if _, err := probeFor("unknown"); err == nil {
		t.Fatal("expected unknown service error")
	}
}
