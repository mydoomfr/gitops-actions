# Turns a case of cases.yaml into the input of lint, and a warning into its expected line

def case_api: {StatefulSet: "apps/v1", Deployment: "apps/v1", DaemonSet: "apps/v1", ReplicaSet: "apps/v1",
  Job: "batch/v1", RoleBinding: "rbac.authorization.k8s.io/v1", ClusterRoleBinding: "rbac.authorization.k8s.io/v1",
  NetworkPolicy: "networking.k8s.io/v1", CustomResourceDefinition: "apiextensions.k8s.io/v1",
  Kustomization: "kustomize.toolkit.fluxcd.io/v1", HelmRelease: "helm.toolkit.fluxcd.io/v2",
  CronJob: "batch/v1", OCIRepository: "source.toolkit.fluxcd.io/v1", GitRepository: "source.toolkit.fluxcd.io/v1"}[.] // "v1";

def case_change:
  (.parent // "Kustomization/apps" | split("/")) as $p
  | {name: "x",
     namespace: (if .kind | IN("Namespace", "CustomResourceDefinition", "ClusterRoleBinding") then ""
       elif .kind | IN("Kustomization", "HelmRelease") then "flux-system" else "apps" end),
     apiVersion: (.kind | case_api), cluster: "", old: null, new: null}
  + .
  + {parent: {kind: $p[0], namespace: "flux-system", name: $p[1]}}
  | .status = (if .old == null then "added" elif .new == null then "removed" else "changed" end);

def case_input:
  {changes: [.changes[] | case_change],
   kustomizations: [.prune // {} | to_entries[] | {cluster: "", namespace: "flux-system", name: .key, prune: .value}]}
  + (if has("removal_kinds") then {removal_kinds} else {} end);

def case_line: "\(.rule) \(.resource) (\(.parent)): \(.detail)";
