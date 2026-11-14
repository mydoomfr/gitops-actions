#!/usr/bin/env bash
# Usage: check.sh <flux-images output dir>
# Checks the real flate renders of the fixture change, after setup.sh and flux-images:
# every expected image and HelmRelease must be there, since flate may drop a render
# without any warning.
set -euo pipefail

images=$1
here=$(cd "$(dirname "$0")" && pwd)
lib=$here/../../lib
root=$PWD work=$(mktemp -d)
failures=0

check() { # <description> <command...>, its output shown on failure only
  if "${@:2}" > "$work/out" 2>&1; then
    echo "ok   $1"
  else
    echo "FAIL $1"
    cat "$work/out"
    failures=$((failures + 1))
  fi
}

echo "# flux-images"
check "lists the expected image pairs" \
  diff -u <(jq -S . "$here/expected/targets.json") <(jq -S . "$images/targets.json")
check "leaves no note" test ! -s "$images/notes.md"

echo "# helm-diff"
cd "$work"
unset FLATE_BASE
# Same render as the helm-diff action
rc=0
flate diff hr --path "$root/pr/clusters/e2e" --path-orig "$root/base/clusters/e2e" -o json > diff.json || rc=$?
check "renders without error" test "$rc" = 0
check "suppresses nothing" jq -e '.suppressed // [] | length == 0' diff.json
for release in traefik podinfo; do
  check "renders the $release Deployment" \
    jq -e --arg r "$release" 'any(.changes[]; .parent.name == $r and .kind == "Deployment")' diff.json
done
# Same Kustomization render as the helm-diff action, CRDs included
rc=0
flate diff ks --skip-kinds Secret --path "$root/pr/clusters/e2e" --path-orig "$root/base/clusters/e2e" -o json > ks.json || rc=$?
check "renders Kustomizations without error" test "$rc" = 0
"$lib/kustomization-scope.sh" ks.json "$root/pr" "$root/base" > scope.json
KS_SCOPE=scope.json HEAD_SHA=0000000 "$lib/helm-diff-comment.sh" diff.json ks.json
check "comments the chart bump" grep -q '^| `flux-system/podinfo` | `podinfo` 6.16.0 → 6.17.0 |' comment.md
check "diffs a remote resource bump" bash -c 'grep -q "^| \`flux-system/remote\` | remote \`raw.githubusercontent.com/…/6.17.0/kustomize/deployment.yaml\` |" comment.md && grep -q "^+ *image: ghcr.io/stefanprodan/podinfo:6.17.0$" comment.md'
check "summarizes a CRD from a shared base" bash -c 'grep -q "^| \`flux-system/crds\` | shared base or variable |" comment.md && grep -q "^| \`widgets.example.com\` | v1 (storage) | v1: +1 (\`spec.color\`) |$" comment.md'
check "diffs a component added to a kustomization" bash -c 'grep -q "^| \`flux-system/whoami\` | kustomization edited |" comment.md && grep -q "^+ *team: platform$" comment.md'
check "only counts the Kustomizations whose manifests the pull request edits" bash -c '! grep -q "^--- HelmRelease flux-system/podinfo" comment-full.md && grep -q "^_2 more Kustomizations changed exactly as the pull request diff shows._$" comment.md'
check "leaves out the values ConfigMaps of a changed HelmRelease" bash -c '! grep -q "^--- ConfigMap flux-system/traefik-values" comment-full.md'

echo
if (( failures > 0 )); then echo "$failures failure(s)"; exit 1; fi
echo "all passed"
