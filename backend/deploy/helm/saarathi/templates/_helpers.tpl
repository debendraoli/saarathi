{{/*
Standard labels applied to every resource this chart creates.
*/}}
{{- define "saarathi.labels" -}}
app.kubernetes.io/part-of: saarathi
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{/*
Labels for one component's own resources (Deployment/StatefulSet + its Pods'
selector) — "component" is the service/piece name, e.g. "rides", "postgres".
*/}}
{{- define "saarathi.componentLabels" -}}
{{ include "saarathi.labels" . }}
app.kubernetes.io/name: {{ .component }}
{{- end -}}

{{/*
Full image reference for a backend service: <registry>/<name>:<tag>
*/}}
{{- define "saarathi.serviceImage" -}}
{{ .root.Values.image.registry }}/{{ .name }}:{{ .root.Values.image.tag }}
{{- end -}}
