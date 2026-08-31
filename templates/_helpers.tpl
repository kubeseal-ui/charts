{{/*
Expand the name of the chart.
*/}}
{{- define "kubeseal-ui.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "kubeseal-ui.fullname" -}}
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

{{- define "kubeseal-ui.apiName" -}}
{{- printf "%s-api" (include "kubeseal-ui.fullname" .) }}
{{- end }}

{{- define "kubeseal-ui.uiName" -}}
{{- printf "%s-ui" (include "kubeseal-ui.fullname" .) }}
{{- end }}

{{- define "kubeseal-ui.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "kubeseal-ui.labels" -}}
helm.sh/chart: {{ include "kubeseal-ui.chart" . }}
{{ include "kubeseal-ui.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: kubeseal-ui
{{- end }}

{{- define "kubeseal-ui.selectorLabels" -}}
app.kubernetes.io/name: {{ include "kubeseal-ui.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "kubeseal-ui.api.selectorLabels" -}}
{{ include "kubeseal-ui.selectorLabels" . }}
app.kubernetes.io/component: api
{{- end }}

{{- define "kubeseal-ui.ui.selectorLabels" -}}
{{ include "kubeseal-ui.selectorLabels" . }}
app.kubernetes.io/component: ui
{{- end }}
