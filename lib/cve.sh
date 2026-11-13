#!/usr/bin/env bash
# Usage:
#   cve.sh scan <targets.json>   writes one scan-<name>-<n>.json per target into OUT_DIR
#   cve.sh render <scan.json>... writes comment.md, plus comment-full.md without row nor size limit
# A target is {name, new_label, new_source, old_label?, old_source?}, sources being grype
# ones (registry:, docker-archive:...): scan compares the new image with the old one.
# SEVERITIES (comma or space separated) picks the severities listed in detail and
# counted as fixable.
set -euo pipefail

: "${GRYPE:=grype}" "${PLATFORM:=linux/amd64}" "${OUT_DIR:=.}" "${MAX_ROWS:=30}" "${MAX_CHARS:=60000}"
: "${HEAD_SHA:=}" "${RUN_URL:=}" "${TITLE:=Image CVEs}" "${NAME_HEADER:=Image}" "${NOTES:=}"
: "${SEVERITIES:=Critical,High}"

# Canonical severities in rank order, such as ["Critical","High"]; fails on an unknown one
SEVERITY_LIST=$(jq -cn --arg s "$SEVERITIES" '
  def rank: {Critical: 0, High: 1, Medium: 2, Low: 3, Negligible: 4, Unknown: 5}[.];
  [$s | ascii_downcase | splits("[ ,]+") | select(. != "") | (.[:1] | ascii_upcase) + .[1:]]
  | unique | sort_by(rank)
  | if . == [] or any(rank == null) then error("SEVERITIES: expected Critical, High, Medium, Low, Negligible or Unknown, got \($s)") end')
SEVERITY_LABEL=$(jq -r 'join("/")' <<< "$SEVERITY_LIST")
: "${INTRO:=Grype, \`$PLATFORM\`, counts read old → new. One count per CVE, whatever the number of packages it hits; fixable = $SEVERITY_LABEL with a fix released.}"

# Prints the deduplicated matches of a grype source, or null when the scan fails
scan() {
  local out platform=()
  out=$(mktemp)
  [[ $1 == registry:* ]] && platform=(--platform "$PLATFORM")
  if "$GRYPE" "$1" ${platform[@]+"${platform[@]}"} -o json -q > "$out"; then
    jq '[.matches[] | {
      id: .vulnerability.id, severity: .vulnerability.severity,
      pkg: .artifact.name, version: .artifact.version,
      fix: ((.vulnerability.fix.versions // []) | join(", ")),
      url: (.vulnerability.dataSource // "")
    }] | unique_by([.id, .pkg])' "$out"
  else
    echo "::warning::grype failed on $1" >&2
    echo null
  fi
}

scan_all() {
  local n i t nv ov
  n=$(jq length "$1")
  (( n > 0 )) || return 0
  "$GRYPE" db update -q
  export GRYPE_DB_AUTO_UPDATE=false
  nv=$(mktemp) ov=$(mktemp)
  for ((i = 0; i < n; i++)); do
    t=$(jq -c --argjson i "$i" '.[$i]' "$1")
    scan "$(jq -r .new_source <<< "$t")" > "$nv"
    if [[ $(jq -r '.old_source // ""' <<< "$t") != "" ]]; then scan "$(jq -r .old_source <<< "$t")"; else echo null; fi > "$ov"
    # Named after the image so that the scans of several jobs can share one directory
    jq --slurpfile nv "$nv" --slurpfile ov "$ov" \
      '{name, new_label, old_label: (if .old_source then .old_label // .old_source else null end), nv: $nv[0], ov: $ov[0]}' \
      <<< "$t" > "$OUT_DIR/scan-$(jq -r '.name | gsub("[^A-Za-z0-9._-]"; "_")' <<< "$t")-$i.json"
  done
}

render() {
  jq -r -n --slurpfile items <(if (( $# > 2 )); then jq -s 'sort_by(.name)' "${@:3}"; else echo '[]'; fi) \
    --arg sha "${HEAD_SHA::7}" --arg run "$RUN_URL" --argjson rows "$2" --argjson details "$1" \
    --arg title "$TITLE" --arg intro "$INTRO" --arg header "$NAME_HEADER" --arg notes "$NOTES" \
    --argjson listed "$SEVERITY_LIST" --arg label "$SEVERITY_LABEL" '
    def rank: {Critical: 0, High: 1, Medium: 2, Low: 3}[.severity] // 4;
    # grype reports a CVE once per binary package built from the same source: one entry per CVE
    def cves: if . == null then null else group_by(.id) | map(sort_by(rank) | {
      id: .[0].id, severity: .[0].severity, url: .[0].url, version: .[0].version,
      pkgs: (map(.pkg) | unique), fix: (map(.fix | select(. != "")) | unique | join(", "))
    }) end;
    def count($s): map(select(.severity == $s)) | length;
    def severe: map(select(.severity | IN($listed[]))) | sort_by(rank, .fix == "", .id);
    def fixable: severe | map(select(.fix != "")) | length;
    def cell($o; $n):
      if $o == null then "\($n)"
      elif $n > $o then "\($o) → \($n) 🔺"
      elif $n < $o then "\($o) → \($n) ✅"
      else "\($n)" end;
    def more($n): "…and \($n) more" + (if $run != "" then ", see the [run summary](\($run))." else "." end);
    def table($vulns; $added):
      # Added CVEs first, so that the row limit never hides one
      ($vulns | sort_by((.id | IN($added[]) | not), rank, .fix == "", .id)) as $vulns
      | "| CVE | Severity | Packages | Version | Fixed in |", "|---|---|---|---|---|",
      ($vulns[:$rows][] | "| \(if .id | IN($added[]) then "🆕 " else "" end)"
        + "\(if .url != "" then "[\(.id)](\(.url))" else .id end) | \(.severity) | "
        + "\(.pkgs | map("`\(.)`") | join(" ")) | `\(.version)` | \(.fix) |"),
      (if ($vulns | length) > $rows then "", more(($vulns | length) - $rows) else empty end),
      "";

    $items[0] | map(.nv |= cves | .ov |= cves) as $items
    | "### \($title) (\($sha))", "",
      (if $notes != "" then $notes, "" else empty end),
      (if $items == [] then empty else $intro, "",
      "| \($header) | Version | Critical | High | Medium | Low | Fixable |", "|---|---|---|---|---|---|---|" end),
      ($items[] | . as $i
        | "| `\(.name)` | \(if .old_label then "`\(.old_label)` → " else "new " end)`\(.new_label)`"
        + (if .old_label and .ov == null then " (old scan failed ⚠️)" else "" end) + " | "
        + (if .nv == null then "⚠️ scan failed | | | | |"
           else ["Critical", "High", "Medium", "Low"]
             | map(. as $s | cell(if $i.ov == null then null else $i.ov | count($s) end; $i.nv | count($s)))
             + [cell(if $i.ov == null then null else $i.ov | fixable end; $i.nv | fixable)]
             | join(" | ") + " |" end)),
      "",
      (if $details then
        $items[] | select(.nv != null)
        | (.nv | severe) as $current
        | (.ov // [] | map(.id)) as $old
        | (if .ov == null then [] else $current | map(.id | select(IN($old[]) | not)) end) as $added
        | (.ov // [] | severe | map(select(.id | IN($current[].id) | not))) as $fixed
        | "<details><summary><code>\(.name)</code>: \($current | length) \($label), \($current | map(select(.fix != "")) | length) fixable"
          + "\(if .ov == null then "" else ", \($added | length) added, \($fixed | length) fixed" end)</summary>", "",
          (if $current == [] then "No \($label) vulnerability.", "" else table($current; $added) end),
          (if $fixed == [] then empty else "**Fixed**", "", table($fixed; []) end),
          "</details>", ""
      else
        "\($label) details are too long for a comment: see the [run summary](\($run))."
      end)'
}

case $1 in
  scan)
    scan_all "$2"
    ;;
  render)
    shift
    render true 1000000 "$@" > comment-full.md
    render true "$MAX_ROWS" "$@" > comment.md
    if (( $(wc -c < comment.md) > MAX_CHARS )); then render false "$MAX_ROWS" "$@" > comment.md; fi
    ;;
  *)
    echo "usage: $0 scan <targets.json> | render <scan.json>..." >&2
    exit 2
    ;;
esac
