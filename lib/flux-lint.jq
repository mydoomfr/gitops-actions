# Review warnings read from `flate diff -o json` changes, loaded by flux-diff-comment.sh.
# lint: {changes, kustomizations?, removal_kinds?} -> [{rule, resource, parent, detail}], sorted
# and without duplicates.

def lint_id: if (.namespace // "") != "" then "\(.namespace)/\(.name)" else .name end;
# The producer of a change, with its cluster when flate reports one
def lint_parent: "\(.parent.kind) \(.parent | lint_id)\(if (.cluster // "") | IN("", ".") | not then " (\(.cluster))" else "" end)";

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

# A kustomize-controller setting on one of $sides: a label or an annotation, its value
# compared case-insensitively (SEMANTICS.md F1, F3)
def flux_set($sides; $key; $value): any($sides[] | objects | .metadata | (.labels, .annotations) | objects
  | .[$key] | strings; ascii_downcase == ($value | ascii_downcase));

# A Helm hook that Helm deletes before creating it again: its delete policy, before-hook-
# creation by default, or hook-succeeded once it ran (H4)
def hook_recreated: .parent.kind == "HelmRelease" and (.new.metadata.annotations["helm.sh/hook"] | strings) != null
  and ((.new.metadata.annotations["helm.sh/hook-delete-policy"] // "before-hook-creation") | split(",")
    | any(.[]; gsub("\\s"; "") | IN("before-hook-creation", "hook-succeeded")));

# A Kubernetes quantity in bytes, nothing when it does not parse
def bytes: capture("^(?<n>[0-9]+(\\.[0-9]+)?)(?<u>Ki|Mi|Gi|Ti|Pi|Ei|k|M|G|T|P|E)?$")
  | (.n | tonumber) * ({"": 1, k: 1e3, M: 1e6, G: 1e9, T: 1e12, P: 1e15, E: 1e18,
      Ki: pow(2; 10), Mi: pow(2; 20), Gi: pow(2; 30), Ti: pow(2; 40), Pi: pow(2; 50), Ei: pow(2; 60)}[.u // ""]);

# Updates the API server refuses: the apply fails, and the reconciliation with it, until
# the object is deleted and recreated
def immutable:
  select(.status == "changed" and (.old | type) == "object" and (.new | type) == "object")
  | is(""; ["PersistentVolumeClaim"]) as $pvc
  # kustomize-controller reads it on the manifest or on the object in the cluster;
  # helm-controller never recreates (F1, F2)
  | (if .parent.kind != "Kustomization"
      or (flux_set([.new, .old]; "kustomize.toolkit.fluxcd.io/force"; "enabled") | not) then ""
    elif $pvc then " (Flux `force` enabled: recreating the claim can delete its data)"
    elif is("apps"; ["StatefulSet"]) and .new.spec.persistentVolumeClaimRetentionPolicy.whenDeleted == "Delete"
      then " (Flux `force` enabled: recreating it deletes its PersistentVolumeClaims, `whenDeleted: Delete`)"
    else " (Flux `force` enabled: recreated)" end) as $force
  | {resource: "\(.kind) \(lint_id)", parent: lint_parent} as $at
  | (if is("apps"; ["StatefulSet"]) then
      changed_outside(["replicas", "ordinals", "template", "updateStrategy", "revisionHistoryLimit",
        "persistentVolumeClaimRetentionPolicy", "minReadySeconds"])
    elif is("apps"; ["Deployment", "DaemonSet", "ReplicaSet"]) then changed_keys(["selector"])
    # The template of a suspended Job may change; completions only along with parallelism,
    # in Indexed mode (K3). Helm deletes and recreates its hooks (H4)
    elif is("batch"; ["Job"]) then
      if hook_recreated then []
      else changed_keys(["selector", "completionMode", "podFailurePolicy", "backoffLimitPerIndex", "managedBy",
          "successPolicy"] + if .old.spec.suspend == true then [] else ["template"] end)
        + if .old.spec.completions != .new.spec.completions
            and (.new.spec.completionMode != "Indexed" or .new.spec.completions != .new.spec.parallelism)
          then ["spec.completions"] else [] end
      end
    # Only the storage request and the attributes class may change; volumeName may be set
    # once, to bind the claim (K4)
    elif $pvc then
      def other_resources: .spec.resources // {} | del(.requests.storage)
        | if .requests == {} then del(.requests) else . end;
      changed_outside(["resources", "volumeAttributesClassName"]
        + if (.old.spec.volumeName // "") == "" then ["volumeName"] else [] end)
      + ((.old | other_resources) as $o | (.new | other_resources) as $n
        | [$o + $n | keys[] | select($o[.] != $n[.]) | "spec.resources.\(.)"])
    elif is("rbac.authorization.k8s.io"; ["RoleBinding", "ClusterRoleBinding"]) then
      if .old.roleRef != .new.roleRef then ["roleRef"] else [] end
    # An unset clusterIP is allocated by the API server, so only two set values conflict;
    # an ExternalName Service releases or allocates it (K7)
    elif is(""; ["Service"]) and ([.old, .new | .spec.type] | index("ExternalName") | not) then
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

# Key of a Flux object or producer in the lint index
def lint_key($cluster; $namespace; $name): [$cluster // "", $namespace // "", $name] | tojson;

# The Flux objects among the changes, and the prune setting of each Kustomization, keyed
# by lint_key: built once, every removal looks its producer up. `from_entries` is avoided:
# older jq drops a false value
def lint_index($ctx):
  def objects($kind; $group): reduce ($ctx.changes[] | select(.kind == $kind and lint_group == $group)) as $c
    ({}; . + {(lint_key($c.cluster; $c.namespace; $c.name)): $c});
  {ks: objects("Kustomization"; "kustomize.toolkit.fluxcd.io"),
   hr: objects("HelmRelease"; "helm.toolkit.fluxcd.io"),
   prune: (reduce ($ctx.kustomizations // [] | .[]) as $k ({}; . + {(lint_key($k.cluster; $k.namespace; $k.name)): $k.prune}))};

# What Flux does on merge with a removed object, from its producer:
#   deleted   a HelmRelease or a pruning Kustomization no longer renders it
#   orphaned  a Kustomization that does not prune, or removed with `deletionPolicy: Orphan`
#   kept      an annotation keeps it, or its producer stays in the cluster and keeps it
#   ""        the prune setting of a Kustomization is unknown
def fate($idx):
  .old.metadata.annotations as $a
  | lint_key(.cluster; .parent.namespace; .parent.name) as $k
  | if .parent.kind == "HelmRelease" then
      if ($a["helm.sh/resource-policy"] // "") == "keep" then "kept"
      # helm-controller uninstalls a deleted HelmRelease; one left in the cluster keeps its
      # release, whatever its render here says
      elif $idx.hr[$k].status != "removed" then "deleted"
      else ($idx.hr[$k] | fate($idx)) | if . == "deleted" or . == "" then . else "kept" end end
    elif .parent.kind != "Kustomization" then ""
    # Settings read on the object in the cluster, not on the manifest that removes it (F3)
    elif flux_set([.old]; "kustomize.toolkit.fluxcd.io/prune"; "disabled")
      or flux_set([.old]; "kustomize.toolkit.fluxcd.io/reconcile"; "disabled")
      or flux_set([.old]; "kustomize.toolkit.fluxcd.io/ssa"; "Ignore") then "kept"
    else $idx.ks[$k] as $obj
      | if $obj.status == "removed" then
          # Its deletion collects what it applied. Left in the cluster, it keeps applying its
          # path, or fails to find it: nothing is deleted
          ($obj | fate($idx)) as $own
          | if $own == "" then ""
            elif $own != "deleted" then "kept"
            elif ($obj.old.spec.deletionPolicy // "") == "Orphan" then "orphaned"
            elif ($obj.old.spec.deletionPolicy // "") | IN("Delete", "WaitForTermination") then "deleted"
            elif $obj.old.spec.prune == true then "deleted" else "orphaned" end
        else
          # `flate get ks` names no cluster when the pull request tree keeps only one, while
          # the diff still names both sides. `//` would skip a false prune
          ([$idx.prune[$k], $idx.prune[lint_key(""; .parent.namespace; .parent.name)], ($obj.new.spec.prune | booleans)]
            | map(booleans) | .[0]) as $prune
          | if $prune == true then "deleted" elif $prune == false then "orphaned" else "" end
        end
    end;

def removal_kinds: ["StatefulSet", "PersistentVolumeClaim", "Namespace", "CustomResourceDefinition", "NetworkPolicy"];
# Why deleting an object of one of removal_kinds matters, "" for another API group
def removal_risk:
  if is("apps"; ["StatefulSet"]) then
    if .old.spec.persistentVolumeClaimRetentionPolicy.whenDeleted == "Delete"
    then "its PersistentVolumeClaims go with it, `whenDeleted: Delete`, which can delete their data"
    else "its pods stop, its PersistentVolumeClaims stay" end
  elif is(""; ["PersistentVolumeClaim"]) then "deleting the claim can delete its data, depending on the `reclaimPolicy` of its volume"
  elif is(""; ["Namespace"]) then "deleting the namespace deletes every object in it"
  elif is("apiextensions.k8s.io"; ["CustomResourceDefinition"]) then
    "deleting the definition deletes every `\(.old.spec.names.kind // "custom resource")` in the cluster"
    + if .parent.kind == "HelmRelease" then ", unless the chart ships it in `crds/`, which Helm never deletes" else "" end
  elif is("networking.k8s.io"; ["NetworkPolicy"]) then "traffic it denied can then be allowed"
  else "" end;

# Removed objects: a risky kind deleted on merge, and what a Kustomization leaves behind
# without pruning, one warning per Kustomization. An object another producer now renders
# moves, but the old one may delete it before the new one applies it: they reconcile in
# no set order. $kinds: the kinds worth a warning when deleted
def removals($ctx; $kinds):
  lint_index($ctx) as $idx
  | def move_key: [.cluster // "", lint_group, .kind, .namespace // "", .name] | tojson;
  (reduce ($ctx.changes[] | select(.status == "added")) as $c ({}; . + {($c | move_key): ($c | lint_parent)})) as $added
  | [$ctx.changes[] | select(.status == "removed" and (.old | type) == "object")
      | . + {fate: fate($idx), to: $added[move_key]}] as $removed
  | ($removed[] | select((.fate | IN("deleted", "")) and (.kind | IN($kinds[])))
      # A custom resource reusing one of these kinds is not what the warning describes
      | select(removal_risk != "" or (.kind | IN(removal_kinds[]) | not))
      | {resource: "\(.kind) \(lint_id)", parent: lint_parent, rule: "removed",
         detail: ((if .to != null then "moves to `\(.to)`, deleted and recreated if `\(lint_parent)` reconciles first"
             + (if .fate == "" then " and prunes" else "" end)
           elif .fate == "" then "deleted on merge if the Kustomization prunes" else "deleted on merge" end)
           + (removal_risk | if . != "" then ": \(.)" else "" end))}),
    # What another producer now applies is managed again
    ($removed | map(select(.fate == "orphaned" and .to == null)) | group_by(lint_parent)[]
      | {resource: (if length == 1 then "\(.[0].kind) \(.[0] | lint_id)" else "\(length) objects" end),
         parent: (.[0] | lint_parent), rule: "not-pruned",
         detail: "removed from git but left in the cluster, where nothing manages \(if length == 1 then "it" else "them" end) any more"});

# lint: .removal_kinds overrides the kinds flagged when deleted
def lint:
  . as $ctx
  | [(.changes[] | immutable),
     removals($ctx; $ctx.removal_kinds // removal_kinds)]
  | unique_by(.resource, .parent, .rule, .detail);
