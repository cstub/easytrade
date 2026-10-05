package telemetry

import (
	"context"
	"testing"
)

func TestSetupSurvivesMalformedResourceAttributes(t *testing.T) {
	t.Setenv("OTEL_RESOURCE_ATTRIBUTES", "service.namespace=easytrade,team=a,b")
	t.Setenv("OTEL_TRACES_EXPORTER", "none")
	t.Setenv("OTEL_METRICS_EXPORTER", "none")
	t.Setenv("OTEL_LOGS_EXPORTER", "none")

	shutdown, err := Setup(context.Background(), "test-service")
	if err != nil {
		t.Fatalf("Setup failed on a malformed OTEL_RESOURCE_ATTRIBUTES: %v", err)
	}
	if err := shutdown(context.Background()); err != nil {
		t.Fatalf("shutdown failed: %v", err)
	}
}
