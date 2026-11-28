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
`Secret` and `CustomResourceDefinition` objects are left out by default (the
`helmrelease-skip-kinds` input), see [Charts using CRDs](#charts-using-crds).

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

## Changes that fail the reconciliation

Some changes read like any other diff but cannot be applied: the API server refuses them,
and the reconciliation fails until the object is deleted and recreated. They are listed
at the top of the comment, and as annotations on the run:

| Rule | Change |
|---|---|
| `immutable-field` | A StatefulSet `spec` field other than `replicas`, `template`, `updateStrategy`, `revisionHistoryLimit`, `persistentVolumeClaimRetentionPolicy`, `minReadySeconds` and `ordinals`, such as `volumeClaimTemplates` |
| | The `selector` of a Deployment, DaemonSet or ReplicaSet |
| | The `selector` or `template` of a Job, except a Helm hook, which Helm recreates |
| | A PersistentVolumeClaim `spec` field other than `resources` and `volumeAttributesClassName`, such as `storageClassName`; a first `volumeName` binds the claim and is allowed |
| | The `roleRef` of a RoleBinding or ClusterRoleBinding |
| | The `clusterIP` of a Service, when both sides set one |
| `pvc-shrink` | A lower storage request on a PersistentVolumeClaim |

The rules apply to the Kubernetes API groups only (`apps`, `batch`, core,
`rbac.authorization.k8s.io`): a custom resource reusing a kind name, such as an OpenKruise
StatefulSet, is not checked. Set `lint: false` to turn the warnings off.

The changes of the Kustomizations the comment leaves out are checked too, except with
`kustomizations: none`, which skips the Kustomization render altogether. A producer that
failed to render is not checked: its objects are left out of the diff, as the comment
warns. A warning names the producer, and its cluster when flate reports one.

Some warnings carry a note:

- an object with the `kustomize.toolkit.fluxcd.io/force: enabled` annotation, under a
  Kustomization, is recreated by Flux; recreating a PersistentVolumeClaim can delete its
  data, and recreating a StatefulSet with `whenDeleted: Delete` deletes its claims;
- a Job whose version in the cluster sets `ttlSecondsAfterFinished` fails until it
  finishes and its TTL expires: Flux then creates the new one.

The Kustomization-wide `spec.force` is not read. Labels that flate leaves out of the
diff, such as `helm.sh/chart` in `volumeClaimTemplates`, are not compared either: a
chart bump that only changes them there is not flagged.

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
  request's change, when its URL names the same repository as the `origin` remote that
  `actions/checkout` sets (`https://` or `ssh://git@`, with or without `.git`). Pinned to a
  tag or a commit, it is fetched as such.
- A chart stored in the repository is built with its `file://` dependencies, so a change
  to a subchart shows in the HelmRelease diff.
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
left out of the HelmRelease diff by default. To review them too, summarized the same way,
keep only `Secret` in `helmrelease-skip-kinds` (this replaces the former job-level
`FLATE_SKIP_KINDS` setting, still honored while the input keeps its default):

```yaml
- uses: mydoomfr/gitops-actions/flux-diff@<sha> # v1.4.0
  with:
    path: clusters/my-cluster
    helmrelease-skip-kinds: Secret
```

## Limits

- The render is offline: Helm `lookup` returns nothing, and the cluster capabilities are
  the default Kubernetes version of the [flate](https://github.com/home-operations/flate)
  release pinned in `flux-setup`, plus the `api-versions` input.
- Whether the git diff shows a Kustomization change is inferred from the files the pull
  request changes: an edited manifest under a Kustomization's path counts as shown,
  even when the same pull request also changes a shared base it uses.
- A Kustomization reading another `GitRepository` whose path also exists in this
  repository is listed as `shared`, `edited` or counted, not as `source`.
- Images are read from `image` and `imageName` fields. A custom resource that splits
  an image into `repository` and `tag` fields is not scanned.
