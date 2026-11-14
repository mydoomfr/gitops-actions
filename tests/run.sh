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
MAX_ROWS=1 RUN_URL=https://example.com/run "$lib/cve.sh" render scan-docker.io_traefik-0.json
check "lists added CVEs before the row limit" bash -c 'grep -A2 "^| CVE" comment.md | grep -q "🆕 \[CVE-4\]"'
check "links the run summary past the row limit" grep -q '^…and 1 more, see the \[run summary\](https://example.com/run)\.$' comment.md
check "keeps every row in the summary" bash -c 'grep -q "\[CVE-2\]" comment-full.md && grep -q "\[CVE-4\]" comment-full.md && ! grep -q "…and" comment-full.md'
SEVERITIES=critical "$lib/cve.sh" render scan-docker.io_traefik-0.json
check "counts fixable CVEs of the chosen severities" grep -q '| 1 → 2 🔺 | 1 | 0 | 1 → 0 ✅ |$' comment.md
check "lists only the chosen severities" bash -c 'grep -q "0 Critical, 0 fixable, 0 added, 1 fixed" comment.md && grep -q "^No Critical vulnerability\.$" comment.md'
SEVERITIES='High medium' "$lib/cve.sh" render scan-docker.io_traefik-0.json
check "lists several chosen severities" bash -c 'grep -q "3 High/Medium," comment.md && grep -q "\[CVE-3\]" comment.md'
check "rejects an unknown severity" bash -c '! SEVERITIES=urgent "$1" render scan-docker.io_traefik-0.json' _ "$lib/cve.sh"
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

echo "# flux-diff"
mkdir "$work/flux-diff" && cd "$work/flux-diff"
HEAD_SHA=abcdef0123456 "$lib/flux-diff-comment.sh" "$fixtures/flate-diff.json"
check "one row per producer" bash -c 'grep -q "^| \`flux-system/traefik\` | \`traefik\` 42.3.2 |  | 1 |  |" comment.md'
check "a unified diff per producer" grep -q '^+          image: docker.io/traefik@sha256:b' comment.md
check "warns about suppressed renders" grep -q '| `apps/broken` | PR | 3 |' comment.md
echo '{"changes": [], "suppressed": []}' > empty.json
"$lib/flux-diff-comment.sh" empty.json
check "writes noop when nothing changed" test -f noop

echo "# flux-diff with Kustomizations"
mkdir "$work/ks-diff" && cd "$work/ks-diff"
: > hr.json
HEAD_SHA=abcdef0123456 RUN_URL=https://example.com/run "$lib/flux-diff-comment.sh" hr.json "$fixtures/flate-diff-ks.json"
check "one row per Kustomization with its path" grep -q '^| `flux-system/gateway-api-crds` | — | `config/crd/experimental` | 1 | 2 |  |$' comment.md
check "diffs plain manifests" grep -q '^+          image: traefik/whoami:v1.11.0$' comment.md
check "summarizes a CRD change" grep -q '^| `httproutes.gateway.networking.k8s.io` | v1 (storage) → v1 (storage), v1beta1 | v1: +3 (`spec.rules\[\].cors`) −1 (`spec.rules\[\].legacy`) |$' comment.md
check "summarizes a new CRD" grep -q '^| `xtelemetrypolicies.gateway.networking.x-k8s.io` | new: v1alpha1 (storage) | — |$' comment.md
check "keeps raw CRD diffs out of the comment" bash -c '! grep -q "^--- CustomResourceDefinition" comment.md && grep -q "^--- CustomResourceDefinition" comment-full.md'
check "never shows a Secret value" bash -c '! grep -E "b2xkLXNlY3JldA|bmV3LXNlY3JldA|YWRtaW4|YWRkZWQta2V5|plain-token" comment-full.md'
check "flags the Secret keys that changed" bash -c 'grep -q "^+  password: <redacted, changed>$" comment.md && grep -q "^ *user: <redacted>$" comment.md && grep -q "^+  apikey: <redacted>$" comment.md'
check "leaves out the values ConfigMaps of a changed HelmRelease" bash -c '! grep -q "ConfigMap flux-system/traefik-values" comment-full.md && grep -q "^--- HelmRelease flux-system/traefik$" comment.md'
"$lib/flux-diff-comment.sh" "$work/flux-diff/empty.json" hr.json
check "writes noop when neither render changed" test -f noop
rm -f noop
MAX_CHARS=1500 RUN_URL=https://example.com/run "$lib/flux-diff-comment.sh" hr.json "$fixtures/flate-diff-ks.json"
check "links the run summary for a section over MAX_CHARS" bash -c 'grep -q "^- \`flux-system/gateway-api-crds\`: diff too long for a comment, see the \[run summary\](https://example.com/run)\.$" comment.md && grep -q "httproutes" comment-full.md'

echo "# Kustomization scope"
mkdir "$work/scope" && cd "$work/scope"
git init -q -b main pr
commit() { git -C pr add -A && git -C pr -c user.name=t -c user.email=t@example.com -c commit.gpgsign=false commit -qm "$1"; }
kustomization() { # <dir> <resource>...
  mkdir -p "pr/$1"
  { echo "resources:"; printf '  - %s\n' "${@:2}"; } > "pr/$1/kustomization.yaml"
}
mkdir -p pr/apps/whoami pr/apps/shared pr/clusters/test
echo "image: whoami:1" > pr/apps/whoami/deployment.yaml
echo "data: 1" > pr/apps/shared/configmap.yaml
kustomization apps/overlay ../shared
kustomization infra/gw https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.6.3/experimental-install.yaml
kustomization infra/nested github.com/example/deploy//base?ref=v1
kustomization infra/remote-base ../nested
kustomization apps/comp deployment.yaml
mkdir -p pr/infra/ssh && printf 'resources:\n  - git@github.com:example/deploy.git//base?ref=v1\n' > pr/infra/ssh/Kustomization
mkdir -p pr/apps/my.app pr/apps/myXapp && echo "a: 1" > pr/apps/my.app/cm.yaml && echo "a: 1" > pr/apps/myXapp/cm.yaml
kustomization apps/img deployment.yaml
printf 'images:\n  - name: app\n    newTag: "1"\n' >> pr/apps/img/kustomization.yaml
printf 'apiVersion: kustomize.toolkit.fluxcd.io/v1\nkind: Kustomization\nmetadata:\n  name: crds\n  namespace: flux-system\nspec:\n  path: ./config/crd\n  sourceRef:\n    kind: GitRepository\n    name: gateway-api\n' > pr/clusters/test/crds.yaml
commit base
echo "image: whoami:2" > pr/apps/whoami/deployment.yaml
echo "data: 2" > pr/apps/shared/configmap.yaml
sed -i.bak 's/v1.6.3/v1.7.0/' pr/infra/gw/kustomization.yaml && rm pr/infra/gw/kustomization.yaml.bak
printf 'components:\n  - ../../components/common\n' >> pr/apps/comp/kustomization.yaml
echo "a: 2" > pr/apps/myXapp/cm.yaml
sed -i.bak 's/newTag: "1"/newTag: "2"/' pr/apps/img/kustomization.yaml && rm pr/apps/img/kustomization.yaml.bak
commit pr
git -C pr worktree add -q ../base HEAD^1
jq -n '{changes: [
  ["whoami", "apps/whoami"], ["overlay", "./apps/overlay"], ["gw", "infra/gw"],
  ["remote-base", "infra/remote-base"], ["crds", "config/crd"], ["comp", "apps/comp"], ["img", "apps/img"],
  ["ssh", "infra/ssh"], ["dotted", "apps/my.app"], ["lookalike", "apps/myXapp"], ["root", "."]
  ] | map({kind: "ConfigMap", name: "x", parent: {kind: "Kustomization", namespace: "flux-system", name: .[0], path: .[1]}})}' > ks.json
"$lib/kustomization-scope.sh" ks.json "$PWD/pr" "$PWD/base" > scope.json
scope() { jq -e --arg k "flux-system/$1" --arg why "$2" '.[$k].why == $why' scope.json; }
check "a Kustomization the pull request edits is direct" scope whoami direct
check "a shared base change is indirect" scope overlay indirect
check "a remote resource bump is remote" bash -c 'jq -e ".[\"flux-system/gw\"] | .why == \"remote\" and (.source | test(\"v1.7.0\"))" scope.json'
check "a remote base behind a local one is remote" scope remote-base remote
check "a component added to a kustomization is edited" scope comp edited
check "an images-only kustomization bump is direct" scope img direct
check "a git@ base in a Kustomization file is remote" scope ssh remote
check "a dot in a path only matches itself" bash -c 'jq -e ".[\"flux-system/dotted\"].why == \"indirect\" and .[\"flux-system/lookalike\"].why == \"direct\"" scope.json'
check "a root path sees every kustomization file the pull request edits" scope root edited
check "a path in another Flux source is external" bash -c 'jq -e ".[\"flux-system/crds\"] == {why: \"external\", source: \"gateway-api\"}" scope.json'

echo "# flux-diff with the Kustomization scope"
mkdir "$work/ks-scope" && cd "$work/ks-scope"
: > hr.json
jq -n '{"flux-system/gateway-api-crds": {why: "external", source: "gateway-api"}, "flux-system/app": {why: "indirect", source: ""},
  "flux-system/flux-system": {why: "direct", source: ""}, "flux-system/traefik": {why: "direct", source: ""},
  "flux-system/whoami": {why: "direct", source: ""}}' > scope.json
KS_SCOPE=scope.json "$lib/flux-diff-comment.sh" hr.json "$fixtures/flate-diff-ks.json"
check "says why a Kustomization is shown" bash -c 'grep -q "^| \`flux-system/gateway-api-crds\` | source \`gateway-api\` |" comment.md && grep -q "^| \`flux-system/app\` | shared base or variable |" comment.md'
check "only counts what the pull request diff shows" bash -c '! grep -q "whoami" comment-full.md && grep -q "^_3 more Kustomizations changed exactly as the pull request diff shows._$" comment.md'
KS_SCOPE=scope.json KS_MODE=all "$lib/flux-diff-comment.sh" hr.json "$fixtures/flate-diff-ks.json"
check "shows every Kustomization in all mode" bash -c 'grep -q "^| \`flux-system/whoami\` | edited here |" comment.md && ! grep -q "more Kustomization" comment.md'
KS_SCOPE=scope.json KS_MODE=remote,source "$lib/flux-diff-comment.sh" hr.json "$fixtures/flate-diff-ks.json"
check "lists only the chosen reasons" bash -c 'grep -q "^| \`flux-system/gateway-api-crds\` |" comment.md && ! grep -q "^| \`flux-system/app\` |" comment.md'
check "counts the Kustomizations a reason list leaves out" bash -c 'grep -q "^_1 more Kustomization changed, left out by the \`kustomizations\` input._$" comment.md && grep -q "^_3 more Kustomizations changed exactly as the pull request diff shows._$" comment.md'
check "rejects an unknown kustomizations value" bash -c '! KS_SCOPE=scope.json KS_MODE=remote,bogus "$1" hr.json "$2" 2> err.txt && grep -q "unknown value .bogus." err.txt' _ "$lib/flux-diff-comment.sh" "$fixtures/flate-diff-ks.json"
rm -f noop
KS_SCOPE=scope.json KS_MODE=none "$lib/flux-diff-comment.sh" "$fixtures/flate-diff.json" "$fixtures/flate-diff-ks.json"
check "lists no Kustomization with none" bash -c '! grep -q "^#### Kustomizations" comment.md && grep -q "^#### HelmReleases" comment.md'
jq '.changes |= map(if .name == "xtelemetrypolicies.gateway.networking.x-k8s.io" then .status = "removed" | .old = .new | .new = null
    elif .kind == "Secret" then .status = "added" | .old = null else . end)' "$fixtures/flate-diff-ks.json" > removed.json
"$lib/flux-diff-comment.sh" hr.json removed.json
check "summarizes a removed CRD" grep -q '^| `xtelemetrypolicies.gateway.networking.x-k8s.io` | removed | — |$' comment.md
check "never shows the values of an added Secret" bash -c '! grep -E "bmV3LXNlY3JldA|YWRtaW4|YWRkZWQta2V5|new-plain-token" comment-full.md && grep -q "^+  password: <redacted>$" comment.md'
jq '[., {changes: [.changes[] | select(.kind == "Deployment") | .parent.name = "whoami-prod"]}]' "$fixtures/flate-diff-ks.json" > multi.json
"$lib/flux-diff-comment.sh" hr.json multi.json
check "merges multi-cluster Kustomization outputs" bash -c 'grep -q "^| \`flux-system/whoami\` |" comment.md && grep -q "^| \`flux-system/whoami-prod\` |" comment.md'
jq '.suppressed = [{parent: {kind: "Kustomization", namespace: "flux-system", name: "broken"}, side: "current", count: 2, reason: "remote resource unreachable"}]' \
  "$fixtures/flate-diff-ks.json" > suppressed.json
PARTIAL=true RUN_URL=https://example.com/run "$lib/flux-diff-comment.sh" hr.json suppressed.json
check "warns about a Kustomization that failed to render" bash -c 'grep -q "^> Some HelmReleases or Kustomizations failed to render" comment.md && grep -q "^| \`flux-system/broken\` | PR | 2 | remote resource unreachable |$" comment.md'
jq 'with_entries(.value.why = "direct")' scope.json > direct.json
KS_SCOPE=direct.json "$lib/flux-diff-comment.sh" hr.json "$fixtures/flate-diff-ks.json"
check "opens no comment when the pull request diff shows everything" test -f noop

echo "# helm-diff alias"
check "helm-diff stays a copy of flux-diff" diff \
  <(yq -o json 'del(.name, .description)' "$root/flux-diff/action.yml") \
  <(yq -o json 'del(.name, .description)' "$root/helm-diff/action.yml")

echo
if (( failures > 0 )); then echo "$failures failure(s)"; exit 1; fi
echo "all passed"
