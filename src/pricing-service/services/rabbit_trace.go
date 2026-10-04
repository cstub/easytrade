package services

import (
	"context"

	amqp "github.com/rabbitmq/amqp091-go"
	"go.opentelemetry.io/otel"
	semconv "go.opentelemetry.io/otel/semconv/v1.40.0"
	"go.opentelemetry.io/otel/trace"
)

var tracer = otel.Tracer("dynatrace.com/easytrade/pricing-service/services")

// startPublishSpan starts a PRODUCER span for a message to queueName and
// writes its W3C trace context into headers.
func startPublishSpan(ctx context.Context, queueName string, headers amqp.Table) (context.Context, trace.Span) {
	ctx, span := tracer.Start(ctx, "send "+queueName,
		trace.WithSpanKind(trace.SpanKindProducer),
		trace.WithAttributes(
			semconv.MessagingSystemRabbitMQ,
			semconv.MessagingOperationTypeSend,
			semconv.MessagingOperationName("publish"),
			semconv.MessagingDestinationName(queueName),
		),
	)
	otel.GetTextMapPropagator().Inject(ctx, headerCarrier(headers))
	return ctx, span
}

// headerCarrier adapts AMQP message headers to a propagation.TextMapCarrier.
type headerCarrier amqp.Table

func (c headerCarrier) Get(key string) string {
	value, _ := c[key].(string)
	return value
}

func (c headerCarrier) Set(key, value string) {
	c[key] = value
}

func (c headerCarrier) Keys() []string {
	keys := make([]string, 0, len(c))
	for key := range c {
		keys = append(keys, key)
	}
	return keys
}
