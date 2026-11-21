#!/usr/bin/env bash
# Usage: kustomization-scope.sh <ks.json> <pr-dir> <base-dir>
# Tells whether the pull request diff shows the rendered change of each Kustomization in
# `flate diff ks -o json`. Prints {"<namespace>/<name>": {why, source}}, why being:
#   remote    it pulls a remote resource, component or base (URL, git remote)
#   external  it reads another Flux source than this repository: an ExternalArtifact, an
#             OCIRepository or Bucket the tree declares, or a path missing from the tree
#   indirect  the pull request changes no file under its path (shared base, variable)
#   edited    the pull request edits a kustomization file under its path beyond
#             `images:` (components, patches, generators...), whose effect its diff hides
#   direct    the pull request only edits manifests or `images:` under its path, so its
#             diff shows the change
# The first that matches wins: a remote URL bump edits a file under the path too. A
# source the tree does not declare is the working tree to flate, so it is not external.
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

# Flux Kustomizations and the sources they may read, declared in the pull request tree,
# read once: [{kind, namespace, name, source}], source being a Kustomization's sourceRef
# No match is no declaration: grep exits 1, which pipefail would turn into a failure
declarations=$({ grep -rlE --include='*.yaml' --include='*.yml' \
  '^kind: (Kustomization|GitRepository|OCIRepository|Bucket|ExternalArtifact)\b' "$pr" 2> /dev/null || true; } |
  while read -r file; do
    yq ea -o json -I0 'select(tag == "!!map" and ((.kind == "Kustomization"
        and ((.apiVersion // "") | test("^kustomize\\.toolkit\\.fluxcd\\.io/")))
        or .kind == "GitRepository" or .kind == "OCIRepository" or .kind == "Bucket" or .kind == "ExternalArtifact"))
      | (.metadata.namespace // "") as $ns
      | {"kind": .kind, "namespace": $ns, "name": .metadata.name, "source": {"kind": (.spec.sourceRef.kind // "GitRepository"),
          "namespace": (.spec.sourceRef.namespace // $ns), "name": (.spec.sourceRef.name // "")}}' "$file" 2> /dev/null || true
  done | jq -sc .)

# Flux source of a Kustomization as declared<TAB>kind<TAB>name, from its object in the
# pull request tree; declared is true when the tree also declares that source. An object
# without a namespace matches any, a parent kustomization.yaml may set it. The name comes
# last: read with a tab IFS, an empty field in the middle would shift the others.
source_of() { # <namespace> <name>
  jq -r --arg ns "$1" --arg name "$2" '. as $all
    | [.[] | select(.kind == "Kustomization" and .name == $name and (.namespace == $ns or .namespace == ""))]
    | sort_by(.namespace != $ns) | .[0].source // empty
    | . as $s | [(any($all[]; .kind == $s.kind and .name == $s.name
      and (.namespace == $s.namespace or .namespace == "")) | tostring), .kind, .name]
    | @tsv' <<< "$declarations"
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
    IFS=$'\t' read -r sdeclared skind sname < <(source_of "$ns" "$name") || sdeclared= skind= sname=
    remote=$({ remotes "$pr" "$path" 0; remotes "$base" "$path" 0; } | sed -n 1p)
    # flate renders an ExternalArtifact (an ArtifactGenerator output) or a declared OCI or
    # Bucket source, whatever the local files say; an undeclared one is the working tree
    if [[ $skind == ExternalArtifact || ($sdeclared == true && $skind != GitRepository) ]]; then
      why=external source=$sname
    elif [[ -n $remote ]]; then
      why=remote source=$remote
    elif [[ -n $path && ! -e $pr/$path && ! -e $base/$path ]]; then
      why=external source=$sname
    elif ! edited "$path"; then
      why=indirect source=
    elif restructured "$path"; then
      why=edited source=
    else
      why=direct source=
    fi
    jq -n --arg k "$ns/$name" --arg why "$why" --arg source "$source" '{($k): {why: $why, source: $source}}'
  done | jq -s 'add // {}'
