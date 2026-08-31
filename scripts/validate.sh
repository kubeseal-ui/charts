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
