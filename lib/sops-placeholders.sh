#!/usr/bin/env bash
# Usage: sops-placeholders.sh <pattern> <dir>...
# Makes SOPS-encrypted YAML under <dir> renderable without the key, in place: every
# file whose name matches <pattern> (find -name, empty for none) and that holds a sops
# MAC. In each SOPS document of such a file, drops the sops metadata, keeps keys, maps
# and lists, and swaps each encrypted leaf for a typed placeholder (rules in the README,
# "SOPS without the private key"). flate drops encrypted keys, so a valuesFrom or
# substituteFrom Secret would otherwise lose the keys a render needs. Plain documents,
# manifests encrypted without encrypted_regex (apiVersion is ENC) and files yq cannot
# parse (warned) are left as they are.
set -euo pipefail

pattern=$1
shift
[[ -n $pattern ]] || exit 0
find "$@" -type f -name "$pattern" -not -path '*/.git/*' -print0 |
  { xargs -0 grep -lE --null '^ +mac: ENC\[AES256_GCM,' || true; } |
  while IFS= read -r -d '' file; do
    yq -i '
      with(select(tag == "!!map" and .sops.mac != null and ((.apiVersion // "") | tostring | test("^ENC\[") | not));
        del(.sops) | .kind as $kind |
        (select(.apiVersion == "v1" and ($kind == "Secret" or $kind == "ConfigMap")) | .[]
          | select(tag == "!!map" and (key == "data" or key == "stringData" or key == "binaryData")))
          |= ((key == "binaryData" or (key == "data" and $kind == "Secret")) as $b64 |
            with_entries(.key as $k | .value |= (select(tag == "!!str" and test("^ENC\[AES256_GCM,")) |=
              ((if ($k | test("(?i)\.ya?ml$")) then "# sops-redacted" else "sops-redacted" end) | select($b64) |= @base64)))) |
        (.. | select(tag == "!!str" and test("^ENC\[AES256_GCM,.*,type:bool\]$"))) = true |
        (.. | select(tag == "!!str" and test("^ENC\[AES256_GCM,.*,type:(int|float)\]$"))) = 1 |
        (.. | select(tag == "!!str" and test("^ENC\[AES256_GCM,") and (path | .[-1] | tostring | test("(?i)name$")))) = "sops-redacted" |
        (.. | select(tag == "!!str" and test("^ENC\[AES256_GCM,"))) = "# sops-redacted")' "$file" ||
      echo "::warning file=$file::sops-placeholders: yq cannot parse it, SOPS values left encrypted"
  done
