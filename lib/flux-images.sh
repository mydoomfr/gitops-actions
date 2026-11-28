#!/usr/bin/env bash
# Usage: flux-images.sh <diff.json>...
# Reads `flate diff -o json` outputs and writes targets.json for cve.sh: every image the
# PR adds, paired with the image of the same repository it replaces when that one is
# unambiguous. Writes notes.md for the report (incomplete render, images without a
# baseline, images over MAX_IMAGES), empty when there is none.
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
  # Pairs each removed and added ref of one repository, when it is the only one on each side
  def pairs: [group_by(.ref | repo)[] | map(select(.side == "old").ref) as $o | map(select(.side == "new").ref) as $n
    | select(($o | length) == 1 and ($n | length) == 1) | {old: $o[0], new: $n[0]}];
  # Refs one object removes and adds, tagged with their side
  def moves: (.old | refs | unique) as $o | (.new | refs | unique) as $n
    | [($o - $n)[] | {side: "old", ref: .}] + [($n - $o)[] | {side: "new", ref: .}];
  ([.changes[].old | refs] | add // [] | unique) as $old
  | ([.changes[].new | refs] | add // [] | unique) as $new
  | [.changes[] | moves] as $moves
  # Pairs within each object, then among the refs left unpaired in all of them (an object
  # renamed or moved to another producer), as konflate does
  | ([$moves[] | pairs[]]) as $local
  | ($local | map(.old, .new)) as $paired
  | ($local + ([$moves[][] | select(.ref | IN($paired[]) | not)] | unique | pairs)) as $pairs
  | ($old - $new | map(repo) | unique) as $replaced
  | ($new - $old) | map(. as $ref | repo as $r | ([$pairs[] | select(.new == $ref).old] | unique) as $from
      | {name: $r, new_label: shown($r), new_source: "registry:\(.)"}
      + if ($from | length) == 1 then {old_label: ($from[0] | shown($r)), old_source: "registry:\($from[0])"}
        elif $r | IN($replaced[]) then {ambiguous: true} else {} end)
  | {targets: (map(del(.ambiguous)) | .[:$max]), skipped: ([length - $max, 0] | max),
     ambiguous: (map(select(.ambiguous).name) | unique)}' diff-normalized.json > images.json

jq '.targets' images.json > targets.json

jq -r --arg partial "$PARTIAL" --arg run "$RUN_URL" --slurpfile images images.json '
  def id: if (.namespace // "") != "" then "\(.namespace)/\(.name)" else .name end;
  (if $partial != "" or .suppressed != [] then
    "> [!WARNING]",
    "> Some resources failed to render, so their images may be missing: see the [run logs](\($run)).",
    (.suppressed[] | ">", "> - `\(.parent | id)`: \(.reason | gsub("\n"; " "))")
  else empty end),
  ($images[0].ambiguous[] | "", "`\(.)`: several versions changed at once, scanned without the image each replaces."),
  (if $images[0].skipped > 0 then "", "\($images[0].skipped) more image(s) not scanned." else empty end)' \
  diff-normalized.json > notes.md
