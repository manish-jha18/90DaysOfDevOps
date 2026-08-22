{{/*
Chart name, overridable via nameOverride.
*/}}
{{- define "devboard.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Fully qualified name: <release>-<chart>. Truncated to 63 chars because
that is the kubernetes limit for a DNS label.
*/}}
{{- define "devboard.fullname" -}}
{{- printf "%s-%s" .Release.Name (include "devboard.name" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Labels every resource should carry.
*/}}
{{- define "devboard.labels" -}}
app.kubernetes.io/name: {{ include "devboard.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
{{- end -}}

{{/*
Selector labels - a SUBSET of the above. These must never change,
because a Deployment's selector is immutable.
*/}}
{{- define "devboard.selectorLabels" -}}
app.kubernetes.io/name: {{ include "devboard.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}
