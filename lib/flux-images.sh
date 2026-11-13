#!/usr/bin/env bash
# Usage: flux-images.sh <diff.json>...
# Reads `flate diff hr|ks -o json` outputs and writes targets.json for cve.sh: every
# image the PR adds, paired with the image of the same repository it removes. Writes
# notes.md for the report (incomplete render, images over MAX_IMAGES), empty when there
# is none.
set -euo pipefail

: "${MAX_IMAGES:=20}" "${PARTIAL:=}" "${RUN_URL:=}"

# A file is empty when flate short-circuits identical trees, an array for multi-cluster repos
jq -s 'map(if type == "array" then .[] else . end)
  | {changes: map(.changes // [] | .[]), suppressed: map(.suppressed // [] | .[])}' "$@" > diff-normalized.json

jq --argjson max "$MAX_IMAGES" '
  # Image fields only: container specs, plus the image/imageName of operator CRs
  def refs: [.. | objects | to_entries[] | select(.key == "image" or .key == "imageName")
    | .value | strings | select(test("^\\S+[:@][^\\s/]+$"))];
  def repo: sub("@.*$"; "") | sub(":[^:/]*$"; "");
  def shown($repo): .[($repo | length):] | ltrimstr(":") | sub("sha256:(?<d>[0-9a-f]{7})[0-9a-f]*"; "\(.d)");
  ([.changes[].old | refs] | add // [] | unique) as $old
  | ([.changes[].new | refs] | add // [] | unique) as $new
  | (($old - $new) | map({key: repo, value: .}) | from_entries) as $removed
  | ($new - $old) | map(repo as $r | {name: $r, new_label: shown($r), new_source: "registry:\(.)"}
      + (if $removed[$r] then {old_label: ($removed[$r] | shown($r)), old_source: "registry:\($removed[$r])"} else {} end))
  | {targets: .[:$max], skipped: ([length - $max, 0] | max)}' diff-normalized.json > images.json

jq '.targets' images.json > targets.json

jq -r --arg partial "$PARTIAL" --arg run "$RUN_URL" --slurpfile images images.json '
  def id: if (.namespace // "") != "" then "\(.namespace)/\(.name)" else .name end;
  (if $partial != "" or .suppressed != [] then
    "> [!WARNING]",
    "> Some resources failed to render, so their images may be missing: see the [run logs](\($run)).",
    (.suppressed[] | ">", "> - `\(.parent | id)`: \(.reason | gsub("\n"; " "))")
  else empty end),
  (if $images[0].skipped > 0 then "", "\($images[0].skipped) more image(s) not scanned." else empty end)' \
  diff-normalized.json > notes.md
