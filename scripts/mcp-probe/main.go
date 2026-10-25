package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"net/http"
	"os"
	"time"

	"github.com/modelcontextprotocol/go-sdk/mcp"
)

type probeSpec struct {
	tool        string
	arguments   map[string]any
	resultField string
}

var probes = map[string]probeSpec{
	"order-management": {
		tool: "get_promise_health",
		arguments: map[string]any{
			"from": "2000-01-01T00:00:00Z",
			"to":   "2100-01-01T00:00:00Z",
		},
		resultField: "ordersAllocatedTotal",
	},
	"inventory-storage": {
		tool: "get_inventory_flow_accuracy_report",
		arguments: map[string]any{
			"from":        "2000-01-01T00:00:00Z",
			"to":          "2100-01-01T00:00:00Z",
			"granularity": "hour",
		},
		resultField: "rows",
	},
	"wes-work-planning": {
		tool: "get_release_throughput_report",
		arguments: map[string]any{
			"from":        "2000-01-01T00:00:00Z",
			"to":          "2100-01-01T00:00:00Z",
			"granularity": "hour",
		},
		resultField: "rows",
	},
	"fulfillment-execution": {
		tool:        "diagnose_stuck_tasks",
		arguments:   map[string]any{"withinSeconds": 0},
		resultField: "count",
	},
	"workforce-management": {
		tool: "propose_path_heads",
		arguments: map[string]any{
			"buildingId":  "acceptance",
			"pathId":      "pick",
			"charge":      1,
			"plannedRate": 1,
		},
		resultField: "proposedHeads",
	},
	"facility-layout": {
		tool:        "list_sites",
		arguments:   map[string]any{},
		resultField: "sites",
	},
	"labor-performance": {
		tool: "get_task_type_utilization",
		arguments: map[string]any{
			"taskType":      "PICK",
			"windowSeconds": 3600,
		},
		resultField: "taskType",
	},
	"process-path-management": {
		tool:        "list_process_paths",
		arguments:   map[string]any{"activeOnly": true},
		resultField: "paths",
	},
}

func probeFor(service string) (probeSpec, error) {
	probe, ok := probes[service]
	if !ok {
		return probeSpec{}, fmt.Errorf("no MCP acceptance probe for %q", service)
	}
	return probe, nil
}

func run(ctx context.Context, service, endpoint string) (map[string]any, error) {
	probe, err := probeFor(service)
	if err != nil {
		return nil, err
	}
	client := mcp.NewClient(
		&mcp.Implementation{Name: "warehouse-cluster-acceptance", Version: "1.0.0"},
		nil,
	)
	transport := &mcp.StreamableClientTransport{
		Endpoint: endpoint,
		HTTPClient: &http.Client{
			Timeout: 15 * time.Second,
		},
	}
	session, err := client.Connect(ctx, transport, nil)
	if err != nil {
		return nil, fmt.Errorf("initialize MCP session: %w", err)
	}
	defer func() { _ = session.Close() }()

	listed, err := session.ListTools(ctx, nil)
	if err != nil {
		return nil, fmt.Errorf("list MCP tools: %w", err)
	}
	advertised := false
	for _, tool := range listed.Tools {
		if tool.Name != probe.tool {
			continue
		}
		advertised = true
		if tool.Annotations == nil || !tool.Annotations.ReadOnlyHint {
			return nil, fmt.Errorf("tool %q is not annotated read-only", probe.tool)
		}
	}
	if !advertised {
		return nil, fmt.Errorf("read-only tool %q is not advertised", probe.tool)
	}

	result, err := session.CallTool(ctx, &mcp.CallToolParams{
		Name:      probe.tool,
		Arguments: probe.arguments,
	})
	if err != nil {
		return nil, fmt.Errorf("call tool %q: %w", probe.tool, err)
	}
	if result.IsError {
		return nil, fmt.Errorf("tool %q returned an error result: %+v", probe.tool, result.Content)
	}
	structured, ok := result.StructuredContent.(map[string]any)
	if !ok {
		return nil, fmt.Errorf("tool %q returned no structured object", probe.tool)
	}
	if _, ok := structured[probe.resultField]; !ok {
		return nil, fmt.Errorf(
			"tool %q result has no %q field: %+v", probe.tool, probe.resultField, structured,
		)
	}
	return map[string]any{
		"service":     service,
		"tool":        probe.tool,
		"resultField": probe.resultField,
		"result":      structured,
	}, nil
}

func main() {
	service := flag.String("service", "", "bounded-context service name")
	endpoint := flag.String("endpoint", "", "Streamable HTTP MCP endpoint")
	flag.Parse()
	if *service == "" || *endpoint == "" {
		fmt.Fprintln(os.Stderr, "-service and -endpoint are required")
		os.Exit(2)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	result, err := run(ctx, *service, *endpoint)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	if err := json.NewEncoder(os.Stdout).Encode(result); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
