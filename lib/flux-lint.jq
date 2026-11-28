# Review warnings read from `flate diff -o json` changes, loaded by flux-diff-comment.sh.
# lint: {changes} -> [{rule, resource, parent, detail}], sorted and without duplicates.

def lint_id: if (.namespace // "") != "" then "\(.namespace)/\(.name)" else .name end;

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
  | (if .new.metadata.annotations["kustomize.toolkit.fluxcd.io/force"] == "enabled"
      then " (Flux `force` enabled: recreated)" else "" end) as $force
  | {resource: "\(.kind) \(lint_id)", parent: "\(.parent.kind) \(.parent | lint_id)"} as $at
  | (if .kind == "StatefulSet" then
      changed_outside(["replicas", "ordinals", "template", "updateStrategy",
        "persistentVolumeClaimRetentionPolicy", "minReadySeconds"])
    elif .kind | IN("Deployment", "DaemonSet", "ReplicaSet") then changed_keys(["selector"])
    # Helm deletes and recreates its hook Jobs
    elif .kind == "Job" then
      if [.old, .new | .metadata.annotations["helm.sh/hook"]?] | any(. != null) then []
      else changed_keys(["selector", "template"]) end
    elif .kind == "PersistentVolumeClaim" then changed_outside(["resources", "volumeAttributesClassName"])
    elif .kind | IN("RoleBinding", "ClusterRoleBinding") then
      if .old.roleRef != .new.roleRef then ["roleRef"] else [] end
    # An unset clusterIP is allocated by the API server, so only two set values conflict
    elif .kind == "Service" then
      (.old.spec.clusterIP // "") as $a | (.new.spec.clusterIP // "") as $b
      | if $a != "" and $b != "" and $a != $b then ["spec.clusterIP"] else [] end
    else [] end) as $fields
  | (if $fields != [] then
      $at + {rule: "immutable-field", detail: "\($fields | map("`\(.)`") | join(", ")) changed\($force)"}
    else empty end),
    (select(.kind == "PersistentVolumeClaim")
      | (.old.spec.resources.requests.storage | strings) as $a
      | (.new.spec.resources.requests.storage | strings) as $b
      | select(($b | bytes) < ($a | bytes))
      | $at + {rule: "pvc-shrink", detail: "storage request `\($a)` → `\($b)`: a PersistentVolumeClaim can only grow\($force)"});

def lint: [.changes[] | immutable] | unique_by(.resource, .rule, .detail);
