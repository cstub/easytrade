#!/bin/sh
# Writes the ngx_otel_module settings from the standard OTEL_* environment variables
# (the module itself reads none of them). Runs from /docker-entrypoint.d before nginx starts.
#   OTEL_EXPORTER_OTLP_ENDPOINT  OTLP/gRPC endpoint, host:port (an http:// prefix is dropped)
#   OTEL_SERVICE_NAME            service.name
#   OTEL_RESOURCE_ATTRIBUTES     key=value,... added as resource attributes
#   OTEL_TRACES_EXPORTER=none or OTEL_SDK_DISABLED=true switches tracing off
set -eu

conf=/etc/nginx/conf.d/00-otel.conf
endpoint=${OTEL_EXPORTER_OTLP_ENDPOINT:-localhost:4317}
endpoint=${endpoint#http://}

trace=on
if [ "${OTEL_TRACES_EXPORTER:-}" = "none" ] || [ "${OTEL_SDK_DISABLED:-}" = "true" ]; then
    trace=off
fi

{
    echo "otel_exporter { endpoint ${endpoint}; }"
    echo "otel_service_name \"${OTEL_SERVICE_NAME:-frontendreverseproxy}\";"
    old_ifs=$IFS
    IFS=','
    for pair in ${OTEL_RESOURCE_ATTRIBUTES:-}; do
        key=${pair%%=*}
        value=${pair#*=}
        if [ -n "$key" ] && [ "$key" != "$pair" ]; then
            echo "otel_resource_attr ${key} \"${value}\";"
        fi
    done
    IFS=$old_ifs
    echo "otel_trace ${trace};"
    echo "otel_trace_context propagate;"
} > "$conf"

echo "$0: OpenTelemetry tracing ${trace}, exporting to ${endpoint}"
