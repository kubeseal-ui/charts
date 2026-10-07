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

{{/*
Serialize the typed gitops credential list into the
auth_ref:mode:username:token_file entries consumed by
GITOPS_CREDENTIAL_REFS. Token values never appear here —
only the Secret-mounted file paths.
*/}}
{{- define "kubeseal-ui.gitopsCredentialRefs" -}}
{{- $entries := list -}}
{{- range .Values.api.gitops.credentials -}}
{{- $username := default "" .username -}}
{{- $entries = append $entries (printf "%s:%s:%s:%s" .authRef .mode $username .tokenFile) -}}
{{- end -}}
{{- join "," $entries -}}
{{- end -}}

{{/*
Serialize the namespace gitops policy list into the
namespace:repository:branch:path_template:auth_ref:mode[:adapter_name][:allowed_paths]
entries consumed by GITOPS_NAMESPACES. Path templates serialize '/'
as '-' so the ':' delimiter is unambiguous; the api's parseMappingSpecs
restores the slashes. Tokens never appear here — only the server-side
policy fields.
*/}}
{{- define "kubeseal-ui.gitopsNamespaceSpecs" -}}
{{- $entries := list -}}
{{- range .Values.api.gitops.namespaces -}}
{{- $path := replace "/" "-" .pathTemplate -}}
{{- $entry := printf "%s:%s:%s:%s:%s:%s" .namespace .repository .branch $path .authRef .mode -}}
{{- if .proposalAdapter -}}
{{- $entry = printf "%s:%s" $entry .proposalAdapter -}}
{{- end -}}
{{- if .allowedPaths -}}
{{- $allowed := join "-" .allowedPaths -}}
{{- $entry = printf "%s:%s" $entry $allowed -}}
{{- end -}}
{{- $entries = append $entries $entry -}}
{{- end -}}
{{- join "," $entries -}}
{{- end -}}

{{/*
Serialize the proposal adapter list into the
name:type:token_file[:base_url] entries consumed by
GITOPS_PROPOSAL_ADAPTERS. Token values never appear here — only the
Secret-mounted file path and the optional host API root.
*/}}
{{- define "kubeseal-ui.gitopsProposalAdapters" -}}
{{- $entries := list -}}
{{- range .Values.api.gitops.proposalAdapters -}}
{{- $entry := printf "%s:%s:%s" .name .type .tokenFile -}}
{{- if .baseUrl -}}
{{- $entry = printf "%s:%s" $entry .baseUrl -}}
{{- end -}}
{{- $entries = append $entries $entry -}}
{{- end -}}
{{- join "," $entries -}}
{{- end -}}

{{/*
Resolve the Secret that holds the proposal adapter tokens: its own
proposalCredentialSecretName when set, otherwise the repository
credential Secret.
*/}}
{{- define "kubeseal-ui.gitopsProposalSecretName" -}}
{{- default .Values.api.gitops.credentialSecretName .Values.api.gitops.proposalCredentialSecretName -}}
{{- end -}}

{{/*
Fail the render when gitops is enabled without the pieces it needs:
at least one namespace mapping, credentials for every mapped authRef,
a configured adapter for every proposal namespace, a token file per
declared adapter, and a Secret to mount them from.
*/}}
{{- define "kubeseal-ui.gitops.validate" -}}
{{- if .Values.api.gitops.enabled -}}
{{- if not .Values.api.gitops.namespaces -}}
{{- fail "api.gitops.enabled requires api.gitops.namespaces" -}}
{{- end -}}
{{- $creds := dict -}}
{{- range .Values.api.gitops.credentials -}}
{{- $_ := set $creds .authRef . -}}
{{- if and (eq .mode "https-token") (not .tokenFile) -}}
{{- fail (printf "credential %s: https-token requires tokenFile" .authRef) -}}
{{- end -}}
{{- if and (ne .mode "https-token") (ne .mode "ssh-agent") (ne .mode "none") -}}
{{- fail (printf "credential %s: unknown mode %s" .authRef .mode) -}}
{{- end -}}
{{- end -}}
{{- $adapters := dict -}}
{{- range .Values.api.gitops.proposalAdapters -}}
{{- if not .name -}}
{{- fail "proposalAdapters entry requires name" -}}
{{- end -}}
{{- if hasKey $adapters .name -}}
{{- fail (printf "duplicate proposal adapter name %s" .name) -}}
{{- end -}}
{{- $_ := set $adapters .name . -}}
{{- if not (eq .type "github") -}}
{{- fail (printf "proposal adapter %s: type must be github, got %s" .name .type) -}}
{{- end -}}
{{- if not .tokenFile -}}
{{- fail (printf "proposal adapter %s: tokenFile is required" .name) -}}
{{- end -}}
{{- end -}}
{{- range .Values.api.gitops.namespaces -}}
{{- if not (hasKey $creds .authRef) -}}
{{- fail (printf "namespace %s: no credential for authRef %s" .namespace .authRef) -}}
{{- end -}}
{{- if and (ne .mode "direct") (ne .mode "proposal") -}}
{{- fail (printf "namespace %s: mode must be direct or proposal" .namespace) -}}
{{- end -}}
{{- if eq .mode "proposal" -}}
{{- if not (hasKey . "proposalAdapter") -}}
{{- fail (printf "namespace %s: proposal mode requires proposalAdapter" .namespace) -}}
{{- end -}}
{{- if not (hasKey $adapters .proposalAdapter) -}}
{{- fail (printf "namespace %s: proposalAdapter %s is not declared in api.gitops.proposalAdapters" .namespace .proposalAdapter) -}}
{{- end -}}
{{- else if .proposalAdapter -}}
{{- fail (printf "namespace %s: direct mode must not declare proposalAdapter" .namespace) -}}
{{- end -}}
{{- end -}}
{{- if not .Values.api.gitops.credentialSecretName -}}
{{- fail "api.gitops.enabled requires api.gitops.credentialSecretName" -}}
{{- end -}}
{{- if and .Values.api.gitops.proposalAdapters (not (include "kubeseal-ui.gitopsProposalSecretName" .)) -}}
{{- fail "api.gitops.proposalAdapters requires api.gitops.proposalCredentialSecretName (or credentialSecretName)" -}}
{{- end -}}
{{- end -}}
{{- end -}}
