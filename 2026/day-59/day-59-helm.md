# Day 59 – Helm

The chart I wrote is in `devboard-chart/` in this folder.

---

## Task 1: Install Helm

```
devops@testvm:~$ curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
devops@testvm:~$ chmod +x get_helm.sh && ./get_helm.sh
Downloading https://get.helm.sh/helm-v3.16.1-linux-amd64.tar.gz
helm installed into /usr/local/bin/helm

devops@testvm:~$ helm version
version.BuildInfo{Version:"v3.16.1", GitCommit:"5a5449dc42be07001fd5771d56429132984ab3ab", GoVersion:"go1.22.7"}
```

**Helm 3 has no Tiller.** Helm 2 ran a server-side component with cluster-wide permissions, which was a genuine security problem. Helm 3 is a client that talks to the API server using my own kubeconfig credentials — so it can do exactly what I can do, no more. Any tutorial mentioning `helm init` or Tiller is for Helm 2 and is obsolete.

Release state is stored in **Secrets in the release's namespace**:

```
devops@testvm:~$ kubectl get secrets -n devboard-dev | grep helm
sh.helm.release.v1.devboard.v1   helm.sh/release.v1   1   2m
```

---

## Task 2: Repositories

```
devops@testvm:~$ helm repo add bitnami https://charts.bitnami.com/bitnami
"bitnami" has been added to your repositories

devops@testvm:~$ helm repo update
Successfully got an update from the "bitnami" chart repository

devops@testvm:~$ helm search repo bitnami/nginx --versions | head -4
NAME                    CHART VERSION   APP VERSION     DESCRIPTION
bitnami/nginx           18.2.4          1.27.2          NGINX Open Source is a web server...
bitnami/nginx           18.2.3          1.27.2          NGINX Open Source is a web server...
bitnami/nginx           18.1.0          1.27.1          NGINX Open Source is a web server...
```

**Two version columns, and the distinction matters.** CHART VERSION is the version of the packaging — the templates. APP VERSION is the software inside. Fixing a template bug bumps the chart version and leaves the app version alone.

```
devops@testvm:~$ helm show values bitnami/nginx | head -12
global:
  imageRegistry: ""
  imagePullSecrets: []
image:
  registry: docker.io
  repository: bitnami/nginx
  tag: 1.27.2-debian-12-r0
  pullPolicy: IfNotPresent
replicaCount: 1
service:
  type: LoadBalancer
  ports:
    http: 80
```

`helm show values` is the first thing to run against any chart — it is the complete list of what can be overridden. The Bitnami nginx chart has about 900 lines of it.

---

## Task 3: Installing a chart

```
devops@testvm:~$ helm install my-nginx bitnami/nginx -n devboard-dev
NAME: my-nginx
LAST DEPLOYED: Tue Aug  4 09:14:22 2026
NAMESPACE: devboard-dev
STATUS: deployed
REVISION: 1

devops@testvm:~$ helm list -n devboard-dev
NAME       NAMESPACE      REVISION   STATUS     CHART          APP VERSION
my-nginx   devboard-dev   1          deployed   nginx-18.2.4   1.27.2

devops@testvm:~$ kubectl get all -n devboard-dev -l app.kubernetes.io/instance=my-nginx
NAME                            READY   STATUS    RESTARTS   AGE
pod/my-nginx-6d9f4b8c7a-k7wqz   1/1     Running   0          48s

NAME               TYPE           CLUSTER-IP      EXTERNAL-IP   PORT(S)
service/my-nginx   LoadBalancer   10.96.142.83    <pending>     80:31204/TCP

NAME                       READY   UP-TO-DATE   AVAILABLE   AGE
deployment.apps/my-nginx   1/1     1            1           48s
```

**One command produced a Deployment, a Service, a ServiceAccount and a ConfigMap.** `<pending>` on the LoadBalancer is Day 53's expected behaviour on kind.

A **release** is the key concept — one installation of a chart, with a name. The same chart can be installed many times in one cluster under different release names, which is why every resource name is prefixed with the release name.

---

## Task 4: Customising with values

```
devops@testvm:~$ helm install my-nginx-2 bitnami/nginx -n devboard-dev \
    --set replicaCount=3 \
    --set service.type=ClusterIP

devops@testvm:~$ kubectl get deploy my-nginx-2 -n devboard-dev
NAME         READY   UP-TO-DATE   AVAILABLE   AGE
my-nginx-2   3/3     3            3           31s
```

`--set` is fine for one or two values and unreadable beyond that. A values file is the real approach:

```yaml
# my-values.yaml
replicaCount: 3
service:
  type: ClusterIP
resources:
  requests:
    cpu: 50m
    memory: 64Mi
```

```
devops@testvm:~$ helm install my-nginx-3 bitnami/nginx -n devboard-dev -f my-values.yaml
```

**This is the point of Helm for multi-environment work** — one chart, one values file per environment:

```
helm install devboard ./devboard-chart -f values-dev.yaml
helm install devboard ./devboard-chart -f values-prod.yaml
```

Same templates, different replica counts, resources and image tags. Without Helm that means maintaining two nearly identical directories of YAML and keeping them in sync by hand.

Checking what will happen before it happens:

```
devops@testvm:~$ helm install my-nginx-4 bitnami/nginx --dry-run --debug -n devboard-dev | head -20
```

`--dry-run` renders the templates and prints the manifests without applying anything — the Helm equivalent of Day 51's `--dry-run=server`.

---

## Task 5: Upgrade and rollback

```
devops@testvm:~$ helm upgrade my-nginx bitnami/nginx -n devboard-dev --set replicaCount=4
Release "my-nginx" has been upgraded. Happy Helming!
REVISION: 2

devops@testvm:~$ helm history my-nginx -n devboard-dev
REVISION   UPDATED                  STATUS       CHART          APP VERSION   DESCRIPTION
1          Tue Aug  4 09:14:22      superseded   nginx-18.2.4   1.27.2        Install complete
2          Tue Aug  4 09:22:41      deployed     nginx-18.2.4   1.27.2        Upgrade complete
```

**A trap worth knowing:**

```
devops@testvm:~$ helm upgrade my-nginx bitnami/nginx -n devboard-dev --set service.type=ClusterIP
devops@testvm:~$ kubectl get deploy my-nginx -n devboard-dev
NAME       READY   UP-TO-DATE   AVAILABLE   AGE
my-nginx   1/1     1            1           12m
```

**Replicas went back to 1.** `--set` values are **not** remembered between upgrades — each upgrade starts from the chart defaults plus whatever you pass *this time*. `--reuse-values` keeps the previous ones, and a values file avoids the problem entirely by being the source of truth.

```
devops@testvm:~$ helm rollback my-nginx 1 -n devboard-dev
Rollback was a success! Happy Helming!

devops@testvm:~$ helm history my-nginx -n devboard-dev
REVISION   STATUS       DESCRIPTION
1          superseded   Install complete
2          superseded   Upgrade complete
3          superseded   Upgrade complete
4          deployed     Rollback to 1
```

**A rollback is a new revision**, not a rewind. Same idea as Day 25's `git revert` versus `git reset` — history moves forward and records what was undone.

This is a real advantage over `kubectl apply`. Rolling back a set of manifests by hand means finding the old versions and re-applying them, and remembering anything that was added and must now be deleted. Helm knows the whole release.

---

## Task 6: My own chart

`helm create` generates a scaffold; I wrote this one deliberately so every file has a reason.

```
devboard-chart/
├── Chart.yaml
├── values.yaml
├── .helmignore
└── templates/
    ├── _helpers.tpl
    ├── configmap.yaml
    ├── deployment.yaml
    ├── service.yaml
    ├── hpa.yaml
    └── NOTES.txt
```

### The pieces worth explaining

**`_helpers.tpl`** — the underscore prefix means Helm does not render it as a manifest. It holds named templates used elsewhere:

```
{{- define "devboard.fullname" -}}
{{- printf "%s-%s" .Release.Name (include "devboard.name" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}
```

`trunc 63` because that is the Kubernetes limit for a DNS label. `trimSuffix "-"` because truncation might leave a trailing dash, which is invalid. Both are in every generated chart and both matter.

**Two label helpers, not one:**

```
{{- define "devboard.labels" -}}          # everything
app.kubernetes.io/name: ...
app.kubernetes.io/version: ...
helm.sh/chart: ...

{{- define "devboard.selectorLabels" -}}  # a subset
app.kubernetes.io/name: ...
app.kubernetes.io/instance: ...
```

**The selector labels deliberately exclude the version.** A Deployment's `selector` is immutable (Day 52), so a version label in the selector would make every chart upgrade fail with "field is immutable". Splitting them is not stylistic — it is required.

**The config checksum:**

```yaml
      annotations:
        checksum/config: {{ include (print $.Template.BasePath "/configmap.yaml") . | sha256sum }}
```

This is Day 54's problem solved properly. A ConfigMap consumed as environment variables never reaches running pods. Hashing the rendered ConfigMap into a pod annotation means the pod template changes whenever the config does, so a rollout happens automatically.

**Conditional replicas:**

```yaml
  {{- if not .Values.autoscaling.enabled }}
  replicas: {{ .Values.replicaCount }}
  {{- end }}
```

Day 58's HPA conflict, solved by omitting the field entirely when an HPA owns it.

**Conditional resources** — `hpa.yaml` is wrapped in `{{- if .Values.autoscaling.enabled }}`, so it renders to nothing when disabled. That is how one chart covers both cases.

**`| nindent 4`** — indent by 4 *and* add a leading newline. Plain `indent` does not add the newline and produces broken YAML. The `-` in `{{-` strips preceding whitespace. Whitespace control is most of the difficulty in writing templates.

### Testing it

```
devops@testvm:~/day-59$ helm lint devboard-chart/
==> Linting devboard-chart/
[INFO] Chart.yaml: icon is recommended

1 chart(s) linted, 0 chart(s) failed

devops@testvm:~/day-59$ helm template devboard devboard-chart/ | head -24
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
  LOG_LEVEL: "info"
```

**`helm template` renders locally without touching the cluster.** This is the command to use while developing a chart — instant feedback, and it is what I would put in CI alongside `helm lint`.

```
devops@testvm:~/day-59$ helm install devboard ./devboard-chart -n devboard-dev
NAME: devboard
STATUS: deployed
REVISION: 1

devboard 1.0.0 installed as release "devboard".

Get the application URL:
  kubectl port-forward -n devboard-dev svc/devboard-devboard 8080:80
  echo "http://localhost:8080"

Replicas: 2

devops@testvm:~/day-59$ kubectl get all -n devboard-dev -l app.kubernetes.io/instance=devboard
NAME                                     READY   STATUS    RESTARTS   AGE
pod/devboard-devboard-7d4f8b9c6d-2xk4p   1/1     Running   0          22s
pod/devboard-devboard-7d4f8b9c6d-8mnq7   1/1     Running   0          22s

NAME                        TYPE        CLUSTER-IP      PORT(S)
service/devboard-devboard   ClusterIP   10.96.201.44    80/TCP
```

**`NOTES.txt` rendered with the right instructions for the ClusterIP case.** The `{{- if eq .Values.service.type "NodePort" }}` branch would have printed the nodePort version instead. A small thing that makes a chart pleasant to use.

Enabling autoscaling:

```
devops@testvm:~/day-59$ helm upgrade devboard ./devboard-chart -n devboard-dev \
    --set autoscaling.enabled=true

devops@testvm:~/day-59$ kubectl get hpa -n devboard-dev
NAME                REFERENCE                      TARGETS       MINPODS   MAXPODS   REPLICAS
devboard-devboard   Deployment/devboard-devboard   cpu: 1%/50%   1         5         2
```

The HPA appeared and `replicas` disappeared from the Deployment, from one flag.

---

## Task 7: Cleanup

```
devops@testvm:~/day-59$ helm uninstall my-nginx my-nginx-2 my-nginx-3 -n devboard-dev
release "my-nginx" uninstalled
release "my-nginx-2" uninstalled
release "my-nginx-3" uninstalled

devops@testvm:~/day-59$ helm list -n devboard-dev
NAME       NAMESPACE      REVISION   STATUS     CHART             APP VERSION
devboard   devboard-dev   2          deployed   devboard-0.1.0    1.0.0
```

**`helm uninstall` removes everything the release created** — deployments, services, configmaps — in one command, with no leftovers to hunt for. That alone is worth the abstraction.

It does **not** remove PVCs created by a StatefulSet's `volumeClaimTemplates`, for the Day 56 reason. Deliberate, and something to remember when cleaning up a database release.

---

## Files in this folder

| Path | What it is |
|---|---|
| `devboard-chart/Chart.yaml` | Chart metadata, chart version vs app version |
| `devboard-chart/values.yaml` | Every overridable default |
| `devboard-chart/templates/_helpers.tpl` | Named templates; separate full and selector labels |
| `devboard-chart/templates/deployment.yaml` | Config checksum, conditional replicas |
| `devboard-chart/templates/service.yaml` | Named port reference |
| `devboard-chart/templates/hpa.yaml` | Rendered only when autoscaling is enabled |
| `devboard-chart/templates/NOTES.txt` | Post-install output, branching on service type |

---

## What I learned

**1. Selector labels must be a separate, smaller set.** A Deployment's selector is immutable, so putting the chart version in it makes every upgrade fail with "field is immutable". The two-helper split in every generated chart exists for that reason, not for tidiness.

**2. `--set` values are forgotten on the next upgrade.** Upgrading with a different `--set` silently reset the replica count to the chart default. Values files are the fix, and they are why the multi-environment story works at all.

**3. Helm solves the config-rollout problem properly.** The `checksum/config` annotation makes the pod template change whenever the ConfigMap does, so a config change actually reaches running pods — which Day 54 showed does not happen by default with env vars.

**Two extras:**

- `helm template` renders locally with no cluster, which is the right inner loop when writing a chart and the right check to put in CI alongside `helm lint`.
- A rollback creates a new revision rather than rewinding. Same shape as `git revert` — history only moves forward.
