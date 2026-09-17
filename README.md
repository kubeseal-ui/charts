# kubeseal-ui chart

Helm chart for kubeseal-ui: one API deployment (Go backend) and one UI deployment (nginx-served SPA), with
conditional controller-key RBAC, optional NetworkPolicy, and GitOps delivery configuration.

## Install

```bash
helm install kubeseal-ui . \
  --set api.env.OIDC_ISSUER=https://auth.example.com \
  --set api.env.OIDC_CLIENT_ID=kubeseal-ui \
  --set api.enableDecrypt=false
```

`api.image.tag` and `ui.image.tag` are empty by default, which resolves to `Chart.AppVersion`. That version is
`*-dev` and has no matching published image, so pin real tags (or digests) for every environment. API and UI
images release on independent cadences: pin them separately.

```yaml
api:
  image:
    tag: sha-48b2807     # or a digest
ui:
  image:
    tag: sha-88088d3
```

## Values that fail the render

The chart refuses to render a configuration it cannot serve, and CI (`scripts/validate.sh`) pins each case:

- `api.gitops.enabled` with no namespace mappings
- a namespace `authRef` with no matching credential entry
- `https-token` credentials with no `tokenFile`
- an unknown credential mode
- a namespace `mode` other than `direct` or `proposal`
- a `proposal` namespace with no `proposalAdapter`, or one that names an adapter absent from
  `api.gitops.proposalAdapters`
- a `direct` namespace that declares `proposalAdapter`
- a proposal adapter with an unknown `type`, a missing `tokenFile`, or a duplicate `name`
- `api.gitops.proposalAdapters` with no Secret to mount the token files from
- `api.gitops.enabled` with no `credentialSecretName`
- `networkPolicy.enabled` with no `networkPolicy.egress` destination

## GitOps values

```yaml
api:
  gitops:
    enabled: true
    authorName: kubeseal-ui
    authorEmail: kubeseal-ui@example.com
    worktreeDir: /tmp/kubeseal-ui/gitops
    credentials:
      - authRef: platform-repo
        mode: https-token            # https-token | ssh-agent | none
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
        baseUrl: https://github.example.com/api/v3   # GitHub Enterprise; omit for api.github.com
    credentialSecretName: kubeseal-ui-git
    proposalCredentialSecretName: kubeseal-ui-proposal
```

Token files are read on every call, so rotating the referenced Secrets needs no restart. Tokens never belong in
values; the chart only ever renders Secret-mounted file paths.

## NetworkPolicy

Disabled by default. When enabled, the chart requires explicit egress destinations because the Kubernetes API,
OIDC issuer, Git remotes, and proposal APIs are environment specific:

```yaml
networkPolicy:
  enabled: true
  dnsNamespace: kube-system
  api:
    ingress:
      - namespaceSelector:
          matchLabels:
            kubernetes.io/metadata.name: ingress-nginx
  egress:
    cidrs:
      - 10.43.0.1/32
    namespaceSelectors: []
```

DNS egress to `dnsNamespace` is always rendered. An empty `api.ingress` or `ui.ingress` renders a rule with no
sources, which admits every pod; set them to restrict traffic.

## Validate

```bash
helm lint .
helm template test-release . > /dev/null
bash scripts/validate.sh
```

`validate.sh` renders the default, GitOps, and NetworkPolicy fixtures, asserts the `GITOPS_*` env contract and
Secret mounts, and confirms the fail-closed cases above still fail.

## Documentation

- [Troubleshooting](https://github.com/kubeseal-ui/api/blob/main/docs/troubleshooting.md)
- [Proposal adapters](https://github.com/kubeseal-ui/api/blob/main/docs/proposal-adapters.md)
