{{/*
Base name helpers.
*/}}
{{- define "kubeseal-ui.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "kubeseal-ui.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default .Chart.Name .Values.nameOverride -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- define "kubeseal-ui.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* Names the API Deployment, ServiceAccount, and RBAC: "<fullname>-api". */}}
{{- define "kubeseal-ui.api.fullname" -}}
{{- printf "%s-api" (include "kubeseal-ui.fullname" .) -}}
{{- end -}}

{{/* The Service name is fixed by the UI image's proxy_pass; it does not track
     the release name. Override only with a rebuilt frontend image. */}}
{{- define "kubeseal-ui.api.serviceName" -}}
{{- default "kubeseal-ui-api" .Values.api.service.name -}}
{{- end -}}

{{- define "kubeseal-ui.api.serviceAccountName" -}}
{{- if .Values.api.serviceAccount.create -}}
{{- default (include "kubeseal-ui.api.fullname" .) .Values.api.serviceAccount.name -}}
{{- else -}}
{{- required "api.serviceAccount.name is required when api.serviceAccount.create is false" .Values.api.serviceAccount.name -}}
{{- end -}}
{{- end -}}

{{/*
Labels. Call with (dict "ctx" . "component" "api").
*/}}
{{- define "kubeseal-ui.labels" -}}
helm.sh/chart: {{ include "kubeseal-ui.chart" .ctx }}
{{ include "kubeseal-ui.selectorLabels" . }}
app.kubernetes.io/version: {{ .ctx.Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .ctx.Release.Service }}
{{- end -}}

{{- define "kubeseal-ui.selectorLabels" -}}
app.kubernetes.io/name: {{ include "kubeseal-ui.name" .ctx }}
app.kubernetes.io/instance: {{ .ctx.Release.Name }}
app.kubernetes.io/component: {{ .component }}
{{- end -}}

{{/*
Image reference. Empty tag resolves to appVersion; a sha256: tag is a digest.
Call with (dict "root" . "image" ...).
*/}}
{{- define "kubeseal-ui.image" -}}
{{- $tag := default .root.Chart.AppVersion .image.tag -}}
{{- if hasPrefix "sha256:" $tag -}}
{{- printf "%s@%s" .image.repository $tag -}}
{{- else -}}
{{- printf "%s:%s" .image.repository $tag -}}
{{- end -}}
{{- end -}}

{{/*
GITOPS_CREDENTIAL_REFS: auth_ref:mode:username:token_file entries.
*/}}
{{- define "kubeseal-ui.gitopsCredentialRefs" -}}
{{- $out := list -}}
{{- range .Values.api.gitops.credentials -}}
{{- $parts := list .authRef .mode (default "" .username) -}}
{{- if .tokenFile -}}
{{- $parts = append $parts .tokenFile -}}
{{- end -}}
{{- $out = append $out (join ":" $parts) -}}
{{- end -}}
{{- join "," $out -}}
{{- end -}}

{{/*
GITOPS_NAMESPACES: namespace:repository:branch:path_template:auth_ref:mode[:adapter][:allowed_paths]
*/}}
{{- define "kubeseal-ui.gitopsNamespaceSpecs" -}}
{{- $out := list -}}
{{- range .Values.api.gitops.namespaces -}}
{{- $parts := list .namespace .repository .branch .pathTemplate .authRef .mode -}}
{{- if eq .mode "proposal" -}}
{{- $parts = append $parts (default "" .proposalAdapter) -}}
{{- if .allowedPaths -}}
{{- $parts = append $parts (join ";" .allowedPaths) -}}
{{- else -}}
{{- $parts = append $parts "" -}}
{{- end -}}
{{- else -}}
{{- if .allowedPaths -}}
{{- $parts = append $parts (join ";" .allowedPaths) -}}
{{- end -}}
{{- end -}}
{{- $out = append $out (join ":" $parts) -}}
{{- end -}}
{{- join "," $out -}}
{{- end -}}

{{/*
GITOPS_PROPOSAL_ADAPTERS: name:type:token_file[:base_url].
*/}}
{{- define "kubeseal-ui.gitopsProposalAdapters" -}}
{{- $out := list -}}
{{- range .Values.api.gitops.proposalAdapters -}}
{{- $parts := list .name .type .tokenFile -}}
{{- if .baseUrl -}}
{{- $parts = append $parts .baseUrl -}}
{{- end -}}
{{- $out = append $out (join ":" $parts) -}}
{{- end -}}
{{- join "," $out -}}
{{- end -}}

{{/*
Fail-closed values validation. The api refuses a boot it cannot serve; the
chart refuses a render the api could not boot from, so a bad upgrade leaves
the previous release running.
*/}}
{{- define "kubeseal-ui.validate" -}}
{{- if kindIs "invalid" .Values.api.enableDecrypt -}}
{{- fail "api.enableDecrypt must be set explicitly to true or false" -}}
{{- end -}}
{{- $g := .Values.api.gitops -}}
{{- if $g.enabled -}}
{{- if not $g.namespaces -}}
{{- fail "api.gitops.enabled requires at least one api.gitops.namespaces entry" -}}
{{- end -}}
{{- if not $g.credentialSecretName -}}
{{- fail "api.gitops.enabled requires api.gitops.credentialSecretName" -}}
{{- end -}}
{{- if and $g.worktreeDir (not (hasPrefix .Values.api.worktree.mountPath $g.worktreeDir)) -}}
{{- fail (printf "api.gitops.worktreeDir %q must be inside api.worktree.mountPath %q" $g.worktreeDir .Values.api.worktree.mountPath) -}}
{{- end -}}
{{- $refs := dict -}}
{{- range $g.credentials -}}
{{- if not .authRef -}}
{{- fail "each api.gitops.credentials entry needs an authRef" -}}
{{- end -}}
{{- if not (has .mode (list "https-token" "ssh-agent" "none")) -}}
{{- fail (printf "credential %q: unknown mode %q (https-token, ssh-agent, none)" .authRef .mode) -}}
{{- end -}}
{{- if and (eq .mode "https-token") (not .tokenFile) -}}
{{- fail (printf "credential %q: https-token requires tokenFile" .authRef) -}}
{{- end -}}
{{- $_ := set $refs .authRef true -}}
{{- end -}}
{{- $adapters := dict -}}
{{- range $g.proposalAdapters -}}
{{- if not .name -}}
{{- fail "each api.gitops.proposalAdapters entry needs a name" -}}
{{- end -}}
{{- if hasKey $adapters .name -}}
{{- fail (printf "duplicate proposal adapter %q" .name) -}}
{{- end -}}
{{- $_ := set $adapters .name true -}}
{{- if ne .type "github" -}}
{{- fail (printf "proposal adapter %q: unknown type %q (github)" .name .type) -}}
{{- end -}}
{{- if not .tokenFile -}}
{{- fail (printf "proposal adapter %q requires tokenFile" .name) -}}
{{- end -}}
{{- end -}}
{{- if and $g.proposalAdapters (not (or $g.proposalCredentialSecretName $g.credentialSecretName)) -}}
{{- fail "proposal adapters require proposalCredentialSecretName or credentialSecretName" -}}
{{- end -}}
{{- range $g.namespaces -}}
{{- if not (has .mode (list "direct" "proposal")) -}}
{{- fail (printf "namespace %q: mode must be direct or proposal" .namespace) -}}
{{- end -}}
{{- if not (hasKey $refs .authRef) -}}
{{- fail (printf "namespace %q maps to undeclared credential %q" .namespace .authRef) -}}
{{- end -}}
{{- if eq .mode "proposal" -}}
{{- if not .proposalAdapter -}}
{{- fail (printf "namespace %q: proposal mode requires proposalAdapter" .namespace) -}}
{{- end -}}
{{- if not (hasKey $adapters .proposalAdapter) -}}
{{- fail (printf "namespace %q names undeclared adapter %q" .namespace .proposalAdapter) -}}
{{- end -}}
{{- else -}}
{{- if .proposalAdapter -}}
{{- fail (printf "namespace %q: direct mode must not set proposalAdapter" .namespace) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
