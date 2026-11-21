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
# The remote actions/checkout sets, here the fixture's own URL: a GitRepository on it
# reads the local trees
git -C pr remote add origin https://github.com/example/fleet.git
git -C pr add -A && commit base
cp -R "$fixtures/pr/." pr/
git -C pr add -A && commit pr
git -C pr worktree add -q ../base HEAD^1
# With the default pattern of flux-setup, so that the SOPS checks guard it; SOPS_PATTERN
# overrides it, empty to leave every SOPS file encrypted
pattern=${SOPS_PATTERN-$(yq '.inputs.sops-values-pattern.default' "$fixtures/../../../flux-setup/action.yml")}
"$fixtures/../../../lib/sops-placeholders.sh" "$pattern" pr base
