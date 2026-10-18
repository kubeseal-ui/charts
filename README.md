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

`/readyz` stays red until `SESSION_SIGNING_KEY` and the OIDC credentials are present. Keep secrets out of
values and pass them through `api.extraEnv` with `valueFrom.secretKeyRef`:

```yaml
api:
  extraEnv:
    - name: OIDC_CLIENT_SECRET
      valueFrom:
        secretKeyRef: { name: kubeseal-ui-oidc, key: client-secret }
    - name: SESSION_SIGNING_KEY
      valueFrom:
        secretKeyRef: { name: kubeseal-ui-oidc, key: session-signing-key }
```

## Values that fail the render

The chart refuses to render a configuration it cannot serve, and CI (`scripts/validate.sh`) pins each case:

- `api.enableDecrypt` absent (it has no default)
- `api.gitops.enabled` with no namespace mappings
- `api.gitops.worktreeDir` outside `api.worktree.mountPath` (the only writable directory)
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
helm lint . --set api.enableDecrypt=false
helm template test-release . --set api.enableDecrypt=false > /dev/null
bash scripts/validate.sh
```

`api.enableDecrypt` has no default on purpose, so every render passes it explicitly. `validate.sh` renders
the default, decrypt, GitOps, observability, and NetworkPolicy fixtures, asserts the rendered contract, and
confirms the fail-closed cases above still fail.

## Running deployment shape

The chart reproduces the hand-written manifest: release name `kubeseal-ui`, namespace `cluster`, API Service
`kubeseal-ui-api:8080`, UI Service `kubeseal-ui:80`. The API Service name is fixed at `kubeseal-ui-api` because
the UI image's nginx config proxies `/api` there; only `api.service.name` changes it, and only for a rebuilt
frontend image. Everything else follows the release name. To translate an existing manifest, map it as follows:

| Manifest field | Value |
| --- | --- |
| `kubectl create secret` referenced by `OIDC_CLIENT_SECRET` / `SESSION_SIGNING_KEY` | `api.extraEnv` entries with `valueFrom.secretKeyRef` |
| `CONFIG_PATH` + mounted ConfigMap `kubeseal-ui-authz` | `api.policy.existingConfigMap: kubeseal-ui-authz` |
| `GITOPS_*` vars | `api.gitops.*` (the chart derives the env strings) |
| Token Secrets mounted at `/var/run/secrets/git/...` | `api.gitops.credentialSecretName` / `proposalCredentialSecretName`; mount paths come from each `tokenFile` directory |
| Controller-key Role in namespace `cluster` | `api.enableDecrypt: true` (renders Role/RoleBinding in `api.controllerNamespace`) |
| Worktree emptyDir at `/tmp/kubeseal-ui` | `api.worktree.mountPath` (always rendered) |

The UI image's nginx listens on port 80 and runs as the chart's non-root UID. That only works when the node
allows unprivileged low ports (k3s does by default via `net.ipv4.ip_unprivileged_port_start=0`); on stock
Kubernetes, rebuild the frontend with a listening port above 1024 and set `ui.service.port` to match.

## Documentation

- [Troubleshooting](https://github.com/kubeseal-ui/api/blob/main/docs/troubleshooting.md)
- [Proposal adapters](https://github.com/kubeseal-ui/api/blob/main/docs/proposal-adapters.md)
