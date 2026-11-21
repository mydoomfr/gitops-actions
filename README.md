# gitops-actions

[![ci](https://github.com/mydoomfr/gitops-actions/actions/workflows/ci.yaml/badge.svg)](https://github.com/mydoomfr/gitops-actions/actions/workflows/ci.yaml)
[![e2e](https://github.com/mydoomfr/gitops-actions/actions/workflows/e2e.yaml/badge.svg)](https://github.com/mydoomfr/gitops-actions/actions/workflows/e2e.yaml)
[![license](https://img.shields.io/github/license/mydoomfr/gitops-actions)](LICENSE)

**See what a [Flux](https://fluxcd.io) pull request really changes, before you merge it.**
Right in CI and fully standalone: no cluster, no kubeconfig, no agent to install.

GitHub Actions that comment on every pull request, Renovate ones included:

- 📦 **Flux diff**: the rendered manifests of every HelmRelease the pull request
  touches, old chart and values against new ones, plus what the git diff hides in
  Kustomizations (remote resources, other Flux sources, shared bases, CRDs).
- 🛡️ **CVE diff**: for every container image the pull request changes, the
  vulnerabilities of the old and new image side by side, then the High/Critical CVEs
  (configurable) of the new image, the ones it adds flagged 🆕, the ones it fixes. Scanned by [grype](https://github.com/anchore/grype).
- 🔐 **No secret needed**: SOPS-encrypted values and Secrets are rendered with
  placeholders, so CI never holds the private key.

Each comment is updated on every push. When there is nothing to report, a short comment
says so, so you know the check ran; set `comment-when-unchanged: false` to stay silent
instead (an existing comment is still refreshed).

> [!IMPORTANT]
> **Flux repositories only** for the Flux diff and the image discovery. Argo CD,
> Helmfile, plain Helm or Kustomize repositories are not supported. The CVE diff of an
> image built by the pull request works in any repository.

## Preview

Example: a pull request that upgrades the traefik chart (42.3.2 → 42.4.0) and its
image (v3.7.17 → v3.7.18, pinned by digest), enables its PodDisruptionBudget, and adds
a shared component (labels and resource limits) to the whoami Kustomization. That last change is two lines in the
pull request diff:

```diff
 resources:
   - deployment.yaml
+components:
+  - ../../components/common
```

and below, what it really changes once rendered.

<details open><summary><b>CVE diff</b></summary>

> ### Image CVEs (abcdef0)
>
> | Image | Version | Critical | High | Medium | Low | Fixable |
> |---|---|---|---|---|---|---|
> | `docker.io/traefik` | `v3.7.17@f4bb143` → `v3.7.18@9c437ac` | 0 | 2 → 1 ✅ | 4 | 1 | 2 → 1 ✅ |
>
> <details open><summary><code>docker.io/traefik</code>: 1 High/Critical, 1 fixable, 1 added, 2 fixed</summary>
>
> | CVE | Severity | Packages | Version | Fixed in |
> |---|---|---|---|---|
> | 🆕 CVE-0000-0004 | High | `golang.org/x/net` | `v0.47.0` | 0.48.0 |
>
> **Fixed**
>
> | CVE | Severity | Packages | Version | Fixed in |
> |---|---|---|---|---|
> | CVE-0000-0001 | High | `stdlib` | `go1.25.4` | 1.25.5 |
> | CVE-0000-0002 | High | `zlib` | `1.3.1-r2` | 1.3.2-r0 |
>
> </details>

</details>

<details open><summary><b>Flux diff</b></summary>

> ### Rendered Flux diff (abcdef0)
>
> #### HelmReleases
>
> | HelmRelease | Chart | Added | Changed | Removed |
> |---|---|--:|--:|--:|
> | `flux-system/traefik` | `traefik` 42.3.2 → 42.4.0 | 1 | 1 | |
>
> <details><summary><code>flux-system/traefik</code>: 1 added, 1 changed</summary>
>
> ```diff
> --- Deployment traefik/traefik
> +++ Deployment traefik/traefik
> @@ -9,3 +9,3 @@
>  spec:
> -  replicas: 1
> +  replicas: 2
>    revisionHistoryLimit: 10
> @@ -44,3 +44,5 @@
>              - --providers.kubernetesgateway.gatewayClass=traefik
> +            - --entryPoints.web.transport.lifeCycle.requestAcceptGraceTimeout=5s
>              - --entryPoints.websecure.http.tls=true
> +            - --entryPoints.websecure.transport.lifeCycle.requestAcceptGraceTimeout=5s
>              - --log.level=INFO
> @@ -63,4 +65,4 @@
>              - name: USER
>                value: traefik
> -          image: docker.io/traefik:v3.7.17@sha256:f4bb143d1135a579b630ed491e17ec50f6f7c9c6a30585ff3d385471d2a86f5a
> +          image: docker.io/traefik:v3.7.18@sha256:9c437ac4f09ce6f4980a8544902d3475fdf70a1a7c578729581d2535dfa7d635
>            imagePullPolicy: IfNotPresent
> --- PodDisruptionBudget traefik/traefik
> +++ PodDisruptionBudget traefik/traefik
> @@ -0,0 +1,11 @@
> +apiVersion: policy/v1
> +kind: PodDisruptionBudget
> +metadata:
> +  name: traefik
> +  namespace: traefik
> +spec:
> +  maxUnavailable: 1
> +  selector:
> +    matchLabels:
> +      app.kubernetes.io/name: traefik
> +      app.kubernetes.io/instance: traefik-traefik
> ```
>
> </details>
>
> #### Kustomizations
>
> | Kustomization | Why | Path | Added | Changed | Removed |
> |---|---|---|--:|--:|--:|
> | `flux-system/whoami` | kustomization edited | `apps/whoami` | | 1 | |
>
> <details open><summary><code>flux-system/whoami</code>: 1 changed</summary>
>
> ```diff
> --- Deployment whoami/whoami
> +++ Deployment whoami/whoami
> @@ -4,6 +4,7 @@
>    labels:
>      kustomize.toolkit.fluxcd.io/name: whoami
>      kustomize.toolkit.fluxcd.io/namespace: flux-system
> +    team: platform
>    name: whoami
>    namespace: whoami
>  spec:
> @@ -18,3 +19,6 @@
>        containers:
>          - image: docker.io/traefik/whoami:v1.10.4
>            name: whoami
> +          resources:
> +            limits:
> +              memory: 128Mi
> ```
>
> </details>
>
> _1 more Kustomization changed exactly as the pull request diff shows._
</details>

## Quick start: Flux repository

Copy [`examples/flux-pr.yaml`](examples/flux-pr.yaml) to `.github/workflows/`, then:

- set `path` to your cluster directory, the `--path` given to `flux bootstrap` (the one
  holding `flux-system/`, such as `clusters/my-cluster`);
- adapt its `on.pull_request.paths` to your repository layout;
- replace `<sha>` with the commit of a [release](https://github.com/mydoomfr/gitops-actions/releases)
  (a tag such as `@v1.4.0` works too; Renovate can pin it to its SHA).

Drop a job to turn its feature off:

```yaml
jobs:
  flux-diff:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      pull-requests: write
    steps:
      - uses: mydoomfr/gitops-actions/flux-setup@<sha> # v1.4.0
      - uses: mydoomfr/gitops-actions/flux-diff@<sha> # v1.4.0
        with:
          path: clusters/my-cluster

  image-scan: # read-only: the scanner pulls third-party images, see Security
    runs-on: ubuntu-latest
    permissions:
      contents: read
    steps:
      - uses: mydoomfr/gitops-actions/flux-setup@<sha> # v1.4.0
      - uses: mydoomfr/gitops-actions/flux-images@<sha> # v1.4.0
        id: images
        with:
          path: clusters/my-cluster
      - uses: mydoomfr/gitops-actions/cve-scan@<sha> # v1.4.0
        with:
          targets: ${{ steps.images.outputs.targets }}
          notes: ${{ steps.images.outputs.notes }}

  image-report:
    needs: image-scan
    runs-on: ubuntu-latest
    permissions:
      pull-requests: write
    steps:
      - uses: mydoomfr/gitops-actions/cve-report@<sha> # v1.4.0
```

## Quick start: any repository building images

Scan the image a pull request builds against the published one. One `cve-scan` job
per image, one `cve-report` job merging them into a single comment:

```yaml
  # The build job saves its image with `docker save -o image.tar` and uploads it with
  # actions/upload-artifact as `my-app-image`; labels and the published image are yours.
  cves:
    needs: build
    runs-on: ubuntu-latest
    permissions:
      contents: read
    steps:
      - uses: actions/download-artifact@<sha> # the image saved by the build job
        with:
          name: my-app-image
          path: ${{ runner.temp }}
      - uses: mydoomfr/gitops-actions/cve-scan@<sha> # v1.4.0
        with:
          name: my-app
          new-source: docker-archive:${{ runner.temp }}/image.tar
          new-label: 1.2.0
          old-source: registry:ghcr.io/me/my-app:1.1.0
          old-label: 1.1.0
          artifact-name: my-app-cves

  cve-comment:
    needs: cves
    runs-on: ubuntu-latest
    permissions:
      pull-requests: write
    steps:
      - uses: mydoomfr/gitops-actions/cve-report@<sha> # v1.4.0
        with:
          artifact-pattern: "*-cves"
          name-header: App
```

Sources are [grype sources](https://github.com/anchore/grype#supported-sources), such
as `registry:` or `docker-archive:`.

## Common settings

**Encrypted values.** Nothing to set up: `flux-setup` gives placeholders to the
SOPS-encrypted YAML files it finds. A Secret that only exists in the cluster needs
`allow-missing-kinds: Secret`. See [SOPS without the private key](docs/sops.md).

**Charts gated on a CRD API.** A `ServiceMonitor` or an `HTTPRoute` renders only when its
API is listed in the `api-versions` input of `flux-setup`. See
[Charts using CRDs](docs/flux-diff.md#charts-using-crds).

To choose which Kustomizations the comment lists, and more, see
[Flux diff in detail](docs/flux-diff.md) and the [inputs of every action](docs/inputs.md).

## Actions

| Action | What it does |
|---|---|
| [`flux-setup`](flux-setup/action.yml) | Checks out the pull request in `./pr` and its base in `./base`, and prepares SOPS files. Run it first. |
| [`flux-diff`](flux-diff/action.yml) | Comments the rendered HelmRelease and Kustomization diff. Needs `pull-requests: write`. |
| [`flux-images`](flux-images/action.yml) | Lists the images the pull request changes, each paired with the image it replaces. |
| [`cve-scan`](cve-scan/action.yml) | Scans each new image and the one it replaces, uploads the scans as an artifact. Run it read-only. |
| [`cve-report`](cve-report/action.yml) | Downloads the scans and comments the CVE report. Needs `pull-requests: write`. |
| [`pr-comment`](pr-comment/action.yml) | Creates or updates a comment tagged with a marker. Needs `pull-requests: write`. |
| [`helm-diff`](helm-diff/action.yml) | Former name of `flux-diff`, kept until v2. |

## Security

- **The scanner never holds a writable token**: `cve-scan` runs in a read-only job,
  `cve-report` posts from another.
- **No secret in CI**: SOPS values and Secrets are swapped for placeholders, never decrypted.
- **Pinned dependencies**: every third-party action is pinned by commit SHA; pin this
  repository the same way.

## Limits

- Runs on `pull_request` events only. Pull requests from forks get a read-only token,
  so no comment is posted on them.
- The render is offline: Helm `lookup` returns nothing.
- Private registries need credentials grype can read, such as a `docker login` in the
  scan job.
- More in [Flux diff](docs/flux-diff.md#limits) and [SOPS](docs/sops.md#limits).

Under the hood, the Flux render is done by
[flate](https://github.com/home-operations/flate), an offline Flux renderer. To
contribute, see [CONTRIBUTING.md](CONTRIBUTING.md).

## License

[MIT](LICENSE)
