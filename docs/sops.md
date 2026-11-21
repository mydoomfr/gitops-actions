# SOPS without the private key

How `flux-setup` makes SOPS-encrypted files renderable in CI, which never holds the
key. Back to the [README](../README.md).

## Encrypted Helm values

SOPS encrypts values, never keys: the structure of an encrypted values file stays
readable. `flux-setup` keeps that structure and swaps each encrypted leaf for a
placeholder of the same type, so the chart renders without decryption:

```yaml
# values.enc.yaml in the repository          # what is rendered
auth:                                         auth:
  password: ENC[AES256_GCM,...,type:str]        password: "# sops-redacted"
  existingSecretName: ENC[...,type:str]         existingSecretName: sops-redacted
persistence:                                  persistence:
  enabled: ENC[AES256_GCM,...,type:bool]        enabled: true
replicas: ENC[AES256_GCM,...,type:int]        replicas: 1
```

Strings become `# sops-redacted`, a YAML comment wherever a chart inlines it, except
keys ending in `name` that may end up in `metadata.name`, which get a valid DNS label.
Since both sides get the same placeholders, a change to an encrypted value is not
shown, and an encrypted `false` renders as `true`. The files are the YAML files
matching the `sops-values-pattern` input (`*.y*ml`) that hold SOPS metadata.

## Secrets read by `valuesFrom` and `substituteFrom`

Without the key, the encrypted keys of a Secret are dropped: a HelmRelease whose
`valuesFrom` needs one fails to render, and a Kustomization `postBuild.substituteFrom`
variable is left as `${VAR}`, or replaced by its `${VAR:=default}` or an empty string
when substitution runs anyway (other readable or inline variables, or the `Always`
strategy). `flux-setup` gives placeholders to the `data`, `stringData` and `binaryData`
of SOPS-encrypted Secrets and ConfigMaps too, without any dummy file to maintain:

```yaml
stringData:                                   # what is rendered
  s3-secret-key: ENC[AES256_GCM,...]            s3-secret-key: sops-redacted
  values.yaml: ENC[AES256_GCM,...]              values.yaml: "# sops-redacted"
data:
  DOMAIN: ENC[AES256_GCM,...]                   DOMAIN: c29wcy1yZWRhY3RlZA== # base64
```

- A key becomes `sops-redacted`, fit for a variable or a `targetPath` value. A key
  ending in `.yaml` or `.yml` holds whole values, so it becomes an empty document:
  only the values outside the Secret then reach the chart.
- The keys are the real ones: a missing key still fails the render, a wrong value
  does not.
- Narrow `sops-values-pattern`, or set it to `''`, to leave files encrypted.

## Objects that only exist in the cluster

A `valuesFrom` or `substituteFrom` object that is not in the repository at all, such as
a Secret created by External Secrets or by hand, fails its render. List its kind in the
`allow-missing-kinds` input of `flux-diff` and `flux-images` to render without it:

```yaml
- uses: mydoomfr/gitops-actions/flux-diff@<sha> # v1.2.0
  with:
    path: clusters/production
    allow-missing-kinds: Secret,ConfigMap
```

The render then warns once per missing reference: a `valuesFrom` is left out of the
values, a `substituteFrom` variable is left unsubstituted or empty. The setting is
broad: with `Secret`, a Flux source whose credentials CI lacks is skipped too, so a real
error can hide behind a warning. Leave it empty, the default, unless such objects exist.

## Limits

- A placeholder is a string: a chart or a manifest that needs a number or a boolean
  from an encrypted Secret key may not render.
- SOPS-encrypted `.env` and JSON files, such as a `secretGenerator` reads, are not
  handled. Neither are manifests encrypted whole, without an `encrypted_regex` such as
  `^(data|stringData|binaryData)$`, nor YAML files yq cannot parse (warned): they are
  rendered as they are.
