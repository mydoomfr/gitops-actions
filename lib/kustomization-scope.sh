#!/usr/bin/env bash
# Usage: kustomization-scope.sh <ks.json> <pr-dir> <base-dir> [<cluster-path>]
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
# With <cluster-path>, Flux declarations are read only where that cluster's render goes,
# so that a source another cluster of the repository declares does not count.
set -euo pipefail

ks=$1 pr=$2 base=$3 cluster=${4:-}
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

# Flux files under the given directories of the pull request tree. No match is no file:
# grep exits 1, which pipefail would turn into a failure
flux_files() { # <dir>...
  { grep -rlE --include='*.yaml' --include='*.yml' \
    '^kind: (Kustomization|GitRepository|OCIRepository|Bucket|ExternalArtifact)\b' "$@" 2> /dev/null || true; } | sort -u
}

# yq over many files at once, file by file when one does not parse: a whole batch would
# otherwise be lost, and stop the script under errexit
yq_all() { # <expression> <file>..., evaluated per document
  local expr=$1 out file
  shift
  (( $# )) || return 0
  if out=$(yq e -r --no-doc "$expr" "$@" 2> /dev/null); then
    [[ -z $out ]] || printf '%s\n' "$out"
  else
    for file; do yq e -r --no-doc "$expr" "$file" 2> /dev/null || true; done
  fi
}

# Absolute path of an existing file or directory, symlinks resolved; nothing otherwise
resolve() { # <path>
  if [[ -d $1 ]]; then
    (cd "$1" && pwd -P)
  elif [[ -f $1 ]]; then
    (cd "${1%/*}" && printf '%s/%s\n' "$(pwd -P)" "${1##*/}")
  fi
}

# Files and directories a cluster's render reads, from the pull request tree: the cluster
# path, then the spec.path of every Flux Kustomization reading a GitRepository (the
# repository root when it sets none; the path of another source is inside its artifact)
# and the local files and directories every kustomization.yaml lists, until no new one
cluster_paths() { # <cluster-path>
  local paths queue files file
  paths=$(resolve "$pr/$1")
  [[ -n $paths ]] || return 0
  queue=$paths
  while [[ -n $queue ]]; do
    printf '%s\n' "$paths" > "$work/known"
    queue=$({
      # One yq per batch of files, not per file: the tree may hold hundreds
      files=()
      while read -r file; do files+=("$file"); done < <(while read -r path; do flux_files "$path"; done <<< "$queue" | sort -u)
      yq_all 'select(.kind == "Kustomization" and ((.apiVersion // "") | test("^kustomize\\.toolkit\\.fluxcd\\.io/"))
          and (.spec.sourceRef.kind // "GitRepository") == "GitRepository")
        | (.spec.path // "") | sub("^$"; ".")' ${files[@]+"${files[@]}"} |
        while read -r entry; do printf '%s/%s\n' "$pr" "$entry"; done
      files=()
      while read -r file; do files+=("$file"); done < <(while read -r path; do
        find "$path" \( -name kustomization.yaml -o -name kustomization.yml -o -name Kustomization \) 2> /dev/null
      done <<< "$queue" | sort -u)
      yq_all 'filename as $f | ((.resources // []) + (.components // []) + (.bases // []))[]
        | select(tag == "!!str") | select(test("://|^git@") | not) | $f + "\t" + .' ${files[@]+"${files[@]}"} |
        while IFS=$'\t' read -r file entry; do printf '%s/%s\n' "${file%/*}" "$entry"; done
    } | sort -u | while read -r entry; do resolve "$entry"; done | sort -u |
      # Only what is neither known nor inside a known directory
      awk 'NR == FNR { known[++n] = $0; next }
        { for (i = 1; i <= n; i++) if ($0 == known[i] || index($0, known[i] "/") == 1) next; print }' "$work/known" -)
    if [[ -n $queue ]]; then paths=$(printf '%s\n%s' "$paths" "$queue"); fi
  done
  echo "$paths"
}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
read_paths=$pr
if [[ -n $cluster ]]; then
  read_paths=$(cluster_paths "$cluster")
  if [[ -z $read_paths ]]; then
    echo "::warning::kustomization-scope: cluster path $cluster not found, reading the whole tree" >&2
    read_paths=$pr
  fi
fi
paths=()
while read -r path; do paths+=("$path"); done <<< "$read_paths"

# Flux Kustomizations and the sources they may read, declared in the pull request tree
# (only where the cluster's render goes, with <cluster-path>), read once:
# [{kind, namespace, name, source}], source being a Kustomization's sourceRef
declarations=$(flux_files "${paths[@]}" |
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
    IFS=$'\t' read -r sdeclared skind sname < <(source_of "$ns" "$name") || sdeclared='' skind='' sname=''
    # Whole output first: `head` closing the pipe early would kill the script under pipefail
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
