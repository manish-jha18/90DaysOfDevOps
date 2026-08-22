# Day 79 – Creating a Custom Helm Chart

The chart is in `helm/devboard/` in this folder. It packages the whole DevBoard stack — React frontend, Go API, Postgres — replacing the hand-written manifests from Days 51–60.

Using DevBoard rather than AI-BankApp, for the reason given on Day 78.

---

## Task 1: Scaffold and study the manifests

`helm create` produces a scaffold with a lot of boilerplate to delete. I wrote this one deliberately so every file has a reason.

```
helm/devboard/
├── Chart.yaml
├── values.yaml
├── .helmignore
├── files/
│   ├── 01_schema.sql
│   └── 02_seed.sql
└── templates/
    ├── _helpers.tpl
    ├── configmap.yaml
    ├── secret.yaml
    ├── postgres-statefulset.yaml
    ├── backend.yaml
    ├── frontend.yaml
    ├── hpa.yaml
    ├── ingress.yaml
    └── NOTES.txt
```

**What the raw manifests from Days 51–60 contained**, and what each becomes:

| Day | Manifest | Becomes |
|---|---|---|
| 52 | Namespace | Not templated — `--create-namespace` handles it |
| 54 | ConfigMap, Secret | `configmap.yaml`, `secret.yaml` |
| 56 | Headless Service + StatefulSet | `postgres-statefulset.yaml` |
| 57 | Deployment with probes | `backend.yaml`, `frontend.yaml` |
| 53 | Services | Folded into the deployment files |
| 58 | HPA | `hpa.yaml`, conditional |
| — | Ingress | `ingress.yaml`, conditional |

**Grouping a Deployment with its Service in one file** is a deliberate choice. They are always created and deleted together and share a selector, so keeping them adjacent means a change to the labels cannot update one and miss the other. Splitting by resource type looks tidier and makes that mistake easy.

---

## Task 2: Chart.yaml and values.yaml

```yaml
apiVersion: v2
name: devboard
description: DevBoard - a 3-tier task tracker (React + Go + Postgres) packaged for Kubernetes
type: application

version: 0.1.0
appVersion: "1.0.0"
```

`apiVersion: v2` is Helm 3. `v1` charts still install but cannot declare dependencies in `Chart.yaml`.

**`appVersion` is quoted** because `1.0` unquoted becomes the float `1` — Day 38's YAML typing rule, and it matters here because the templates use `.Chart.AppVersion` as an image tag fallback.

### values.yaml as the chart's API

The design question from Day 65 applies: what must the caller decide, and what can it decide for them?

```yaml
postgres:
  image: postgres:16-alpine
  user: devboard
  database: devboard
  password: devboard
  port: 5432
  storage:
    size: 1Gi
    storageClassName: ""
  resources:
    requests: { cpu: 50m, memory: 128Mi }
    limits: { cpu: 500m, memory: 256Mi }

backend:
  image:
    repository: manishjha18/devboard-backend
    tag: ""
    pullPolicy: IfNotPresent
  replicas: 1
  port: 8080
  resources: { ... }

frontend:
  image: { ... }
  service:
    type: ClusterIP
    nodePort: 30080
  hpa:
    enabled: false
    minReplicas: 1
    maxReplicas: 5
    targetCPUUtilizationPercentage: 60

ingress:
  enabled: false
  className: nginx
  host: devboard.local
  tls:
    enabled: false

observability:
  enabled: false
  otlpEndpoint: otel-collector.observability.svc.cluster.local:4317

probes:
  liveness:
    initialDelaySeconds: 15
    periodSeconds: 10
    failureThreshold: 3
  readiness: { ... }

nodeSelector: {}
tolerations: []
affinity: {}
podAnnotations: {}
```

**Four decisions worth explaining:**

**Grouped by component, not by resource type.** `backend.image` and `backend.resources` rather than `images.backend` and `resources.backend`. A caller changing the backend edits one block.

**`tag: ""` rather than a hardcoded default.** Empty falls back to `.Chart.AppVersion` in the template, so a chart bump alone can move the image tag — and a caller who wants a specific SHA just sets it.

**`storageClassName: ""` with a comment.** Empty means "cluster default", which on kind works and on EKS hangs the PVC Pending because nothing is marked default (Day 66). The comment is there because the failure gives no hint.

**Every probe timing is exposed.** A slow environment can loosen them without editing a template — Day 80's prod values do exactly that.

**`nodeSelector`, `tolerations`, `affinity` and `podAnnotations` empty at the bottom.** These cost nothing when unset and are painful to add later once people are running the chart, because it becomes a chart version bump. Day 80's prod values use `affinity`.

---

## Task 3: The core templates

### `_helpers.tpl`

```
{{- define "devboard.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name (include "devboard.name" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
```

Day 78's explanation — `trunc 63` for the DNS label limit, `trimSuffix "-"` because truncation can leave a trailing dash.

**The label split, which is the one that actually breaks charts:**

```
{{- define "devboard.labels" -}}
app.kubernetes.io/name: {{ include "devboard.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
{{- end -}}

{{- define "devboard.selectorLabels" -}}
app.kubernetes.io/name: {{ include "devboard.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}
```

**Selector labels are a strict subset with no version in them.** A Deployment's `selector` is immutable (Day 52), so a chart version in it makes every single upgrade fail with `field is immutable`. This is the single most common way a hand-written chart breaks on its second release.

**A helper for the connection string:**

```
{{- define "devboard.postgresUrl" -}}
{{- printf "postgres://%s:%s@%s:5432/%s?sslmode=disable" .Values.postgres.user .Values.postgres.password (include "devboard.fullname" .) .Values.postgres.database -}}
{{- end -}}
```

Assembled once so the backend and Postgres cannot drift apart. Day 54 built the same string with `$(VAR)` substitution and had to get the env-var ordering right; a helper removes that whole class of mistake.

### ConfigMap, with real files

```yaml
data:
  {{- (.Files.Glob "files/*.sql").AsConfig | nindent 2 }}
```

`.Files.Glob` reads `files/01_schema.sql` and `files/02_seed.sql` into ConfigMap keys. The SQL stays in `.sql` files where an editor highlights it and it can be run directly — much better than embedding it in a YAML block. Straight from devboard's chart.

### Secret

```yaml
type: Opaque
stringData:
  POSTGRES_PASSWORD: {{ .Values.postgres.password | quote }}
  POSTGRES_URL: {{ include "devboard.postgresUrl" . | quote }}
```

`stringData` rather than base64 `data`, so `helm template` output is readable — which matters when reviewing a rendered chart in CI.

**This is the weakest part of the chart and Day 80 addresses it.** A password in a values file is Day 27's leak. The right answer is an **ExternalSecret** pointing at AWS Secrets Manager, which is what devboard's real chart does.

### Postgres StatefulSet

Day 56's manifest, templated. Two details worth carrying forward:

```yaml
            - name: PGDATA
              value: /var/lib/postgresql/data/pgdata
```

A mounted volume always contains `lost+found`, and Postgres refuses to initialise into a non-empty directory. Day 55's crash loop, with an error that says nothing about volumes.

```yaml
          readinessProbe:
            exec:
              command: ["sh", "-c", "pg_isready -U $POSTGRES_USER -d $POSTGRES_DB"]
            initialDelaySeconds: 10
            periodSeconds: 5
          livenessProbe:
            exec:
              command: ["sh", "-c", "pg_isready -U $POSTGRES_USER -d $POSTGRES_DB"]
            initialDelaySeconds: 60
            periodSeconds: 20
```

**Liveness far more relaxed than readiness.** Readiness steers traffic and should react quickly; liveness kills the container and should be reluctant. Day 57's rule, and an aggressive liveness probe on a database restarts it exactly when it is busiest.

The `storageClassName` is conditional, because an empty string is not the same as omitting the field:

```yaml
        {{- if .Values.postgres.storage.storageClassName }}
        storageClassName: {{ .Values.postgres.storage.storageClassName | quote }}
        {{- end }}
```

`storageClassName: ""` explicitly means "no class, static binding only" and would break dynamic provisioning. Omitting it means "use the default". A subtle distinction with a confusing failure.

---

## Task 4: The deployment templates

### The config checksum

```yaml
      annotations:
        checksum/config: {{ include (print $.Template.BasePath "/configmap.yaml") . | sha256sum }}
        checksum/secret: {{ include (print $.Template.BasePath "/secret.yaml") . | sha256sum }}
```

**This is the most valuable line in the chart.** Day 54 established that a ConfigMap consumed as environment variables **never reaches running pods** — patch the ConfigMap and the pods keep the old value forever, with no error.

Hashing the rendered ConfigMap into a pod annotation changes the pod template whenever the config changes, which forces a rollout. `$.Template.BasePath` resolves to the chart's `templates/` directory, and `$` is the root context — `.` inside a `range` or `with` would be scoped and this would silently break.

### The init container

```yaml
      initContainers:
        - name: wait-for-postgres
          image: {{ .Values.postgres.image | quote }}
          command:
            - sh
            - -c
            - |
              until pg_isready -h {{ include "devboard.fullname" . }} -p {{ .Values.postgres.port }} -U {{ .Values.postgres.user }}; do
                echo "waiting for postgres..."
                sleep 2
              done
```

Kubernetes has no `depends_on` — Day 34's Compose feature does not exist here. An init container runs to completion before any app container starts, so the backend simply does not begin until Postgres answers.

**Reusing the Postgres image** because it already contains `pg_isready`. No extra image to build or pull.

Without this the backend crash-loops for the 30-odd seconds Postgres takes to initialise, which works eventually and looks broken in the meantime.

### Image tag with a fallback

```yaml
          image: "{{ .Values.backend.image.repository }}:{{ .Values.backend.image.tag | default .Chart.AppVersion }}"
```

An unset tag falls back to `appVersion`. So `helm upgrade` after bumping `appVersion` to `1.1.0` moves the image — and a caller pinning a SHA overrides it.

### Conditional observability

```yaml
            {{- if .Values.observability.enabled }}
            - name: OTEL_SERVICE_NAME
              value: devboard-backend
            - name: OTEL_EXPORTER_OTLP_ENDPOINT
              value: {{ .Values.observability.otlpEndpoint | quote }}
            - name: OTEL_RESOURCE_ATTRIBUTES
              value: "deployment.environment={{ .Release.Namespace }},service.namespace={{ .Release.Namespace }}"
            {{- end }}
```

Days 76–77's OTel wiring, off by default. `.Release.Namespace` as the environment attribute means the same chart tags its telemetry correctly in dev and prod with no extra values.

### Conditional replicas

```yaml
  {{- if not .Values.frontend.hpa.enabled }}
  replicas: {{ .Values.frontend.replicas }}
  {{- end }}
```

Day 58's conflict: an HPA owns the replica count, so leaving `replicas` in the manifest means every `helm upgrade` resets it and the HPA changes it back seconds later. Omitting the field entirely when the HPA is on is the fix.

### Optional scheduling

```yaml
      {{- with .Values.nodeSelector }}
      nodeSelector:
        {{- toYaml . | nindent 8 }}
      {{- end }}
```

**`with` rather than `if`** — it sets `.` to the value inside the block, so `toYaml .` renders it. And it skips the whole block when the value is empty, so an empty `nodeSelector: {}` produces no key at all rather than `nodeSelector: {}` in the manifest.

---

## Task 5: Services, HPA and Ingress

**Named ports** are the detail worth adopting:

```yaml
          ports:
            - containerPort: {{ .Values.backend.port }}
              name: http
```

```yaml
  ports:
    - port: {{ .Values.backend.port }}
      targetPort: http
```

`targetPort: http` refers to the **name**, not the number. Change the container port in values and the Service follows automatically — no chance of the two drifting apart, which was a real risk in Day 53's hand-written manifests.

**The Ingress path order matters:**

```yaml
          - path: /api
            pathType: Prefix
            backend: { ... backend service ... }
          - path: /
            pathType: Prefix
            backend: { ... frontend service ... }
```

Most specific first. `/` before `/api` would send everything to the frontend. Same reasoning as Day 72's nginx location blocks.

**Whole templates are conditional:**

```yaml
{{- if .Values.frontend.hpa.enabled }}
...
{{- end }}
```

Wrapping the entire file means it renders to nothing when disabled — not an empty document, nothing. Same for the Ingress. That is how one chart covers a local cluster with no ingress controller and a production cluster with one.

---

## Task 6: Validate and deploy

```
devops@testvm:~/day-79$ helm lint helm/devboard
==> Linting helm/devboard
[INFO] Chart.yaml: icon is recommended

1 chart(s) linted, 0 chart(s) failed
```

```
devops@testvm:~/day-79$ helm template devboard helm/devboard | head -20
---
# Source: devboard/templates/configmap.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: devboard-devboard-config
  labels:
    app.kubernetes.io/name: devboard
    app.kubernetes.io/instance: devboard
    app.kubernetes.io/version: "1.0.0"
    app.kubernetes.io/managed-by: Helm
    helm.sh/chart: devboard-0.1.0
data:
  POSTGRES_USER: "devboard"
  POSTGRES_DB: "devboard"
```

**`helm template` is the inner loop for chart development** — renders locally, no cluster, instant. This is where I found three whitespace bugs before ever installing anything.

```
devops@testvm:~/day-79$ helm template devboard helm/devboard | grep -c "^kind:"
9

devops@testvm:~/day-79$ helm template devboard helm/devboard | grep "^kind:" | sort | uniq -c
      2 kind: ConfigMap
      2 kind: Deployment
      1 kind: Secret
      3 kind: Service
      1 kind: StatefulSet
```

Nine resources. No HPA and no Ingress, because both are disabled by default.

**Validating against the real API server** catches what lint cannot:

```
devops@testvm:~/day-79$ helm template devboard helm/devboard | kubectl apply --dry-run=server -f -
configmap/devboard-devboard-config created (server dry run)
secret/devboard-devboard-secrets created (server dry run)
service/devboard-devboard created (server dry run)
statefulset.apps/devboard-devboard-postgres created (server dry run)
deployment.apps/devboard-devboard-backend created (server dry run)
```

Day 51's point: client-side checks the YAML, server-side checks the schema. This is what would have caught the `resources` indentation bug in devboard's `feat/k8s` manifests.

```
devops@testvm:~/day-79$ helm install devboard helm/devboard -n devboard-helm --create-namespace
NAME: devboard
STATUS: deployed
REVISION: 1

devboard 1.0.0 deployed as release "devboard" in namespace "devboard-helm".

Watch it come up:
  kubectl -n devboard-helm get pods -l app.kubernetes.io/instance=devboard -w

Reach the app:
  kubectl -n devboard-helm port-forward svc/devboard-devboard-frontend 8080:80
  then open http://localhost:8080

Configuration in effect:
  backend  : manishjha18/devboard-backend:1.0.0 x 1
  frontend : manishjha18/devboard-frontend:1.0.0 x 1
  postgres : postgres:16-alpine, 1Gi volume

WARNING: postgres.password is still the chart default. Override it with
-f values-prod.yaml or --set before using this anywhere real.
```

**The NOTES output is conditional** — it prints the right access instructions for the service type, and warns about the default password. A small thing that makes a chart pleasant to hand to someone else.

```
devops@testvm:~$ kubectl get pods -n devboard-helm
NAME                                        READY   STATUS     RESTARTS   AGE
devboard-devboard-backend-7d4f8b9c6d-2xk4p  0/1     Init:0/1   0          8s
devboard-devboard-frontend-6b8d9f4c2a-k7wq  1/1     Running    0          8s
devboard-devboard-postgres-0                0/1     Running    0          8s

devops@testvm:~$ kubectl get pods -n devboard-helm
NAME                                        READY   STATUS    RESTARTS   AGE
devboard-devboard-backend-7d4f8b9c6d-2xk4p  1/1     Running   0          52s
devboard-devboard-frontend-6b8d9f4c2a-k7wq  1/1     Running   0          52s
devboard-devboard-postgres-0                1/1     Running   0          52s
```

**`Init:0/1` on the backend** while Postgres starts — the init container doing its job. It moved to Running only once `pg_isready` succeeded.

```
devops@testvm:~$ kubectl port-forward -n devboard-helm svc/devboard-devboard-frontend 8080:80 &
devops@testvm:~$ curl -s localhost:8080 | grep -o "<title>[^<]*</title>"
<title>DevBoard</title>
```

**Testing the config-checksum behaviour:**

```
devops@testvm:~$ helm upgrade devboard helm/devboard -n devboard-helm --set postgres.database=devboard2
devops@testvm:~$ kubectl get pods -n devboard-helm -l component=backend
NAME                                        READY   STATUS    RESTARTS   AGE
devboard-devboard-backend-5c8f2a91d4-p2nvx  1/1     Running   0          14s
```

**A new pod hash and 14 seconds old** — the ConfigMap changed, the checksum annotation changed, the pod template changed, a rollout happened. Without the annotation the ConfigMap would have updated and the pods would have kept the old value indefinitely.

---

## Files in this folder

| Path | What it is |
|---|---|
| `helm/devboard/Chart.yaml` | Metadata, chart version vs app version |
| `helm/devboard/values.yaml` | The chart's interface, grouped by component |
| `helm/devboard/templates/_helpers.tpl` | fullname, the two label sets, the connection-string helper |
| `helm/devboard/templates/configmap.yaml` | Config plus SQL loaded from `files/` |
| `helm/devboard/templates/secret.yaml` | `stringData`, replaced by ExternalSecret on Day 80 |
| `helm/devboard/templates/postgres-statefulset.yaml` | Headless Service + StatefulSet, PGDATA fix |
| `helm/devboard/templates/backend.yaml` | Init container, checksums, conditional OTel |
| `helm/devboard/templates/frontend.yaml` | Conditional replicas, NodePort support |
| `helm/devboard/templates/hpa.yaml`, `ingress.yaml` | Whole-template conditionals |
| `helm/devboard/templates/NOTES.txt` | Branching post-install output |

---

## What I learned

**1. The config checksum annotation is the reason to use Helm at all for an app with config.** Day 54 showed that a ConfigMap change never reaches pods consuming it as env vars. Hashing the rendered ConfigMap into the pod template makes a config change trigger a rollout automatically — something the hand-written manifests could not do without remembering `kubectl rollout restart`.

**2. Selector labels must exclude the chart version, or every upgrade fails.** A Deployment's selector is immutable, so `helm.sh/chart: devboard-0.1.0` in it breaks the moment you bump to 0.2.0. The two-helper split exists purely for this, and it is invisible until the second release.

**3. `storageClassName: ""` and omitting the field are different things.** Empty means "no class, static binding"; absent means "use the default". Getting it wrong gives a PVC stuck Pending with an unhelpful event, and it is why the template wraps the field in an `if`.

**Two extras:**

- `helm template | kubectl apply --dry-run=server` validates against the real API schema. `helm lint` only checks that the chart is well-formed.
- Named ports (`targetPort: http`) mean the Service follows the container port automatically instead of duplicating the number in two places.
