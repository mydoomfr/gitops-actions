{{- if .Values.x }}
sops:
    mac: ENC[AES256_GCM,data:x,iv:y,tag:z,type:str]
{{- end }}
