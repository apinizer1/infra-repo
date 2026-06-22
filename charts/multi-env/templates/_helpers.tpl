{{- define "multi-env.name" -}}{{ default .Chart.Name .Values.nameOverride }}{{- end -}}
{{- define "multi-env.fullname" -}}{{ .Release.Name }}{{- end -}}

{{- define "multi-env.labels" -}}
app.kubernetes.io/name: {{ include "multi-env.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- define "multi-env.selectorLabels" -}}
app.kubernetes.io/name: {{ include "multi-env.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}