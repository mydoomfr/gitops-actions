#!/usr/bin/env bash
# Usage: helm-diff-comment.sh <diff.json>
# Turns `flate diff hr -o json` into comment.md: one summary row per HelmRelease
# (chart bump, change counts), then its unified diff in a collapsed section.
# comment-full.md keeps every diff; comment.md replaces those overflowing MAX_CHARS
# with a link. Writes an empty noop file instead when nothing changed and flate rendered all.
set -euo pipefail

: "${HEAD_SHA:=}" "${RUN_URL:=}" "${PARTIAL:=}" "${MAX_CHARS:=60000}"
work=$(mktemp -d)

# Empty when flate short-circuits identical trees, an array for multi-cluster repos
jq -s '(.[0] // {}) | if type == "array" then {changes: map(.changes[]), suppressed: map(.suppressed[])} else . end
  | {changes: (.changes // []), suppressed: (.suppressed // [])}' "$1" > "$work/diff.json"

if [[ $(jq '.changes + .suppressed | length' "$work/diff.json") == 0 && -z $PARTIAL ]]; then
  echo noop > noop
  exit 0
fi

jq '
  def id: if .namespace != "" then "\(.namespace)/\(.name)" else .name end;
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
  .changes | group_by([.parent.namespace, .parent.name]) | map({
      id: (.[0].parent | id),
      added: map(select(.status == "added")) | length,
      changed: map(select(.status == "changed")) | length,
      removed: map(select(.status == "removed")) | length,
      charts: charts(.[0].parent.name),
      changes: map({label: "\(.kind) \(id)", old, new})
    })' "$work/diff.json" > "$work/groups.json"

ngroups=$(jq length "$work/groups.json")
for ((g = 0; g < ngroups; g++)); do
  jq -r --argjson g "$g" '.[$g] |
    "<details><summary><code>\(.id)</code>: "
    + ([(if .added > 0 then "\(.added) added" else empty end),
        (if .changed > 0 then "\(.changed) changed" else empty end),
        (if .removed > 0 then "\(.removed) removed" else empty end)] | join(", "))
    + "</summary>\n\n`````diff"' "$work/groups.json" > "$work/section-$g.md"
  # Compact JSON never holds a raw tab: one change per line, label and both sides tab-separated
  # shellcheck disable=SC2034 # old and new are read through ${!side}
  jq -r --argjson g "$g" '.[$g].changes[] | [.label, (.old | tojson), (.new | tojson)] | join("\t")' \
    "$work/groups.json" | while IFS=$'\t' read -r label old new; do
    # null for an addition or a removal: that side stays an empty file
    for side in old new; do
      if [[ ${!side} != null ]]; then
        yq -P -p json -o yaml <<< "${!side}" > "$work/$side.yaml"
      else
        : > "$work/$side.yaml"
      fi
    done
    diff -u --label "$label" --label "$label" "$work/old.yaml" "$work/new.yaml" || true
  done >> "$work/section-$g.md"
  printf '`````\n\n</details>\n\n' >> "$work/section-$g.md"
done

jq -r --arg sha "${HEAD_SHA::7}" --arg run "$RUN_URL" --arg partial "$PARTIAL" --slurpfile groups "$work/groups.json" '
  def cell: if . == 0 then "" else tostring end;
  def esc: gsub("\\|"; "\\|") | gsub("\n"; " ");
  def side: {orig: "base", current: "PR", both: "both"}[.] // .;
  def id: if .namespace != "" then "\(.namespace)/\(.name)" else .name end;
  "### Rendered HelmRelease diff (\($sha))", "",
  (if $partial != "" or .suppressed != [] then
    "> [!WARNING]",
    "> Some HelmReleases failed to render and their objects are left out of the diff, see the [run logs](\($run)).",
    "",
    (if .suppressed != [] then
      "| HelmRelease | Side | Objects | Reason |", "|---|---|---|---|",
      (.suppressed[] | "| `\(.parent | id)` | \(.side | side) | \(.count) | \(.reason | esc) |"),
      ""
    else empty end)
  else empty end),
  (if $groups[0] != [] then
    "| HelmRelease | Chart | Added | Changed | Removed |", "|---|---|--:|--:|--:|",
    ($groups[0][] | "| `\(.id)` | \(if .charts == [] then "—" else .charts[:3] + (if (.charts | length) > 3 then ["+\((.charts | length) - 3) more"] else [] end) | join("<br>") end) | \(.added | cell) | \(.changed | cell) | \(.removed | cell) |"),
    ""
  else empty end)' "$work/diff.json" > "$work/header.md"

# Keep whole sections only: an overflowing diff is replaced by a link, never cut midway
cp "$work/header.md" comment-full.md
cp "$work/header.md" comment.md
for ((g = 0; g < ngroups; g++)); do
  cat "$work/section-$g.md" >> comment-full.md
  # Leave room for the link line of every section after this one
  reserve=$(( (ngroups - g) * 200 ))
  if (( $(wc -c < comment.md) + $(wc -c < "$work/section-$g.md") + reserve <= MAX_CHARS )); then
    cat "$work/section-$g.md" >> comment.md
  else
    id=$(jq -r --argjson g "$g" '.[$g].id' "$work/groups.json")
    printf -- '- `%s`: diff too long for a comment, see the [run summary](%s).\n' "$id" "$RUN_URL" >> comment.md
  fi
done
