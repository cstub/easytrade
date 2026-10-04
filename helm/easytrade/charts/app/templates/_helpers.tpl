{{/*
Expand the name of the chart.
*/}}
{{- define "app.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "app.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "app.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "app.labels" -}}
helm.sh/chart: {{ include "app.chart" . }}
{{ include "app.selectorLabels" . }}
app.kubernetes.io/version: {{ .Values.global.image.tag | quote }}
app.kubernetes.io/dt-version: {{ .Values.global.dynatrace.version | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: easytrade
{{- with .Values.global.labels }}
{{ toYaml . }}
{{- end }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "app.selectorLabels" -}}
app.kubernetes.io/name: {{ include "app.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "app.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "app.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
OpenTelemetry environment for components with otel.enabled. Placed before the component's own
env, so a component can still override a variable.
- OTEL_SERVICE_NAME: the component name, without the release prefix.
- OTEL_RESOURCE_ATTRIBUTES: service.namespace, service.version (the image tag),
  deployment.environment.name and any global.otel.resourceAttributes.
- Exporter: global.otel.endpoint for OTLP/HTTP; for grpc components global.otel.grpcEndpoint,
  or else the endpoint's host with port 4317. Without an endpoint, all exporters are set to none.
*/}}
{{- define "app.otelEnv" -}}
{{- if .Values.otel.enabled }}
{{- $otel := .Values.global.otel | default dict }}
{{- $tag := .Values.image.tag | default .Values.global.image.tag | toString }}
{{- $attributes := list }}
{{- with $otel.serviceNamespace }}{{ $attributes = append $attributes (printf "service.namespace=%s" .) }}{{ end }}
{{- $attributes = append $attributes (printf "service.version=%s" $tag) }}
{{- with $otel.deploymentEnvironment }}{{ $attributes = append $attributes (printf "deployment.environment.name=%s" .) }}{{ end }}
{{- range $key, $value := $otel.resourceAttributes }}{{ $attributes = append $attributes (printf "%s=%s" $key ($value | toString)) }}{{ end }}
- name: OTEL_SERVICE_NAME
  value: {{ include "app.name" . | quote }}
- name: OTEL_RESOURCE_ATTRIBUTES
  value: {{ join "," $attributes | quote }}
{{- if $otel.endpoint }}
{{- $endpoint := $otel.endpoint }}
{{- if eq .Values.otel.protocol "grpc" }}
{{- $endpoint = $otel.grpcEndpoint | default (printf "%s:4317" (regexReplaceAll ":[0-9]+$" (urlParse $otel.endpoint).host "")) }}
{{- end }}
- name: OTEL_EXPORTER_OTLP_ENDPOINT
  value: {{ $endpoint | quote }}
- name: OTEL_EXPORTER_OTLP_PROTOCOL
  value: {{ .Values.otel.protocol | quote }}
- name: OTEL_TRACES_SAMPLER
  value: "parentbased_always_on"
{{- else }}
- name: OTEL_TRACES_EXPORTER
  value: "none"
- name: OTEL_METRICS_EXPORTER
  value: "none"
- name: OTEL_LOGS_EXPORTER
  value: "none"
{{- end }}
{{- end }}
{{- end }}
