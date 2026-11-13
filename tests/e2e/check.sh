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
HEAD_SHA=0000000 "$lib/helm-diff-comment.sh" diff.json
check "comments the chart bump" grep -q '^| `flux-system/podinfo` | `podinfo` 6.16.0 → 6.17.0 |' comment.md

echo
if (( failures > 0 )); then echo "$failures failure(s)"; exit 1; fi
echo "all passed"
