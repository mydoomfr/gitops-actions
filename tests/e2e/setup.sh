#!/usr/bin/env bash
# Replaces pr/ and base/ in the current directory with the fixture trees, laid out like
# flux-setup does: pr/ a git checkout, base/ a worktree of its first parent, SOPS
# values swapped for placeholders.
# fixtures/base holds the whole tree, fixtures/pr only the files the change touches.
set -euo pipefail

fixtures=$(cd "$(dirname "$0")" && pwd)/fixtures
commit() { git -C pr -c user.name=e2e -c user.email=e2e@example.com -c commit.gpgsign=false commit -qm "$1"; }

rm -rf pr base
mkdir pr
cp -R "$fixtures/base/." pr/
git -C pr init -q -b main
git -C pr add -A && commit base
cp -R "$fixtures/pr/." pr/
git -C pr add -A && commit pr
git -C pr worktree add -q ../base HEAD^1
# With the default pattern of flux-setup, so that the SOPS checks guard it
"$fixtures/../../../lib/sops-placeholders.sh" "$(yq '.inputs.sops-values-pattern.default' "$fixtures/../../../flux-setup/action.yml")" pr base
