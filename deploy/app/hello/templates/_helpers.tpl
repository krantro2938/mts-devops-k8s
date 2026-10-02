{{- define "hello.labels" -}}
app.kubernetes.io/name: hello
app.kubernetes.io/part-of: mts-demo
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end }}

{{- define "hello.selector" -}}
app.kubernetes.io/name: hello
app.kubernetes.io/version: {{ .version }}
{{- end }}

{{/* Response header added by the Gateway on every app route (visible with curl -i). */}}
{{- define "hello.gwHeader" -}}
- type: ResponseHeaderModifier
  responseHeaderModifier:
    set:
      - name: X-Served-By
        value: envoy-gateway
{{- end }}
