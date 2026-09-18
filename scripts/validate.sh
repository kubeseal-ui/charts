#!/usr/bin/env bash
#
# Validate that the rendered kubeseal-ui chart produces the expected
# resource kinds and surfaces the kubeseal-ui/api + kubeseal-ui/frontend
# images in the API + UI deployments. Mirrors the validate.sh contract
# from pamawas-infra per the ci-cd-advanced-patterns skill.
set -euo pipefail

CHART_DIR="${CHART_DIR:-.}"
RENDERED="$(mktemp)"
trap 'rm -f "${RENDERED}"' EXIT

# Render the chart with default values plus the release name the CI uses.
helm template test-release "${CHART_DIR}" > "${RENDERED}"

# Debug aid (visible in the job log when running locally).
printf 'Rendered resource kinds:\n' >&2
grep '^kind:' "${RENDERED}" | sort | uniq -c >&2

assert_rendered() {
    local pattern="$1"
    local description="$2"
    if ! grep -Eq "${pattern}" "${RENDERED}"; then
        printf 'error: rendered chart missing %s\n' "${description}" >&2
        printf 'Searching for pattern: %s\n' "${pattern}" >&2
        exit 1
    fi
}

# Core resource kinds (the chart MVP contract is one Deployment + one
# Service per component; 2 of each = 4 resources).
assert_rendered '^kind: Deployment$' 'at least one Deployment'
assert_rendered '^kind: Service$' 'at least one Service'

# API + UI components are both rendered.
assert_rendered 'app.kubernetes.io/component: api' 'api component label'
assert_rendered 'app.kubernetes.io/component: ui' 'ui component label'

# Image references resolve to the kubeseal-ui ghcr.io repositories. This
# pins the image-naming convention used by the api + frontend CI flows.
assert_rendered 'image: "ghcr.io/kubeseal-ui/api:' 'api image from ghcr.io/kubeseal-ui/api'
assert_rendered 'image: "ghcr.io/kubeseal-ui/frontend:' 'frontend image from ghcr.io/kubeseal-ui/frontend'

# Security baseline: every container must run as non-root with read-only
# root filesystem. This catches regressions where someone loosens the
# podSecurityContext defaults in values.yaml.
assert_rendered 'runAsNonRoot: true' 'runAsNonRoot: true on at least one container'
assert_rendered 'readOnlyRootFilesystem: true' 'readOnlyRootFilesystem: true on at least one container'
assert_rendered 'seccompProfile:' 'seccompProfile set on the pod spec'

# Health probes are wired so kubelet can route traffic only to ready
# replicas.
assert_rendered 'livenessProbe:' 'liveness probe on at least one container'
assert_rendered 'readinessProbe:' 'readiness probe on at least one container'

# App version label surfaces the kubeseal-ui release version so operators
# can confirm which release is running via kubectl.
assert_rendered 'app.kubernetes.io/version' 'app.kubernetes.io/version label'

printf 'validate.sh: rendered contract checks passed\n'

# --- GitOps delivery fixtures -------------------------------------------
# Direct + proposal namespace mapping, typed credentials, and a github-pr
# proposal adapter. Pins the GITOPS_* env contract and the Secret mounts
# that carry the token files.

GITOPS_VALUES="$(mktemp)"
NETPOL_VALUES="$(mktemp)"
BAD_ADAPTER_VALUES="$(mktemp)"
BAD_NETPOL_VALUES="$(mktemp)"
trap 'rm -f "${RENDERED}" "${GITOPS_VALUES}" "${NETPOL_VALUES}" "${BAD_ADAPTER_VALUES}" "${BAD_NETPOL_VALUES}"' EXIT

cat > "${GITOPS_VALUES}" <<'EOF'
api:
  env:
    OIDC_ISSUER: https://auth.example.com
    OIDC_CLIENT_ID: kubeseal-ui
  enableDecrypt: false
  gitops:
    enabled: true
    authorName: kubeseal-ui
    authorEmail: kubeseal-ui@example.com
    credentials:
      - authRef: platform-repo
        mode: https-token
        username: kubeseal-ui
        tokenFile: /var/run/secrets/git/platform/token
    namespaces:
      - namespace: payments
        repository: org/platform-repo
        branch: main
        pathTemplate: clusters/{namespace}/{name}.yaml
        authRef: platform-repo
        mode: direct
      - namespace: staging
        repository: org/platform-repo
        branch: main
        pathTemplate: clusters/{namespace}/{name}.yaml
        authRef: platform-repo
        mode: proposal
        proposalAdapter: github-pr
    proposalAdapters:
      - name: github-pr
        type: github
        tokenFile: /var/run/secrets/git/proposal/token
        baseUrl: https://github.example.com/api/v3
    credentialSecretName: kubeseal-ui-git
    proposalCredentialSecretName: kubeseal-ui-proposal
EOF

GITOPS_RENDERED="$(mktemp)"
helm template test-release "${CHART_DIR}" -f "${GITOPS_VALUES}" > "${GITOPS_RENDERED}"

assert_gitops_rendered() {
    local pattern="$1"
    local description="$2"
    if ! grep -Fq "${pattern}" "${GITOPS_RENDERED}"; then
        printf 'error: gitops render missing %s\n' "${description}" >&2
        printf 'Searching for: %s\n' "${pattern}" >&2
        exit 1
    fi
}

assert_gitops_rendered 'name: GITOPS_NAMESPACES' 'GITOPS_NAMESPACES env'
assert_gitops_rendered 'payments:org/platform-repo:main:clusters-{namespace}-{name}.yaml:platform-repo:direct' 'direct namespace mapping'
assert_gitops_rendered 'staging:org/platform-repo:main:clusters-{namespace}-{name}.yaml:platform-repo:proposal:github-pr' 'proposal namespace mapping with adapter name'
assert_gitops_rendered 'github-pr:github:/var/run/secrets/git/proposal/token:https://github.example.com/api/v3' 'proposal adapter spec'
assert_gitops_rendered 'secretName: kubeseal-ui-proposal' 'proposal credential Secret volume'
assert_gitops_rendered 'mountPath: /var/run/secrets/git/proposal' 'proposal token mount path'
assert_gitops_rendered 'name: GITOPS_CREDENTIAL_REFS' 'GITOPS_CREDENTIAL_REFS env'

# A proposal namespace that names an adapter the values never declare must
# fail the render rather than booting an API that cannot open proposals.
printf '%s\n' "api:" "  gitops:" "    enabled: true" \
    "    credentials:" "      - authRef: platform-repo" \
    "        mode: https-token" "        username: kubeseal-ui" \
    "        tokenFile: /var/run/secrets/git/platform/token" \
    "    namespaces:" "      - namespace: staging" "        repository: org/platform-repo" \
    "        branch: main" "        pathTemplate: clusters/{namespace}/{name}.yaml" \
    "        authRef: platform-repo" "        mode: proposal" \
    "        proposalAdapter: github-pr" \
    "    credentialSecretName: kubeseal-ui-git" > "${BAD_ADAPTER_VALUES}"
if helm template test-release "${CHART_DIR}" -f "${BAD_ADAPTER_VALUES}" > /dev/null 2>&1; then
    printf 'error: render succeeded with an undeclared proposal adapter\n' >&2
    exit 1
fi

# --- NetworkPolicy fixture ----------------------------------------------
cat > "${NETPOL_VALUES}" <<'EOF'
networkPolicy:
  enabled: true
  egress:
    cidrs:
      - 10.43.0.1/32
    namespaceSelectors:
      - matchLabels:
          kubernetes.io/metadata.name: git-system
  api:
    ingress:
      - namespaceSelector:
          matchLabels:
            kubernetes.io/metadata.name: ingress-nginx
EOF

NETPOL_RENDERED="$(mktemp)"
trap 'rm -f "${RENDERED}" "${GITOPS_VALUES}" "${NETPOL_VALUES}" "${BAD_ADAPTER_VALUES}" "${BAD_NETPOL_VALUES}" "${GITOPS_RENDERED}" "${NETPOL_RENDERED}"' EXIT
helm template test-release "${CHART_DIR}" -f "${NETPOL_VALUES}" > "${NETPOL_RENDERED}"

assert_netpol_rendered() {
    local pattern="$1"
    local description="$2"
    if ! grep -Fq "${pattern}" "${NETPOL_RENDERED}"; then
        printf 'error: networkpolicy render missing %s\n' "${description}" >&2
        printf 'Searching for: %s\n' "${pattern}" >&2
        exit 1
    fi
}

netpol_count="$(grep -c '^kind: NetworkPolicy$' "${NETPOL_RENDERED}" || true)"
if [ "${netpol_count}" != "2" ]; then
    printf 'error: expected 2 NetworkPolicy resources, found %s\n' "${netpol_count}" >&2
    exit 1
fi
assert_netpol_rendered 'kubernetes.io/metadata.name: kube-system' 'DNS egress to the cluster DNS namespace'
assert_netpol_rendered 'cidr: 10.43.0.1/32' 'operator-supplied egress CIDR'
assert_netpol_rendered 'kubernetes.io/metadata.name: git-system' 'operator-supplied egress namespace selector'
assert_netpol_rendered 'kubernetes.io/metadata.name: ingress-nginx' 'operator-supplied API ingress source'

# The policy refuses to guess egress destinations; enabling it with none is
# a configuration error, not a permissive default.
printf '%s\n' "networkPolicy:" "  enabled: true" > "${BAD_NETPOL_VALUES}"
if helm template test-release "${CHART_DIR}" -f "${BAD_NETPOL_VALUES}" > /dev/null 2>&1; then
    printf 'error: render succeeded with networkPolicy enabled and no egress destinations\n' >&2
    exit 1
fi

printf 'validate.sh: gitops and networkpolicy render checks passed\n'

# --- Observability fixture ----------------------------------------------
# ServiceMonitor + PrometheusRule render, the OTEL_* env contract, and the
# metrics endpoint path. The /metrics exposition carries bounded labels
# only, so it is safe to scrape unauthenticated.

OBS_VALUES="$(mktemp)"
OBS_RENDERED="$(mktemp)"
trap 'rm -f "${RENDERED}" "${GITOPS_VALUES}" "${NETPOL_VALUES}" "${BAD_ADAPTER_VALUES}" "${BAD_NETPOL_VALUES}" "${GITOPS_RENDERED}" "${NETPOL_RENDERED}" "${OBS_VALUES}" "${OBS_RENDERED}"' EXIT

cat > "${OBS_VALUES}" <<'EOF'
observability:
  serviceMonitor:
    enabled: true
    selector:
      release: prometheus
    interval: 30s
    scrapeTimeout: 10s
  prometheusRule:
    enabled: true
    selector:
      release: prometheus
  otlpEndpoint: http://otel-collector.observability.svc:4317
  traceSampleRatio: "0.25"
  metricIntervalSeconds: "15"
EOF

helm template test-release "${CHART_DIR}" -f "${OBS_VALUES}" > "${OBS_RENDERED}"

assert_obs_rendered() {
    local pattern="$1"
    local description="$2"
    if ! grep -Fq "${pattern}" "${OBS_RENDERED}"; then
        printf 'error: observability render missing %s\n' "${description}" >&2
        printf 'Searching for: %s\n' "${pattern}" >&2
        exit 1
    fi
}

obs_kinds="$(grep -c '^kind: ServiceMonitor$\|^kind: PrometheusRule$' "${OBS_RENDERED}" || true)"
if [ "${obs_kinds}" != "2" ]; then
    printf 'error: expected 1 ServiceMonitor + 1 PrometheusRule, found %s\n' "${obs_kinds}" >&2
    exit 1
fi
assert_obs_rendered 'release: prometheus' 'operator selector label'
assert_obs_rendered 'path: /metrics' 'metrics scrape path'
assert_obs_rendered 'KubesealUIHighErrorRate' 'high error rate alert'
assert_obs_rendered 'KubesealUIHighLatency' 'high latency alert'
assert_obs_rendered 'KubesealUIGitOpsPushFailing' 'gitops push failing alert'
assert_obs_rendered 'KubesealUICryptoFailures' 'crypto failures alert'
assert_obs_rendered 'name: OTEL_EXPORTER_OTLP_ENDPOINT' 'OTLP endpoint env'
assert_obs_rendered 'otel-collector.observability.svc:4317' 'collector endpoint with scheme stripped'
assert_obs_rendered 'name: OTEL_TRACE_SAMPLE_RATIO' 'trace sampling env'
assert_obs_rendered 'name: OTEL_METRIC_INTERVAL_SECONDS' 'metric interval env'
assert_obs_rendered 'name: OTEL_SERVICE_NAME' 'service name env'
assert_obs_rendered 'name: OTEL_SERVICE_VERSION' 'service version env'
assert_obs_rendered 'name: OTEL_DEPLOYMENT_ENVIRONMENT' 'deployment environment env'

# Without an endpoint the SDK must stay disabled: /metrics returns 503 and
# the OTEL env vars render empty.
DEFAULT_OTEL="$(grep -A1 'name: OTEL_EXPORTER_OTLP_ENDPOINT' "${RENDERED}" | tail -1)"
if ! printf '%s' "${DEFAULT_OTEL}" | grep -Fq '""'; then
    printf 'error: default render sets a non-empty OTEL endpoint\n' >&2
    exit 1
fi

printf 'validate.sh: observability render checks passed\n'
