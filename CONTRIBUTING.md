# Contributing

## Tests

`tests/run.sh` runs the scripts of `lib/` against fixtures, with fake `grype` and `gh`
binaries. CI also runs `shellcheck --severity=warning` on them.

The `e2e` workflow renders a fixture Flux change (`tests/e2e/fixtures`) with the
[flate](https://github.com/home-operations/flate) version pinned in `flux-setup`, and
checks the images, HelmReleases and Kustomization objects (a CRD among them) it must
find against `tests/e2e/expected`. It runs on every pull request that touches the Flux
actions, so a flate bump that changes the renders fails its Renovate pull request.

## Layout

- Each action is a composite action in its own directory (`flux-setup/`, `flux-diff/`...);
  `helm-diff/` is a copy of `flux-diff/` kept as an alias until v2, and `tests/run.sh`
  checks that they stay identical apart from `name` and `description`.
- The logic lives in `lib/*.sh`, called by the actions.

## Dependencies

Renovate keeps the action SHAs (`helpers:pinGitHubActionDigests`) and the flate version
up to date. The flate version is pinned twice in `flux-setup/action.yml`, as the action
SHA and as its `version` input: Renovate bumps both.
