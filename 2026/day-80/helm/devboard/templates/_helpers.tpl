{{/*
Chart name, overridable with nameOverride.
*/}}
{{- define "devboard.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Fully qualified name: "<release>-<chart>". Naming resources this way is what
lets two releases of the same chart live in one namespace without colliding.
63 is the kubernetes limit for a DNS label; trimSuffix cleans up a trailing
dash left behind by truncation.
*/}}
{{- define "devboard.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name (include "devboard.name" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{/*
Labels stamped on every resource. Includes the chart version, so these
change on every chart bump.
*/}}
{{- define "devboard.labels" -}}
app.kubernetes.io/name: {{ include "devboard.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
{{- end -}}

{{/*
Selector labels - deliberately a SUBSET, with no version in it.
A Deployment's selector is immutable, so a version label here would make
every chart upgrade fail with "field is immutable".
*/}}
{{- define "devboard.selectorLabels" -}}
app.kubernetes.io/name: {{ include "devboard.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/*
Postgres connection string, assembled once so the backend and any job
cannot drift apart.
*/}}
{{- define "devboard.postgresUrl" -}}
{{- printf "postgres://%s:%s@%s:5432/%s?sslmode=disable" .Values.postgres.user .Values.postgres.password (include "devboard.fullname" .) .Values.postgres.database -}}
{{- end -}}
