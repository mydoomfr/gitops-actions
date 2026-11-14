#!/usr/bin/env bash
# Usage: flux-diff-comment.sh <diff.json>...
# Turns `flate diff hr|ks -o json` outputs into comment.md: one summary table per kind of
# producer (HelmRelease, Kustomization), then each producer's changes in a collapsed
# section. CustomResourceDefinitions are summarized (served versions, fields added or
# removed) rather than diffed, and Secret values are never shown. comment-full.md keeps
# every section plus the raw CRD diffs; comment.md replaces the sections overflowing
# MAX_CHARS with a link. Writes an empty noop file instead when nothing changed and flate
# rendered all.
# KS_SCOPE: output of kustomization-scope.sh. KS_MODE picks the Kustomizations listed:
# auto (remote,source,shared,edited), all, none, or a comma-separated list of those
# reasons and direct. The others are only counted.
set -euo pipefail

: "${HEAD_SHA:=}" "${RUN_URL:=}" "${PARTIAL:=}" "${MAX_CHARS:=60000}" "${MAX_FIELDS:=5}"
: "${KS_SCOPE:=}" "${KS_MODE:=auto}"
work=$(mktemp -d)

# Reasons a Kustomization is listed for, as kustomization-scope.sh names them
case $KS_MODE in
  all) reasons=all ;;
  none) reasons=none ;;
  *)
    reasons=
    IFS=', ' read -ra names <<< "${KS_MODE/#auto/remote,source,shared,edited}"
    for name in "${names[@]}"; do
      case $name in
        remote | edited | direct) reason=$name ;;
        source) reason=external ;;
        shared) reason=indirect ;;
        *)
          echo "::error::kustomizations: unknown value '$name', expected auto, all, none or a list of remote, source, shared, edited, direct" >&2
          exit 2
          ;;
      esac
      reasons+=${reasons:+,}$reason
    done
    ;;
esac

# A file is empty when flate short-circuits identical trees, an array for multi-cluster repos
jq -s 'map(if type == "array" then .[] else . end)
  | {changes: map(.changes // [] | .[]), suppressed: map(.suppressed // [] | .[])}' "$@" > "$work/raw.json"

jq --slurpfile scope <(if [[ -n $KS_SCOPE ]]; then cat "$KS_SCOPE"; else echo '{}'; fi) --arg reasons "$reasons" '
  def key: "\(.namespace // "")/\(.name)";
  def why: $scope[0][.parent | key].why // "";
  # A Kustomization the scope does not know stays listed
  def listed: .parent.kind != "Kustomization" or ($reasons != "none"
    and ($reasons == "all" or why == "" or (why | IN($reasons | split(",")[]))));
  # Secret values never reach the comment: each key only says whether it changed
  def mask:
    (.old // {}) as $o
    | reduce ("data", "stringData", "binaryData") as $f (.;
        (if .old[$f] then .old[$f] |= with_entries(.value = "<redacted>") else . end)
        | (if .new[$f] then .new[$f] |= with_entries(.key as $k | .value = (
            if ($o[$f] // {} | has($k)) and $o[$f][$k] != .value then "<redacted, changed>" else "<redacted>" end))
          else . end));
  # Values ConfigMaps and Secrets of a changed HelmRelease: its rendered diff shows their effect
  ([.changes[] | select(.kind == "HelmRelease") | .namespace as $ns
    | (.old, .new) | objects | .spec.valuesFrom[]? | "\(.kind)/\($ns)/\(.name)"] | unique) as $values
  | .changes |= map(
      select((.parent.kind == "Kustomization" and (.kind == "ConfigMap" or .kind == "Secret")
        and ("\(.kind)/\(.namespace)/\(.name)" | IN($values[]))) | not)
      | if .kind == "Secret" then mask else . end)
  # Kustomizations not listed are only counted: those the pull request diff shows, and the others
  | ([.changes[] | select(listed | not) | {key: (.parent | key), why: why}] | unique) as $left
  | .shown = ($left | map(select(.why == "direct")) | length)
  | .skipped = ($left | map(select(.why != "direct")) | length)
  | .changes |= map(select(listed) | .why = ($scope[0][.parent | key] // {why: "", source: ""}))' "$work/raw.json" > "$work/diff.json"

if [[ $(jq '.changes + .suppressed | length' "$work/diff.json") == 0 && -z $PARTIAL ]]; then
  echo noop > noop
  exit 0
fi

jq --argjson maxfields "$MAX_FIELDS" '
  def id: if (.namespace // "") != "" then "\(.namespace)/\(.name)" else .name end;
  def chart: capture("^(?<name>.+?)-(?<version>v?[0-9]+\\..*)$") // {name: ., version: "?"};
  def versions($side): map(.[$side] // "" | select(. != "") | chart);
  # One entry per chart name (main chart first, then subcharts) with base and PR versions
  def charts($main):
    (versions("oldChart") | map(. + {side: "old"})) + (versions("newChart") | map(. + {side: "new"}))
    | group_by(.name) | map({
        name: .[0].name,
        old: map(select(.side == "old") | .version) | unique | join("/"),
        new: map(select(.side == "new") | .version) | unique | join("/")
      })
    | sort_by(.name != $main, .name)
    | map(. + {text: (
        if .old == .new then "`\(.name)` \(.new)"
        elif .old == "" then "`\(.name)` \(.new) (new)"
        elif .new == "" then "`\(.name)` \(.old) (removed)"
        else "`\(.name)` \(.old) → \(.new)" end)})
    # Bumped charts only, or the current versions when none moved
    | (map(select(.old != .new))) as $moved | (if $moved != [] then $moved else . end) | map(.text);
  # Dotted field paths of an OpenAPI schema, such as spec.rules[].matches
  def paths($p):
    (.properties // {} | to_entries[] | ($p + (if $p == "" then "" else "." end) + .key) as $q
      | $q, (.value | paths($q))),
    (.items | objects | paths($p + "[]")),
    (.additionalProperties | objects | paths($p + ".*"));
  def fields: [.schema.openAPIV3Schema // {} | paths("")] | unique;
  # Paths without an ancestor in the same list: a new subtree counts once
  def roots: . as $all | map(. as $p
    | select(any($all[]; . as $a | $a != $p and ($p | startswith($a + ".") or startswith($a + "[]"))) | not));
  def served: [.spec.versions[]? | .name + (if .storage then " (storage)" elif .served == false then " (not served)" else "" end)];
  def crd($o; $n):
    ($o // {}) as $o | ($n // {}) as $n
    | [$n.spec.versions[]? | . as $nv | ($o.spec.versions[]? | select(.name == $nv.name)) as $ov
        | {version: .name, added: (($nv | fields) - ($ov | fields)), removed: (($ov | fields) - ($nv | fields)),
           other: ($nv.schema != $ov.schema)}] as $versions
    | {served_old: ($o | served), served_new: ($n | served),
       fields: ($versions | map(select(.added != [] or .removed != [])) | group_by([.added, .removed])
         | map({versions: map(.version), added: .[0].added, removed: .[0].removed})),
       other: ($versions | any(.other and .added == [] and .removed == [])),
       annotations: [($o.metadata.annotations // {}) as $a | $n.metadata.annotations // {} | to_entries[]
         | select($a[.key] != .value) | "`\(.key)`: \($a[.key] // "∅") → \(.value)"]};
  def list: map("`\(.)`") | .[:$maxfields] + (if length > $maxfields then ["+\(length - $maxfields) more"] else [] end) | join(", ");
  def crdrow:
    (if .status == "added" then "new: \(.s.served_new | join(", "))"
     elif .status == "removed" then "removed"
     elif .s.served_old == .s.served_new then .s.served_new | join(", ")
     else "\(.s.served_old | join(", ")) → \(.s.served_new | join(", "))" end) as $versions
    | (if .status != "changed" then "—"
       else [(.s.fields[] | "\(.versions | join(", ")): "
                + ([(if .added != [] then "+\(.added | length) (\(.added | roots | list))" else empty end),
                    (if .removed != [] then "−\(.removed | length) (\(.removed | roots | list))" else empty end)]
                   | join(" "))),
             (if .s.other then "descriptions or validations" else empty end)]
         | if . == [] then "—" else join("<br>") end end) as $fields
    | "| `\(.name)` | \($versions) | \($fields) |";
  .changes | group_by([.parent.kind, .parent.namespace, .parent.name]) | map({
      kind: .[0].parent.kind,
      id: (.[0].parent | id),
      path: (.[0].parent.path // ""),
      why: .[0].why,
      added: map(select(.status == "added")) | length,
      changed: map(select(.status == "changed")) | length,
      removed: map(select(.status == "removed")) | length,
      charts: (if .[0].parent.kind == "HelmRelease" then charts(.[0].parent.name) else [] end),
      crds: [.[] | select(.kind == "CustomResourceDefinition") | {name, status, s: crd(.old; .new)} | . + {row: crdrow}],
      changes: map({label: "\(.kind) \(id)", crd: (.kind == "CustomResourceDefinition"), old, new})
    })
  | sort_by(.kind != "HelmRelease", .kind, .id)' "$work/diff.json" > "$work/groups.json"

# Wraps the given diff files in one fenced block, nothing when all are empty
fence() {
  if [[ -s $1 || -s ${2:-/dev/null} ]]; then printf '`````diff\n'; cat "$@"; printf '`````\n\n'; fi
}

ngroups=$(jq length "$work/groups.json")
for ((g = 0; g < ngroups; g++)); do
  jq -r --argjson g "$g" '.[$g] |
    "<details><summary><code>\(.id)</code>: "
    + ([(if .added > 0 then "\(.added) added" else empty end),
        (if .changed > 0 then "\(.changed) changed" else empty end),
        (if .removed > 0 then "\(.removed) removed" else empty end)] | join(", "))
    + "</summary>\n",
    (if .crds != [] then
      "| CustomResourceDefinition | Versions | Fields added / removed |", "|---|---|---|",
      (.crds[] | .row),
      ([.crds[] | select(.status == "changed") | .s.annotations[]] | group_by(.) | map("\(.[0]) (\(length) CRD\(if length > 1 then "s" else "" end))")
        | if . == [] then empty else "", "Annotations: \(join("; "))" end),
      ""
    else empty end)' "$work/groups.json" > "$work/head-$g.md"
  : > "$work/diff-$g.md"
  : > "$work/crd-$g.md"
  # Compact JSON never holds a raw tab: one change per line, label and both sides tab-separated
  # shellcheck disable=SC2034 # old and new are read through ${!side}
  jq -r --argjson g "$g" '.[$g].changes[] | [.label, (.crd | tostring), (.old | tojson), (.new | tojson)] | join("\t")' \
    "$work/groups.json" | while IFS=$'\t' read -r label crd old new; do
    # null for an addition or a removal: that side stays an empty file
    for side in old new; do
      if [[ ${!side} != null ]]; then
        yq -P -p json -o yaml <<< "${!side}" > "$work/$side.yaml"
      else
        : > "$work/$side.yaml"
      fi
    done
    # Raw CRD diffs only go to the run summary: the comment shows their summary
    if [[ $crd == true ]]; then out=$work/crd-$g.md; else out=$work/diff-$g.md; fi
    diff -u --label "$label" --label "$label" "$work/old.yaml" "$work/new.yaml" >> "$out" || true
  done
  { cat "$work/head-$g.md"; fence "$work/diff-$g.md"; printf '</details>\n\n'; } > "$work/section-$g.md"
  { cat "$work/head-$g.md"; fence "$work/diff-$g.md" "$work/crd-$g.md"; printf '</details>\n\n'; } > "$work/full-$g.md"
done

jq -r --arg sha "${HEAD_SHA::7}" --arg run "$RUN_URL" --arg partial "$PARTIAL" '
  def esc: gsub("\\|"; "\\|") | gsub("\n"; " ");
  def side: {orig: "base", current: "PR", both: "both"}[.] // .;
  def id: if (.namespace // "") != "" then "\(.namespace)/\(.name)" else .name end;
  "### Rendered Flux diff (\($sha))", "",
  (if $partial != "" or .suppressed != [] then
    "> [!WARNING]",
    "> Some HelmReleases or Kustomizations failed to render and their objects are left out of the diff, see the [run logs](\($run)).",
    "",
    (if .suppressed != [] then
      "| Producer | Side | Objects | Reason |", "|---|---|---|---|",
      (.suppressed[] | "| `\(.parent | id)` | \(.side | side) | \(.count) | \(.reason | esc) |"),
      ""
    else empty end)
  else empty end)' "$work/diff.json" > "$work/header.md"

# Summary table of a kind of producer, written before that kind's first section
table() { # <kind>
  jq -r --arg kind "$1" '
    def cell: if . == 0 then "" else tostring end;
    map(select(.kind == $kind)) |
    if $kind == "HelmRelease" then
      "#### HelmReleases", "",
      "| HelmRelease | Chart | Added | Changed | Removed |", "|---|---|--:|--:|--:|",
      (.[] | "| `\(.id)` | \(if .charts == [] then "—" else .charts[:3] + (if (.charts | length) > 3 then ["+\((.charts | length) - 3) more"] else [] end) | join("<br>") end) | \(.added | cell) | \(.changed | cell) | \(.removed | cell) |")
    else
      # Long URLs keep their host and last three segments, the version usually among them
      def short: if test("://") then capture("^[a-z+]+://(?<host>[^/]+)/(?<path>.*)$") // {host: ., path: ""}
        | .host + "/…/" + (.path | split("/") | .[-3:] | join("/")) else . end;
      def why: {remote: "remote `\(.source | short)`", external: "source `\(.source)`",
        indirect: "shared base or variable", edited: "kustomization edited", direct: "edited here"}[.why] // "—";
      "#### \($kind)s", "",
      "| \($kind) | Why | Path | Added | Changed | Removed |", "|---|---|---|--:|--:|--:|",
      (.[] | "| `\(.id)` | \(.why | why) | \(if .path != "" then "`\(.path)`" else "—" end) | \(.added | cell) | \(.changed | cell) | \(.removed | cell) |")
    end, ""' "$work/groups.json"
}

# Keep whole sections only: an overflowing diff is replaced by a link, never cut midway
cp "$work/header.md" comment-full.md
cp "$work/header.md" comment.md
kind=
for ((g = 0; g < ngroups; g++)); do
  this=$(jq -r --argjson g "$g" '.[$g].kind' "$work/groups.json")
  if [[ $this != "$kind" ]]; then
    kind=$this
    table "$kind" | tee -a comment-full.md >> comment.md
  fi
  cat "$work/full-$g.md" >> comment-full.md
  # Leave room for the link line of every section after this one
  reserve=$(( (ngroups - g) * 200 ))
  if (( $(wc -c < comment.md) + $(wc -c < "$work/section-$g.md") + reserve <= MAX_CHARS )); then
    cat "$work/section-$g.md" >> comment.md
  else
    id=$(jq -r --argjson g "$g" '.[$g].id' "$work/groups.json")
    printf -- '- `%s`: diff too long for a comment, see the [run summary](%s).\n' "$id" "$RUN_URL" >> comment.md
  fi
done

# Counts the Kustomizations left out: <count> <what>
left() {
  if (( $1 > 0 )); then
    printf '_%s more Kustomization%s %s._\n' "$1" "$([[ $1 == 1 ]] || echo s)" "$2" | tee -a comment-full.md >> comment.md
  fi
}
left "$(jq .shown "$work/diff.json")" "changed exactly as the pull request diff shows"
left "$(jq .skipped "$work/diff.json")" "changed, left out by the \`kustomizations\` input"
