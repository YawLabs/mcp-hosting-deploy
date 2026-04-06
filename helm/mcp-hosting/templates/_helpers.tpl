{{/*
Expand the name of the chart.
*/}}
{{- define "mcp-hosting.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "mcp-hosting.fullname" -}}
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
Chart label
*/}}
{{- define "mcp-hosting.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "mcp-hosting.labels" -}}
helm.sh/chart: {{ include "mcp-hosting.chart" . }}
{{ include "mcp-hosting.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "mcp-hosting.selectorLabels" -}}
app.kubernetes.io/name: {{ include "mcp-hosting.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
PostgreSQL hostname
*/}}
{{- define "mcp-hosting.postgresHost" -}}
{{ include "mcp-hosting.fullname" . }}-postgres
{{- end }}

{{/*
Redis hostname
Uses in-cluster Valkey when redis.enabled=true, otherwise externalRedis.
*/}}
{{- define "mcp-hosting.redisHost" -}}
{{- if .Values.redis.enabled -}}
{{ include "mcp-hosting.fullname" . }}-redis
{{- else -}}
{{- required "externalRedis.host is required when redis.enabled=false. Set it to your ElastiCache/Memorystore endpoint." .Values.externalRedis.host -}}
{{- end -}}
{{- end }}

{{/*
Redis port
*/}}
{{- define "mcp-hosting.redisPort" -}}
{{- if .Values.redis.enabled -}}
6379
{{- else -}}
{{ .Values.externalRedis.port | default 6379 }}
{{- end -}}
{{- end }}

{{/*
DATABASE_URL connection string
Uses in-cluster postgres when postgres.enabled=true, otherwise externalDatabase.
Fails with a clear error if external DB is required but not configured.
*/}}
{{- define "mcp-hosting.databaseUrl" -}}
{{- if .Values.postgres.enabled -}}
postgresql://{{ .Values.postgres.username }}:{{ .Values.postgres.password }}@{{ include "mcp-hosting.postgresHost" . }}:5432/{{ .Values.postgres.database }}
{{- else -}}
{{- required "externalDatabase.host is required when postgres.enabled=false. Set it to your RDS/Cloud SQL endpoint." .Values.externalDatabase.host -}}
{{- required "externalDatabase.password is required when postgres.enabled=false." .Values.externalDatabase.password -}}
postgresql://{{ .Values.externalDatabase.username }}:{{ .Values.externalDatabase.password }}@{{ .Values.externalDatabase.host }}:{{ .Values.externalDatabase.port }}{{ printf "/" }}{{ .Values.externalDatabase.database }}?sslmode={{ .Values.externalDatabase.sslMode }}
{{- end -}}
{{- end }}

{{/*
Namespace
*/}}
{{- define "mcp-hosting.namespace" -}}
{{ .Values.namespace | default "mcp-hosting" }}
{{- end }}
