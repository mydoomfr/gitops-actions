#!/usr/bin/env bash
# Usage: kustomization-prune.sh <ks.json> <cluster-path> [<flate flag>...]
# Prints the Kustomizations of the pull request tree with their prune setting, read with
# `flate get ks`: [{cluster, namespace, name, prune}]. flux-lint.jq tells with it a removal
# Flux deletes from one it leaves in the cluster. The listing renders the Kustomizations
# again, so it only runs when one of <ks.json> removes an object; [] otherwise, or when
# flate fails.
set -euo pipefail

ks=$1 path=$2
shift 2
if ! jq -se 'any(.[] | if type == "array" then .[] else . end | .changes // [] | .[];
    .status == "removed" and .parent.kind == "Kustomization")' "$ks" > /dev/null 2>&1; then
  echo '[]'
  exit 0
fi
# Neither --path-orig nor --base: with either, get lists only what changed. A single cluster
# prints its Kustomizations, several print [{cluster, documents}]. A Kustomization flate
# cannot render fails the command but leaves the others listed
rc=0
out=$(env -u FLATE_BASE flate get ks "$@" --path "$path" -o json) || rc=$?
if jq -ce '[.[] | if has("documents") then .cluster as $c | .documents[] | . + {cluster: $c} else . + {cluster: ""} end
  | {cluster, namespace: (.namespace // ""), name, prune: (.prune == true)}]' <<< "$out" 2> /dev/null; then
  if (( rc != 0 )); then
    echo "::warning::flate could not list every Kustomization: the removals of those left out are flagged as possible deletions" >&2
  fi
  exit 0
fi
echo "::warning::flate could not list the Kustomizations: their removals are flagged as possible deletions" >&2
echo '[]'
