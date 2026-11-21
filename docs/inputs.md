# Action inputs

Every input of every action, with its default. Back to the [README](../README.md).

## flux-setup

| Input | Default | Description |
|---|---|---|
| `sops-values-pattern` | `*.y*ml` | `find -name` pattern of the SOPS-encrypted YAML files to give placeholders: Helm values, and the Secrets and ConfigMaps a `valuesFrom` or a `substituteFrom` reads, see [SOPS](sops.md); empty to leave them all encrypted |
| `api-versions` | Prometheus Operator, Gateway API, cert-manager, VolumeSnapshot | CRD APIs the render treats as installed in the cluster, see [Charts using CRDs](flux-diff.md#charts-using-crds) |

## flux-diff (and its former name, `helm-diff`)

| Input | Default | Description |
|---|---|---|
| `path` | required | Cluster directory holding the Flux bootstrap objects |
| `marker` | `helm-diff` | Tag of the comment, kept from the former name so that existing comments keep updating |
| `kustomizations` | `auto` | Kustomizations to list: `auto` (`remote,source,shared,edited`), `all`, `none`, or a list of those reasons and `direct` (changes the git diff shows), see [Flux diff](flux-diff.md#what-the-git-diff-hides-in-kustomizations) |
| `kustomization-skip-kinds` | `Secret` | Comma-separated kinds left out of the Kustomization diff |
| `allow-missing-kinds` | empty | Comma-separated kinds (`Secret`, `ConfigMap`, `CustomResourceDefinition`) the render may do without, with a warning, see [Objects that only exist in the cluster](sops.md#objects-that-only-exist-in-the-cluster) |
| `comment-when-unchanged` | `true` | Post a short comment when nothing renders differently; `false` only refreshes an existing comment |
| `max-chars` | `60000` | Size above which a section is replaced by a link to the run summary |
| `token`, `author` | workflow token, `github-actions[bot]` | Identity that writes the comment |

## flux-images (outputs: `targets`, `notes`)

| Input | Default | Description |
|---|---|---|
| `path` | required | Cluster directory holding the Flux bootstrap objects |
| `max-images` | `20` | Images listed at most, the others are counted in the notes |
| `allow-missing-kinds` | empty | Comma-separated kinds (`Secret`, `ConfigMap`, `CustomResourceDefinition`) the render may do without, with a warning, see [Objects that only exist in the cluster](sops.md#objects-that-only-exist-in-the-cluster) |

## cve-scan (output: `dir`)

| Input | Default | Description |
|---|---|---|
| `targets` | | JSON file of `[{name, new_label, new_source, old_label?, old_source?}]`, as `flux-images` writes it |
| `name`, `new-source`, `new-label`, `old-source`, `old-label` | | Single image mode, instead of `targets` |
| `notes` | | Markdown file shown above the report table |
| `platform` | `linux/amd64` | Platform scanned for multi-arch images |
| `cache-db` | `false` | Keep the grype database in the Actions cache |
| `output-dir` | `$RUNNER_TEMP/cve-scans` | Directory receiving the scans |
| `artifact-name` | `cve-scans` | Artifact holding the scans, empty to skip the upload |

## cve-report

| Input | Default | Description |
|---|---|---|
| `artifact-pattern` | `cve-scans` | Artifacts to download, empty when the scans are local |
| `scans-dir` | `$RUNNER_TEMP/cve-scans` | Directory holding the scans |
| `marker` | `image-cves` | Tag of the comment |
| `title`, `name-header`, `intro` | `Image CVEs`, `Image`, default line | Comment heading, first column header, line under the heading |
| `noop-message` | `✅ No container image changed.` | Line under the heading when no image changed. The heading already shows the head commit; `{sha}` in the message is replaced by it too |
| `comment-when-unchanged` | `true` | Post the `noop-message` comment when no image changed; `false` only refreshes an existing comment |
| `platform` | `linux/amd64` | Platform named in the default intro |
| `severities` | `Critical,High` | Severities listed in detail and counted as fixable |
| `max-rows` | `30` | Rows per CVE table in the comment; the run summary keeps them all |
| `max-chars` | `60000` | Size above which the lists are replaced by a link to the run summary |
| `token`, `author` | workflow token, `github-actions[bot]` | Identity that writes the comment |

## pr-comment

| Input | Default | Description |
|---|---|---|
| `marker` | required | Unique tag of the comment, stored as a hidden HTML comment |
| `body-file` | required | Markdown file holding the comment body |
| `update-only` | `false` | Only refresh an existing comment, never create one |
| `token`, `author` | workflow token, `github-actions[bot]` | Identity that writes the comment |
