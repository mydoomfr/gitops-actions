# What the lint relies on

Each behavior `lib/flux-lint.jq` assumes, checked in the upstream source. Write the row,
with its source, before the rule. Every case of [cases.yaml](cases.yaml) names the rows
it checks in `refs`, and `tests/run.sh` fails when a row has no case.

Read at Kubernetes v1.37.3, kustomize-controller v1.10.2 (fluxcd/pkg ssa v0.83.0),
helm-controller v1.7.2 and Helm v4.3.2.

## Kubernetes

| Id | Behavior | In the lint | Source |
|---|---|---|---|
| K1 | A StatefulSet update may only change `replicas`, `ordinals`, `template`, `updateStrategy`, `revisionHistoryLimit`, `persistentVolumeClaimRetentionPolicy` and `minReadySeconds`. Since v1.37 the refusal reads `field is immutable` per field instead of one `Forbidden` on `spec` | `immutable-field`, `apps` group only | [validation.go](https://github.com/kubernetes/kubernetes/blob/v1.37.3/pkg/apis/apps/validation/validation.go#L261-L264) |
| K2 | The `selector` of a Deployment, DaemonSet or ReplicaSet (`apps/v1`) is immutable | `immutable-field` | [validation.go](https://github.com/kubernetes/kubernetes/blob/v1.37.3/pkg/apis/apps/validation/validation.go#L704-L708) |
| K3 | A Job `selector`, `completionMode`, `podFailurePolicy`, `backoffLimitPerIndex`, `managedBy` and `successPolicy` are immutable; `completions` too, unless Indexed and equal to the new `parallelism`. `template` is immutable unless the Job is suspended and has not started (some fields only, behind gates) | `immutable-field`; the template of a Job suspended in the cluster passes | [validation.go](https://github.com/kubernetes/kubernetes/blob/v1.37.3/pkg/apis/batch/validation/validation.go#L638-L652) |
| K4 | A PVC `spec` is immutable, except `resources.requests.storage` and `volumeAttributesClassName` while Bound; `volumeName` may be set once while empty. `resources.limits` and other request keys never change | `immutable-field`; a Pending claim is not told apart | [validation.go](https://github.com/kubernetes/kubernetes/blob/v1.37.3/pkg/apis/core/validation/validation.go#L2565-L2611) |
| K5 | `resources.requests.storage` cannot go below the previous value; since v1.34 (RecoverVolumeExpansionFailure) it may, while above `status.capacity`, to retry a failed expansion | `pvc-shrink`, against the previous request: the capacity is not in git | [validation.go](https://github.com/kubernetes/kubernetes/blob/v1.37.3/pkg/apis/core/validation/validation.go#L2612-L2622) |
| K6 | The `roleRef` of a RoleBinding or ClusterRoleBinding is immutable | `immutable-field` | [validation.go](https://github.com/kubernetes/kubernetes/blob/v1.37.3/pkg/apis/rbac/validation/validation.go#L161-L168) |
| K7 | A set `clusterIP` cannot change; an unset one is allocated, or kept on update; a switch to or from `ExternalName` releases or allocates it | `immutable-field` when both sides set different values, neither `ExternalName` | [validation.go](https://github.com/kubernetes/kubernetes/blob/v1.37.3/pkg/apis/core/validation/validation.go#L9519-L9556) |
| K8 | A StatefulSet with `whenDeleted: Delete` owns its claims, which the garbage collector deletes with it; the default `Retain` keeps them | detail of `removed` and of the `force` note | [stateful_set_utils.go](https://github.com/kubernetes/kubernetes/blob/v1.37.3/pkg/controller/statefulset/stateful_set_utils.go#L333-L357) |
| K9 | The TTL controller deletes a finished Job `ttlSecondsAfterFinished` seconds after it finished | note on a Job `immutable-field`, read on the Job in the cluster | [ttlafterfinished_controller.go](https://github.com/kubernetes/kubernetes/blob/v1.37.3/pkg/controller/ttlafterfinished/ttlafterfinished_controller.go#L287-L302) |
| K10 | Deleting a CRD deletes all its custom resources; deleting a Namespace deletes every namespaced object in it | detail of `removed` | [crd_finalizer.go](https://github.com/kubernetes/kubernetes/blob/v1.37.3/staging/src/k8s.io/apiextensions-apiserver/pkg/controller/finalizer/crd_finalizer.go#L181-L237) |

## Flux

| Id | Behavior | In the lint | Source |
|---|---|---|---|
| F1 | `kustomize.toolkit.fluxcd.io/force: enabled`, as a label or an annotation, on the manifest or the object in the cluster, value in any case, makes kustomize-controller delete and recreate an object it cannot apply (any 409 or 422, not only immutable fields). `spec.force` forces every object | `force` note, under a Kustomization; `spec.force` is not read | [manager_apply.go](https://github.com/fluxcd/pkg/blob/ssa/v0.83.0/ssa/manager_apply.go#L667-L678) |
| F2 | helm-controller does not read that annotation; its `spec.upgrade.force` replaces objects under client-side apply, it does not recreate them | no `force` note under a HelmRelease | [upgrade.go](https://github.com/fluxcd/helm-controller/blob/v1.7.2/internal/action/upgrade.go#L77-L78) |
| F3 | `prune: disabled`, `reconcile: disabled` and `ssa: Ignore` (`kustomize.toolkit.fluxcd.io/`, label or annotation) exclude an object from deletion, read on the object in the cluster: adding one in the commit that removes the object protects nothing | removal kept, read on the old side | [kustomization_controller.go](https://github.com/fluxcd/kustomize-controller/blob/v1.10.2/internal/controller/kustomization_controller.go#L1505-L1521) |
| F4 | `prune: true` deletes what the source no longer renders; `prune: false` deletes nothing. Nothing is deleted while the Kustomization is suspended | `removed` or `not-pruned`; suspension is not read | [kustomization_controller.go](https://github.com/fluxcd/kustomize-controller/blob/v1.10.2/internal/controller/kustomization_controller.go#L1192-L1194) |
| F5 | A deleted Kustomization collects its objects by `deletionPolicy`: `MirrorPrune` (default) follows `prune`, `Delete` and `WaitForTermination` delete, `Orphan` keeps | fate of a removed Kustomization | [kustomization_controller.go](https://github.com/fluxcd/kustomize-controller/blob/v1.10.2/internal/controller/kustomization_controller.go#L1248-L1267) |
| F6 | Garbage collection deletes only objects whose `kustomize.toolkit.fluxcd.io/name` and `/namespace` labels still name the Kustomization | a moved object is deleted if the old producer reconciles first | [manager_delete.go](https://github.com/fluxcd/pkg/blob/ssa/v0.83.0/ssa/manager_delete.go#L77-L89) |
| F7 | Deleting a HelmRelease uninstalls the release, unless it is suspended | fate of a removed HelmRelease; suspension is not read | [helmrelease_controller.go](https://github.com/fluxcd/helm-controller/blob/v1.7.2/internal/controller/helmrelease_controller.go#L467-L478) |
| F8 | A Kustomization takes over an object another one applied, by relabelling it, with no check of the previous owner | a move is a removal only if the old producer wins the race | [kustomization_controller.go](https://github.com/fluxcd/kustomize-controller/blob/v1.10.2/internal/controller/kustomization_controller.go#L494-L498) |

## Helm

| Id | Behavior | In the lint | Source |
|---|---|---|---|
| H1 | An upgrade deletes the objects of the previous manifest the new one lacks, without checking their ownership | `removed` under a HelmRelease | [client.go](https://github.com/helm/helm/blob/v4.3.2/pkg/kube/client.go#L657-L699) |
| H2 | `helm.sh/resource-policy: keep` spares an object on upgrade (read on the object in the cluster, exact value) and on uninstall (read in the stored manifest); not a hook | removal kept, read on the old side | [client.go](https://github.com/helm/helm/blob/v4.3.2/pkg/kube/client.go#L680-L683) |
| H3 | The CRDs of `crds/` are never in the release manifest: never upgraded nor deleted. CRDs of `templates/` are deleted like any object | detail of `removed` for a CRD under a HelmRelease | [install.go](https://github.com/helm/helm/blob/v4.3.2/pkg/action/install.go#L331-L337) |
| H4 | Hooks are created, never updated; the delete policy, `before-hook-creation` by default, deletes the previous one first. With a policy without it nor `hook-succeeded`, the previous Job stays and the new one fails | hook Jobs pass unless their policy keeps the previous one | [hooks.go](https://github.com/helm/helm/blob/v4.3.2/pkg/action/hooks.go#L76-L107) |

## Not checked

- Helm refuses to adopt an existing object without its ownership metadata
  ([validate.go](https://github.com/helm/helm/blob/v4.3.2/pkg/action/validate.go#L170-L195)):
  an object moving from a Kustomization to a HelmRelease fails the HelmRelease until the
  Kustomization deletes it.
- A suspended Kustomization or HelmRelease applies and deletes nothing (F4, F7).
- A Pending PVC refuses a new storage request too (K4); a `storageClassName` set from nil
  to the value of its beta annotation is allowed.
