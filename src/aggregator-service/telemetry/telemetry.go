// Package telemetry sets up the OpenTelemetry SDK: traces, metrics and logs
// exported over OTLP/HTTP. Endpoint, service name, resource attributes and
// sampler come from the standard OTEL_* environment variables.
package telemetry

import (
	"context"
	"errors"
	"os"

	"go.opentelemetry.io/contrib/instrumentation/runtime"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/exporters/otlp/otlplog/otlploghttp"
	"go.opentelemetry.io/otel/exporters/otlp/otlpmetric/otlpmetrichttp"
	"go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracehttp"
	"go.opentelemetry.io/otel/log/global"
	"go.opentelemetry.io/otel/propagation"
	sdklog "go.opentelemetry.io/otel/sdk/log"
	sdkmetric "go.opentelemetry.io/otel/sdk/metric"
	"go.opentelemetry.io/otel/sdk/resource"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	semconv "go.opentelemetry.io/otel/semconv/v1.40.0"
)

// Setup installs global tracer, meter and logger providers and starts the Go
// runtime metrics. The returned function flushes and stops them.
//
// A signal whose OTEL_<SIGNAL>_EXPORTER is "none", or every signal when
// OTEL_SDK_DISABLED is "true", keeps the no-op provider.
func Setup(ctx context.Context, defaultServiceName string) (func(context.Context) error, error) {
	otel.SetTextMapPropagator(propagation.NewCompositeTextMapPropagator(
		propagation.TraceContext{}, propagation.Baggage{},
	))
	if os.Getenv("OTEL_SDK_DISABLED") == "true" {
		return func(context.Context) error { return nil }, nil
	}

	res, err := resource.New(ctx,
		resource.WithAttributes(semconv.ServiceName(defaultServiceName)),
		resource.WithTelemetrySDK(),
		resource.WithHost(),
		resource.WithProcessRuntimeName(),
		resource.WithProcessRuntimeVersion(),
		resource.WithFromEnv(),
	)
	if err != nil {
		// res still holds every attribute that could be read. A malformed
		// OTEL_RESOURCE_ATTRIBUTES must not keep the service from starting.
		otel.Handle(err)
	}

	var shutdowns []func(context.Context) error
	shutdown := func(ctx context.Context) error {
		var errs error
		for _, s := range shutdowns {
			errs = errors.Join(errs, s(ctx))
		}
		return errs
	}

	if enabled("OTEL_TRACES_EXPORTER") {
		exporter, err := otlptracehttp.New(ctx)
		if err != nil {
			return nil, err
		}
		tp := sdktrace.NewTracerProvider(sdktrace.WithResource(res), sdktrace.WithBatcher(exporter))
		otel.SetTracerProvider(tp)
		shutdowns = append(shutdowns, tp.Shutdown)
	}

	if enabled("OTEL_METRICS_EXPORTER") {
		exporter, err := otlpmetrichttp.New(ctx)
		if err != nil {
			return nil, errors.Join(err, shutdown(ctx))
		}
		mp := sdkmetric.NewMeterProvider(sdkmetric.WithResource(res), sdkmetric.WithReader(sdkmetric.NewPeriodicReader(exporter)))
		otel.SetMeterProvider(mp)
		shutdowns = append(shutdowns, mp.Shutdown)
		if err := runtime.Start(); err != nil {
			return nil, errors.Join(err, shutdown(ctx))
		}
	}

	if enabled("OTEL_LOGS_EXPORTER") {
		exporter, err := otlploghttp.New(ctx)
		if err != nil {
			return nil, errors.Join(err, shutdown(ctx))
		}
		lp := sdklog.NewLoggerProvider(sdklog.WithResource(res), sdklog.WithProcessor(sdklog.NewBatchProcessor(exporter)))
		global.SetLoggerProvider(lp)
		shutdowns = append(shutdowns, lp.Shutdown)
	}

	return shutdown, nil
}

func enabled(exporterEnv string) bool {
	return os.Getenv(exporterEnv) != "none"
}
