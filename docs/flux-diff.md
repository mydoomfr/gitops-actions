# Flux diff in detail

How `flux-diff` builds its comment, and how to tune it. Back to the [README](../README.md).

## A diff of what your cluster will run

A chart bump is reviewed by the manifests **your values** produce, not by the chart's
changelog or templates. Each HelmRelease is rendered twice, as Flux's helm-controller
would, with the chart, the inline values and the `valuesFrom` of each side, then the
resulting objects are diffed:

- If your values set `grafana.enabled: false` and the new chart version rewrites its Grafana
  templates, the diff stays empty: nothing changes in your cluster.
- A new chart default you don't override shows up; one you override doesn't.
- A values-only change, with no chart bump, is rendered the same way.

Labels and annotations that change with every chart version (`helm.sh/chart`,
`app.kubernetes.io/version`, `checksum/*`) are ignored as noise. In HelmReleases,
`Secret` and `CustomResourceDefinition` objects are left out by default, see
[Charts using CRDs](#charts-using-crds).

## What the git diff hides in Kustomizations

The pull request diff already shows a manifest edited in place, so the Kustomization
diff only lists the Kustomizations whose change it does not show, and says why:

| Reason | Example | The git diff shows |
|---|---|---|
| `remote` | `resources: [https://…/releases/download/v1.7.0/experimental-install.yaml]`, a `github.com/…//dir?ref=` base | one URL line |
| `source` | a Kustomization reading another `GitRepository`, `OCIRepository`, `Bucket` or an `ArtifactGenerator` output | one commit or tag line |
| `shared` | a `../common` base, a component or a `postBuild.substituteFrom` variable used by several Kustomizations | the shared file only |
| `edited` | a `kustomization.yaml` that adds a component or a patch, renames or relabels | the reference, not its effect |

A Kustomization reads `source` when its `sourceRef` is an `ExternalArtifact` (the output
of an `ArtifactGenerator`), an `OCIRepository` or `Bucket` declared in the repository, or
when its path is missing from the repository, such as one in another `GitRepository`.

Every other changed Kustomization (an edited manifest, an `images:` tag bump in a
`kustomization.yaml`) is `direct`: the git diff shows its change, so it is only counted
and on its own never opens a comment. A Renovate image or chart bump stays as quiet as
before.

Pick the reasons with the `kustomizations` input:

```yaml
- uses: mydoomfr/gitops-actions/flux-diff@<sha> # v1.4.0
  with:
    path: clusters/my-cluster
    kustomizations: remote,source # auto (default: remote,source,shared,edited), all, none, or a list with direct
    kustomization-skip-kinds: Secret # the default: CRDs are listed, Secrets left out
```

In the sections listed:

- **CRDs are summarized**, not diffed: served versions and the fields each version adds
  or removes. Their raw diff, often hundreds of kilobytes, goes to the run summary only.
- **Secret values are never shown.** Secrets are left out by default, and when included,
  each key only reads `<redacted>` or `<redacted, changed>`.
- **No duplicates:** the values ConfigMaps and Secrets of a changed HelmRelease are left
  out, their effect is in its rendered diff. The HelmRelease object itself stays, for
  changes no render shows, such as `interval` or `driftDetection`.

## Flux sources

- A source that a Kustomization reads and that nothing in the repository declares or
  produces, whatever its kind, is read from the pull request and base trees: committing
  the `flux-system` `GitRepository` is not required, nor a Flux Operator `FluxInstance`
  that lives only in the cluster. The chart source of a HelmRelease must still be
  declared.
- A source produced by an object the repository declares, such as the `OCIRepository`
  of a `FluxInstance` sync committed here, cannot be fetched offline: its Kustomizations
  fail to render and the comment says so.
- A second `GitRepository` pointing at this repository with only a `branch` shows the pull
  request's change. Pinned to a tag or a commit, it is fetched as such.
- `GitRepository` `spec.include` is applied, and `valuesFrom` entries with a `targetPath`
  are merged with `spec.values` in helm-controller's order.

## Charts using CRDs

Many charts render an object only when the cluster serves its API, such as
`{{ if .Capabilities.APIVersions.Has "monitoring.coreos.com/v1" }}` around a
`ServiceMonitor`. There is no cluster here, so only the APIs listed in the
`api-versions` input of `flux-setup` are known. If an API is missing, its objects
silently drop out of the render.

The default covers Prometheus Operator, Gateway API, cert-manager and VolumeSnapshot.
The input **replaces** that list, so repeat the defaults when you add an API:

```yaml
- uses: mydoomfr/gitops-actions/flux-setup@<sha> # v1.4.0
  with:
    api-versions: >-
      monitoring.coreos.com/v1 monitoring.coreos.com/v1alpha1
      gateway.networking.k8s.io/v1 cert-manager.io/v1 snapshot.storage.k8s.io/v1
      external-secrets.io/v1
```

The CRDs a Kustomization applies are in its diff, summarized. Those a chart ships are
left out of the HelmRelease diff. To review them too, an advanced setting overrides the
kinds the renderer leaves out, at the job level: keep only `Secret` (the Kustomization
diff follows the `kustomization-skip-kinds` input instead):

```yaml
  flux-diff:
    env:
      FLATE_SKIP_KINDS: Secret
```

## Limits

- The render is offline: Helm `lookup` returns nothing, and the cluster capabilities are
  the default Kubernetes version of the [flate](https://github.com/home-operations/flate)
  release pinned in `flux-setup`, plus the `api-versions` input.
- Whether the git diff shows a Kustomization change is inferred from the files the pull
  request changes: an edited manifest under a Kustomization's path counts as shown,
  even when the same pull request also changes a shared base it uses.
- A Kustomization reading another `GitRepository` whose path also exists in this
  repository is listed as `shared`, `edited` or counted, not as `source`. Sources are
  looked up in the whole repository: in a repository with several clusters, a source one
  cluster declares counts as declared for the others too.
- Images are read from `image` and `imageName` fields. A custom resource that splits
  an image into `repository` and `tag` fields is not scanned.
