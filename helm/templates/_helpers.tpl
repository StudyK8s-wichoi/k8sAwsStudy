{{/*
Chart label
*/}}
{{- define "study.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "study.labels" -}}
helm.sh/chart: {{ include "study.chart" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}
