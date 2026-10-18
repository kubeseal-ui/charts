#!/usr/bin/env bash
# Renders the chart's contract: defaults, decrypt, GitOps, observability,
# NetworkPolicy, and the fail-closed cases the chart must refuse.
set -euo pipefail
cd "$(dirname "$0")/.."

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

helm lint . --set api.enableDecrypt=false >/dev/null

render() { helm template test-release . "$@"; }
fail_case() {
  local name="$1"; shift
  if "$@" >/dev/null 2>&1; then
    echo "FAIL: expected $name to be refused" >&2
    exit 1
  fi
}
expect() {
  grep -q -- "$1" "$2" || { echo "FAIL: missing $1 in $2" >&2; exit 1; }
}
expect_count() {
  local want="$1" pattern="$2" file="$3"
  local got
  got="$(grep -c -- "$pattern" "$file" || true)"
  [ "$got" = "$want" ] || { echo "FAIL: expected $want x '$pattern' in $file, got $got" >&2; exit 1; }
}

# --- defaults -------------------------------------------------------------
render --set api.enableDecrypt=false > "$tmp/defaults.yaml"
expect_count 2 "^kind: Deployment$" "$tmp/defaults.yaml"
expect_count 2 "^kind: Service$" "$tmp/defaults.yaml"
expect "^kind: ServiceAccount$" "$tmp/defaults.yaml"
expect "^kind: ClusterRole$" "$tmp/defaults.yaml"
expect "^kind: ClusterRoleBinding$" "$tmp/defaults.yaml"
expect "ghcr.io/kubeseal-ui/api:" "$tmp/defaults.yaml"
expect "ghcr.io/kubeseal-ui/frontend:" "$tmp/defaults.yaml"
# The UI image's nginx proxies /api to this fixed name, independent of the release.
expect_count 1 "^  name: kubeseal-ui-api$" "$tmp/defaults.yaml"
expect "^  name: test-release-kubeseal-ui$" "$tmp/defaults.yaml"
expect "readOnlyRootFilesystem: true" "$tmp/defaults.yaml"
expect "runAsNonRoot: true" "$tmp/defaults.yaml"
expect "type: RuntimeDefault" "$tmp/defaults.yaml"
expect "path: /healthz" "$tmp/defaults.yaml"
expect "path: /readyz" "$tmp/defaults.yaml"
grep -A1 -- '- name: ENABLE_DECRYPT' "$tmp/defaults.yaml" | grep -q 'value: "false"' \
  || { echo "FAIL: ENABLE_DECRYPT not false in defaults" >&2; exit 1; }
if grep -q "controller-key" "$tmp/defaults.yaml"; then
  echo "FAIL: controller-key RBAC rendered with decrypt disabled" >&2
  exit 1
fi
if grep -q "GITOPS_ENABLED" "$tmp/defaults.yaml"; then
  echo "FAIL: GitOps env rendered while disabled" >&2
  exit 1
fi
if grep -q "OTEL_EXPORTER_OTLP_ENDPOINT" "$tmp/defaults.yaml"; then
  echo "FAIL: OTEL endpoint rendered while unset" >&2
  exit 1
fi

# --- decrypt --------------------------------------------------------------
render --set api.enableDecrypt=true > "$tmp/decrypt.yaml"
expect "^kind: Role$" "$tmp/decrypt.yaml"
expect "name: test-release-kubeseal-ui-api-controller-key" "$tmp/decrypt.yaml"
grep -A1 -- '- name: ENABLE_DECRYPT' "$tmp/decrypt.yaml" | grep -q 'value: "true"' \
  || { echo "FAIL: ENABLE_DECRYPT not true in decrypt fixture" >&2; exit 1; }

# --- GitOps ---------------------------------------------------------------
render -f ci/values-gitops.yaml > "$tmp/gitops.yaml"
grep -A1 -- '- name: GITOPS_ENABLED' "$tmp/gitops.yaml" | grep -q 'value: "true"' \
  || { echo "FAIL: GITOPS_ENABLED not true in GitOps fixture" >&2; exit 1; }
expect "platform-repo:https-token:kubeseal-ui:/var/run/secrets/git/platform/token" "$tmp/gitops.yaml"
expect "payments:example/config:main:cluster/sealed-secret/{namespace}/{name}.yaml:platform-repo:direct" "$tmp/gitops.yaml"
expect "development:example/config:main:cluster/sealed-secret/{namespace}/{name}.yaml:platform-repo:proposal:github-main:cluster" "$tmp/gitops.yaml"
expect "github-main:github:/var/run/secrets/git/proposal/token:https://git.example.com/api/v3" "$tmp/gitops.yaml"
expect "mountPath: /var/run/secrets/git/platform" "$tmp/gitops.yaml"
expect "mountPath: /var/run/secrets/git/proposal" "$tmp/gitops.yaml"
expect "secretName: kubeseal-ui-git" "$tmp/gitops.yaml"
expect "secretName: kubeseal-ui-proposal" "$tmp/gitops.yaml"

# --- observability --------------------------------------------------------
render -f ci/values-observability.yaml > "$tmp/observability.yaml"
expect "^kind: ServiceMonitor$" "$tmp/observability.yaml"
expect "^kind: PrometheusRule$" "$tmp/observability.yaml"
expect_count 2 "release: prometheus" "$tmp/observability.yaml"
for alert in KubesealUIHighErrorRate KubesealUIHighLatency KubesealUIGitOpsPushFailing KubesealUICryptoFailures; do
  expect "alert: $alert" "$tmp/observability.yaml"
done
grep -A1 -- '- name: OTEL_EXPORTER_OTLP_ENDPOINT' "$tmp/observability.yaml" \
  | grep -q 'value: "otel-collector.observability.svc:4317"' \
  || { echo "FAIL: OTLP endpoint not scheme-stripped" >&2; exit 1; }
grep -A1 -- '- name: OTEL_TRACE_SAMPLE_RATIO' "$tmp/observability.yaml" | grep -q 'value: "0.25"' \
  || { echo "FAIL: OTEL_TRACE_SAMPLE_RATIO not rendered" >&2; exit 1; }
grep -A1 -- '- name: OTEL_METRIC_INTERVAL_SECONDS' "$tmp/observability.yaml" | grep -q 'value: "15"' \
  || { echo "FAIL: OTEL_METRIC_INTERVAL_SECONDS not rendered" >&2; exit 1; }

# --- NetworkPolicy --------------------------------------------------------
render -f ci/values-networkpolicy.yaml > "$tmp/np.yaml"
expect_count 2 "^kind: NetworkPolicy$" "$tmp/np.yaml"
expect "kubernetes.io/metadata.name: kube-system" "$tmp/np.yaml"
expect "cidr: 10.43.0.1/32" "$tmp/np.yaml"
expect "cidr: 10.43.0.20/32" "$tmp/np.yaml"
expect "port: 4317" "$tmp/np.yaml"
expect "kubernetes.io/metadata.name: ingress-nginx" "$tmp/np.yaml"
expect "OTEL_EXPORTER_OTLP_ENDPOINT" "$tmp/np.yaml"

# --- fail-closed ----------------------------------------------------------
fail_case "missing api.enableDecrypt" helm template test-release .
fail_case "GitOps without namespace mappings" helm template test-release . \
  --set api.enableDecrypt=false --set api.gitops.enabled=true \
  --set api.gitops.credentialSecretName=x
fail_case "NetworkPolicy without egress destinations" helm template test-release . \
  --set api.enableDecrypt=false --set networkPolicy.enabled=true

sed 's/proposalAdapter: github-main/proposalAdapter: undeclared/' \
  ci/values-gitops.yaml > "$tmp/bad-adapter.yaml"
fail_case "undeclared proposal adapter" helm template test-release . -f "$tmp/bad-adapter.yaml"

grep -v 'tokenFile: /var/run/secrets/git/platform/token' ci/values-gitops.yaml > "$tmp/bad-token.yaml"
fail_case "https-token without tokenFile" helm template test-release . -f "$tmp/bad-token.yaml"

fail_case "GitOps worktreeDir outside the writable mount" helm template test-release . \
  -f ci/values-gitops.yaml --set api.worktree.mountPath=/tmp/elsewhere

echo "chart contract checks passed"
