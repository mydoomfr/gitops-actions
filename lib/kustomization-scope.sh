#!/usr/bin/env bash
# Usage: kustomization-scope.sh <ks.json> <pr-dir> <base-dir>
# Tells whether the pull request diff shows the rendered change of each Kustomization in
# `flate diff ks -o json`. Prints {"<namespace>/<name>": {why, source}}, why being:
#   remote    it pulls a remote resource, component or base (URL, git remote)
#   external  its path lives in another Flux source than this repository
#   indirect  the pull request changes no file under its path (shared base, variable)
#   edited    the pull request edits a kustomization file under its path beyond
#             `images:` (components, patches, generators...), whose effect its diff hides
#   direct    the pull request only edits manifests or `images:` under its path, so its
#             diff shows the change
# The first that matches wins: a remote URL bump edits a file under the path too.
set -euo pipefail

ks=$1 pr=$2 base=$3
changed=$(git -C "$pr" diff --name-only HEAD^1 HEAD 2> /dev/null || true)

# Prints the remote entries of the kustomization in <dir>, following local directories
remotes() { # <root> <dir> <depth>
  local root=$1 dir=$2 depth=$3 file entry
  (( depth <= 8 )) || return 0
  for file in "$root/$dir"/{kustomization.yaml,kustomization.yml,Kustomization}; do
    [[ -f $file ]] || continue
    yq -r '[.resources, .components, .bases] | .[] | select(. != null) | .[] | select(tag == "!!str")' "$file" 2> /dev/null |
      while read -r entry; do
        if [[ $entry == *://* || $entry == git@* || $entry == *\?ref=* || $entry == *.git//* ]]; then
          echo "$entry"
        elif [[ -d $root/$dir/$entry ]]; then
          remotes "$root" "$dir/$entry" $((depth + 1))
        fi
      done
  done
}

# Flux source of a Kustomization, from its object in the pull request tree
source_of() { # <namespace> <name>
  local file
  grep -rlE --include='*.yaml' --include='*.yml' '^kind: Kustomization' "$pr" 2> /dev/null |
    while read -r file; do
      NS=$1 NAME=$2 yq ea -r 'select(.kind == "Kustomization" and .metadata.name == strenv(NAME)
        and (.metadata.namespace // "") == strenv(NS)) | .spec.sourceRef.name' "$file" 2> /dev/null
    done | sed -n 1p
}

# Whether the pull request changes a file under <path>, the repository root included
edited() { # <path>
  [[ -n $changed ]] || return 1
  [[ -n $1 ]] || return 0
  grep -qE "^$(sed 's/[][\.*^$+?(){}|/]/\\&/g' <<< "$1")(/|$)" <<< "$changed"
}

# Whether the pull request changes a kustomization file under <path> beyond `images:`,
# which Renovate bumps and the diff shows
restructured() { # <path>
  local file old new
  while read -r file; do
    case ${file##*/} in kustomization.yaml | kustomization.yml | Kustomization) ;; *) continue ;; esac
    [[ -z $1 || $file == "$1"/* ]] || continue
    old=$(yq -o json 'del(.images)' "$base/$file" 2> /dev/null || echo absent)
    new=$(yq -o json 'del(.images)' "$pr/$file" 2> /dev/null || echo absent)
    if [[ $old != "$new" ]]; then return 0; fi
  done <<< "$changed"
  return 1
}

jq -r '[if type == "array" then .[] else . end | .changes // [] | .[] | .parent
  | select(.kind == "Kustomization")] | unique_by([.namespace, .name])[]
  | [(.namespace // ""), .name, (.path // "" | ltrimstr("./") | rtrimstr("/") | if . == "." then "" else . end)] | @tsv' "$ks" |
  while IFS=$'\t' read -r ns name path; do
    # Whole output first: `head` closing the pipe early would kill the script under pipefail
    remote=$({ remotes "$pr" "$path" 0; remotes "$base" "$path" 0; } | sed -n 1p)
    if [[ -n $remote ]]; then
      why=remote source=$remote
    elif [[ -n $path && ! -e $pr/$path && ! -e $base/$path ]]; then
      why=external source=$(source_of "$ns" "$name")
    elif ! edited "$path"; then
      why=indirect source=
    elif restructured "$path"; then
      why=edited source=
    else
      why=direct source=
    fi
    jq -n --arg k "$ns/$name" --arg why "$why" --arg source "$source" '{($k): {why: $why, source: $source}}'
  done | jq -s 'add // {}'
