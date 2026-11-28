# Review warnings read from `flate diff -o json` changes, loaded by flux-diff-comment.sh.
# lint: {changes} -> [{rule, resource, parent, detail}], sorted and without duplicates.

def lint_id: if (.namespace // "") != "" then "\(.namespace)/\(.name)" else .name end;

# API group of a change, "" for the core group: a custom resource may reuse a core kind
def lint_group: [.apiVersion, .new.apiVersion, .old.apiVersion | strings | select(. != "")][0] // ""
  | if test("/") then split("/")[0] else "" end;
def is($group; $kinds): lint_group == $group and (.kind | IN($kinds[]));

# Fields of spec that differ between both sides, as spec.<key>
def changed_keys($keys): (.old.spec // {}) as $o | (.new.spec // {}) as $n
  | [$keys[] | select($o[.] != $n[.]) | "spec.\(.)"];
# Same, for every key of spec outside the mutable ones
def changed_outside($mutable): (.old.spec // {}) as $o | (.new.spec // {}) as $n
  | changed_keys([$o + $n | keys[] | select(IN($mutable[]) | not)]);

# A Kubernetes quantity in bytes, nothing when it does not parse
def bytes: capture("^(?<n>[0-9]+(\\.[0-9]+)?)(?<u>Ki|Mi|Gi|Ti|Pi|Ei|k|M|G|T|P|E)?$")
  | (.n | tonumber) * ({"": 1, k: 1e3, M: 1e6, G: 1e9, T: 1e12, P: 1e15, E: 1e18,
      Ki: pow(2; 10), Mi: pow(2; 20), Gi: pow(2; 30), Ti: pow(2; 40), Pi: pow(2; 50), Ei: pow(2; 60)}[.u // ""]);

# Updates the API server refuses: the apply fails, and the reconciliation with it, until
# the object is deleted and recreated
def immutable:
  select(.status == "changed" and (.old | type) == "object" and (.new | type) == "object")
  | is(""; ["PersistentVolumeClaim"]) as $pvc
  # The annotation is read by kustomize-controller only: helm-controller never recreates
  | (if .parent.kind != "Kustomization"
      or .new.metadata.annotations["kustomize.toolkit.fluxcd.io/force"] != "enabled" then ""
    elif $pvc then " (Flux `force` enabled: recreating the claim can delete its data)"
    elif is("apps"; ["StatefulSet"]) and .new.spec.persistentVolumeClaimRetentionPolicy.whenDeleted == "Delete"
      then " (Flux `force` enabled: recreating it deletes its PersistentVolumeClaims, `whenDeleted: Delete`)"
    else " (Flux `force` enabled: recreated)" end) as $force
  | {resource: "\(.kind) \(lint_id)",
     parent: "\(.parent.kind) \(.parent | lint_id)\(if (.cluster // "") | IN("", ".") | not then " (\(.cluster))" else "" end)"} as $at
  | (if is("apps"; ["StatefulSet"]) then
      changed_outside(["replicas", "ordinals", "template", "updateStrategy", "revisionHistoryLimit",
        "persistentVolumeClaimRetentionPolicy", "minReadySeconds"])
    elif is("apps"; ["Deployment", "DaemonSet", "ReplicaSet"]) then changed_keys(["selector"])
    # Helm deletes and recreates its hook Jobs
    elif is("batch"; ["Job"]) then
      if [.old, .new | .metadata.annotations["helm.sh/hook"]?] | any(. != null) then []
      else changed_keys(["selector", "template"]) end
    # volumeName may be set once, to bind the claim
    elif $pvc then changed_outside(["resources", "volumeAttributesClassName"]
      + if (.old.spec.volumeName // "") == "" then ["volumeName"] else [] end)
    elif is("rbac.authorization.k8s.io"; ["RoleBinding", "ClusterRoleBinding"]) then
      if .old.roleRef != .new.roleRef then ["roleRef"] else [] end
    # An unset clusterIP is allocated by the API server, so only two set values conflict
    elif is(""; ["Service"]) then
      (.old.spec.clusterIP // "") as $a | (.new.spec.clusterIP // "") as $b
      | if $a != "" and $b != "" and $a != $b then ["spec.clusterIP"] else [] end
    else [] end) as $fields
  # The TTL of the Job in the cluster, the old one, deletes it once finished; Flux then
  # creates the new one
  | (if is("batch"; ["Job"]) and .old.spec.ttlSecondsAfterFinished != null
      then " (`ttlSecondsAfterFinished` set: fails until the previous Job finishes and its TTL expires)" else "" end) as $ttl
  | (if $fields != [] then
      $at + {rule: "immutable-field", detail: "\($fields | map("`\(.)`") | join(", ")) changed\($ttl)\($force)"}
    else empty end),
    (select($pvc)
      | (.old.spec.resources.requests.storage | strings) as $a
      | (.new.spec.resources.requests.storage | strings) as $b
      | select(($b | bytes) < ($a | bytes))
      | $at + {rule: "pvc-shrink", detail: "storage request `\($a)` → `\($b)`: a PersistentVolumeClaim can only grow\($force)"});

def lint: [.changes[] | immutable] | unique_by(.resource, .parent, .rule, .detail);
