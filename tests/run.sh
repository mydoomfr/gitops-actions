#!/usr/bin/env bash
# Runs the lib scripts against fixtures, with fake grype and gh binaries.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
lib=$root/lib
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0

check() { # <description> <command...>
  if "${@:2}" > /dev/null; then echo "ok   $1"; else echo "FAIL $1"; failures=$((failures + 1)); fi
}

# Fake grype: answers from $GRYPE_FIXTURES/<sha1 of source>.json, fails otherwise
mkdir -p "$work/bin"
cat > "$work/bin/grype" << 'EOF'
#!/usr/bin/env bash
[[ $1 == db ]] && exit 0
echo "$*" >> "$GRYPE_LOG"
f=$GRYPE_FIXTURES/$(printf %s "$1" | shasum | cut -c1-12).json
[[ -f $f ]] && cat "$f"
EOF
# Fake gh: lists the comments of $GH_STATE, records PATCH and POST bodies
cat > "$work/bin/gh" << 'EOF'
#!/usr/bin/env bash
shift # api
case $1 in
  --paginate) jq -r "${4}" "$GH_STATE" ;;
  -X) echo "PATCH ${3##*/} $(cat "${5#body=@}")" >> "$GH_LOG" ;;
  *) echo "POST $(cat "${3#body=@}")" >> "$GH_LOG" ;;
esac
EOF
chmod +x "$work/bin/grype" "$work/bin/gh"
export PATH=$work/bin:$PATH GRYPE_FIXTURES=$work/grype GRYPE_LOG=$work/grype.log GH_LOG=$work/gh.log
fixtures=$root/tests/fixtures

# Grype fixtures, keyed like the fake grype reads them
vuln() { # id severity package version fix
  jq -n --arg id "$1" --arg s "$2" --arg p "$3" --arg v "$4" --arg f "$5" \
    '{vulnerability: {id: $id, severity: $s, dataSource: "https://example.com/\($id)", fix: {versions: (if $f == "" then [] else [$f] end)}},
      artifact: {name: $p, version: $v}}'
}
fixture() { mkdir -p "$GRYPE_FIXTURES"; jq -s '{matches: .}' > "$GRYPE_FIXTURES/$(printf %s "$1" | shasum | cut -c1-12).json"; }
{ vuln CVE-1 Critical libssl3 3.0 3.1; vuln CVE-1 Critical libcrypto3 3.0 3.1; vuln CVE-2 High zlib 1.2 1.3; vuln CVE-3 Medium curl 8 ""; } |
  fixture registry:docker.io/traefik@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
{ vuln CVE-2 High zlib 1.2 1.3; vuln CVE-4 High glibc 2.36 ""; vuln CVE-3 Medium curl 8 ""; } |
  fixture registry:docker.io/traefik@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
vuln CVE-5 High musl 1.2 1.3 | fixture registry:quay.io/hedgedoc/hedgedoc:1.12.0-alpine@sha256:2222222222222222222222222222222222222222222222222222222222222222
vuln CVE-6 Low busybox 1.36 "" | fixture docker-archive:/tmp/image.tar

echo "# flux-images"
mkdir "$work/flux" && cd "$work/flux"
MAX_IMAGES=20 "$lib/flux-images.sh" "$fixtures/flate-diff.json"
check "pairs a digest-only bump by repository" \
  jq -e '.[] | select(.name == "docker.io/traefik") | .old_label == "@aaaaaaa" and .new_label == "@bbbbbbb"' targets.json
check "pairs a Kustomization image bump" \
  jq -e '.[] | select(.name == "quay.io/hedgedoc/hedgedoc") | .old_source and .new_label == "1.12.0-alpine@2222222"' targets.json
check "lists a new image without an old one" \
  jq -e '.[] | select(.name == "ghcr.io/example/new") | has("old_source") | not' targets.json
check "ignores image strings outside image fields" jq -e 'map(.name) | index("ghcr.io/example/not-an-image") == null' targets.json
check "reports suppressed renders in the notes" grep -q 'apps/broken' notes.md

mkdir "$work/flux-split" && cd "$work/flux-split"
# hr and ks outputs as separate files, one a multi-cluster array, plus an empty one
jq '[{changes: [.changes[] | select(.parent.kind == "HelmRelease")], suppressed}]' "$fixtures/flate-diff.json" > hr.json
jq '{changes: [.changes[] | select(.parent.kind != "HelmRelease")]}' "$fixtures/flate-diff.json" > ks.json
: > empty.json
"$lib/flux-images.sh" hr.json ks.json empty.json
check "merges several flate outputs" bash -c "diff -q targets.json '$work/flux/targets.json' && diff -q notes.md '$work/flux/notes.md'"

mkdir "$work/flux-noop" && cd "$work/flux-noop"
echo '{"changes": [], "suppressed": []}' > diff.json
: > empty.json
"$lib/flux-images.sh" diff.json empty.json
check "no target nor note when nothing changed" bash -c '[[ $(jq length targets.json) == 0 && ! -s notes.md ]]'

mkdir "$work/flux-cap" && cd "$work/flux-cap"
MAX_IMAGES=1 "$lib/flux-images.sh" "$fixtures/flate-diff.json"
check "caps the targets and counts the rest" bash -c '[[ $(jq length targets.json) == 1 ]] && grep -q "2 more image" notes.md'

echo "# cve scan and render"
mkdir "$work/cve" && cd "$work/cve"
OUT_DIR=. "$lib/cve.sh" scan "$work/flux/targets.json"
jq -n '[{name: "app", new_label: "1.0", new_source: "docker-archive:/tmp/image.tar",
  old_label: "app:0.9", old_source: "registry:ghcr.io/example/missing:0.9"}]' > single.json
OUT_DIR=. "$lib/cve.sh" scan single.json
check "names scans after the image" test -f scan-docker.io_traefik-0.json
check "passes the platform to registry sources only" \
  bash -c 'grep -q "^registry:.* --platform linux/amd64" "$GRYPE_LOG" && grep -q "^docker-archive:[^ ]* -o json" "$GRYPE_LOG"'
check "records a failed scan as null" jq -e '.ov == null and .old_label == "app:0.9"' scan-app-0.json
HEAD_SHA=abcdef0123456 RUN_URL=https://example.com/run NOTES='> note' "$lib/cve.sh" render scan-*.json
check "counts a CVE once across its packages" grep -q '| `docker.io/traefik` | `@aaaaaaa` → `@bbbbbbb` | 1 → 0 ✅ | 1 → 2 🔺 | 1 | 0 | 2 → 1 ✅ |' comment.md
check "flags the CVEs the bump adds" grep -q '🆕 \[CVE-4\]' comment.md
check "lists the CVEs the bump fixes" bash -c 'grep -A4 "^\*\*Fixed\*\*" comment.md | grep -q "CVE-1.*\`libcrypto3\` \`libssl3\`"'
check "shows a failed old scan" grep -q 'app:0.9` → `1.0` (old scan failed ⚠️)' comment.md
check "puts the notes under the heading" bash -c 'sed -n 3p comment.md | grep -q "> note"'
MAX_CHARS=500 "$lib/cve.sh" render scan-*.json
check "drops the details over MAX_CHARS" bash -c 'grep -q "too long for a comment" comment.md && ! grep -q "<details>" comment.md && grep -q "<details>" comment-full.md'
NOTES='> warning' "$lib/cve.sh" render
check "renders notes without any scan" bash -c 'grep -q "> warning" comment.md && ! grep -q "^| Image" comment.md'

echo "# pr-comment"
cd "$work"
echo body > body.md
export GH_REPO=o/r PR=1 GH_STATE=$work/comments.json
echo '[{"id": 7, "user": {"login": "github-actions[bot]"}, "body": "<!-- other -->\nx"},
  {"id": 8, "user": {"login": "someone"}, "body": "<!-- cves -->\nx"}]' > comments.json
"$lib/pr-comment.sh" cves body.md --update-only
check "update-only creates nothing" test ! -s "$GH_LOG"
"$lib/pr-comment.sh" cves body.md
check "creates the comment with its marker" grep -q '^POST <!-- cves -->' "$GH_LOG"
: > "$GH_LOG"
echo '[{"id": 9, "user": {"login": "github-actions[bot]"}, "body": "<!-- cves -->\nold"}]' > comments.json
"$lib/pr-comment.sh" cves body.md
check "edits the comment carrying the marker" grep -q '^PATCH 9 <!-- cves -->' "$GH_LOG"

echo "# helm-diff"
mkdir "$work/helm-diff" && cd "$work/helm-diff"
HEAD_SHA=abcdef0123456 "$lib/helm-diff-comment.sh" "$fixtures/flate-diff.json"
check "one row per producer" bash -c 'grep -q "^| \`flux-system/traefik\` | \`traefik\` 42.3.2 |  | 1 |  |" comment.md'
check "a unified diff per producer" grep -q '^+          image: docker.io/traefik@sha256:b' comment.md
check "warns about suppressed renders" grep -q '| `apps/broken` | PR | 3 |' comment.md
echo '{"changes": [], "suppressed": []}' > empty.json
"$lib/helm-diff-comment.sh" empty.json
check "writes noop when nothing changed" test -f noop

echo
if (( failures > 0 )); then echo "$failures failure(s)"; exit 1; fi
echo "all passed"
