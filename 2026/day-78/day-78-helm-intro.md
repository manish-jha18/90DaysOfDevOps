# Day 78 – Introduction to Helm and Chart Basics

Values files in `helm/` in this folder.

**A note on the reference app:** the README points at AI-BankApp. I am using **DevBoard** instead — my own project, already containerised on Day 36, already deployed to Kubernetes by hand on Days 51–60, and already carrying a real Helm chart on the `mega-project` branch. Days 79 and 80 rebuild that chart from scratch, so the comparison at the end is against something I can actually read.

---

## Task 1: Helm concepts

Day 59 covered the basics. This is what I actually need to be clear about before writing a real chart.

| Term | Is |
|---|---|
| **Chart** | A directory of templates plus a `values.yaml`. The package |
| **Release** | One installation of a chart, with a name. `helm install foo ./chart` creates release `foo` |
| **Repository** | An HTTP-served index of packaged charts |
| **Values** | The inputs. Defaults in `values.yaml`, overridden with `-f` or `--set` |
| **Revision** | A version of a release. Every upgrade and rollback creates a new one |

**Release state lives in Secrets in the release's namespace:**

```
devops@testvm:~$ kubectl get secret -n devboard-dev -l owner=helm
NAME                              TYPE                 DATA   AGE
sh.helm.release.v1.devboard.v1    helm.sh/release.v1   1      4m
sh.helm.release.v1.devboard.v2    helm.sh/release.v1   1      1m
```

One Secret per revision, holding a gzipped copy of the rendered manifests. That is how `helm rollback` works without re-rendering — it re-applies a stored snapshot. It also means **release history is per namespace**, so the same release name can exist independently in dev and prod.

**Helm 3 has no Tiller.** Helm 2's server-side component held cluster-wide permissions and was a genuine security problem. Helm 3 is a client using my kubeconfig, so it can do exactly what I can do. Any tutorial mentioning `helm init` is obsolete.

### Why not just `kubectl apply -f`

Day 60 deployed WordPress with six hand-written manifests and it worked. What Helm adds:

**Parameterisation.** Three environments from one set of templates instead of three directories kept in sync by hand.

**Atomic lifecycle.** `helm uninstall` removes everything the release created. `kubectl delete -f dir/` misses anything that was added to the cluster but removed from the directory.

**Rollback.** One command, using the stored previous revision.

**Distribution.** A chart is a versioned artefact others can install.

What it costs: an extra templating layer to debug, and `helm template` becomes a step in understanding what will be applied.

---

## Task 2: Setup and exploring the chart

```
devops@testvm:~$ helm version
version.BuildInfo{Version:"v3.16.1", GitCommit:"5a5449dc42be...", GoVersion:"go1.22.7"}

devops@testvm:~$ kubectl config current-context
kind-devops-cluster
```

**Checking the context first**, because Day 66 left two clusters in the kubeconfig and one of them costs $200/month.

```
devops@testvm:~$ git clone -b mega-project https://github.com/manish-jha18/devboard.git
devops@testvm:~$ cd devboard/helm/devboard && find . -type f | sort
./.helmignore
./Chart.yaml
./files/01_schema.sql
./files/02_seed.sql
./templates/NOTES.txt
./templates/_helpers.tpl
./templates/backend-deployment.yaml
./templates/backend-service.yaml
./templates/configmap.yaml
./templates/externalsecret.yaml
./templates/frontend-deployment.yaml
./templates/frontend-hpa.yaml
./templates/gateway.yaml
./templates/httproute.yaml
./templates/postgres-statefulset.yaml
./values.yaml
```

Twenty-two files. Worth noting what is in there that a beginner chart would not have: an **ExternalSecret** rather than a Secret, **Gateway API** resources rather than an Ingress, and a **cert-manager Certificate**. Days 79–80 build the simpler version and Day 81 onwards gets to the rest.

```
devops@testvm:~$ helm show chart ./helm/devboard | head -6
apiVersion: v2
appVersion: "1.0.0"
description: DevBoard — a 3-tier task tracker (React + Go + Postgres) packaged for GitOps on Kubernetes
name: devboard
type: application
version: 0.2.0
```

**`version` is the chart; `appVersion` is the software.** Fixing a template bug bumps `version` and leaves `appVersion` alone. Day 80 uses that.

---

## Task 3: A chart from a repository

```
devops@testvm:~$ helm repo add bitnami https://charts.bitnami.com/bitnami
devops@testvm:~$ helm repo update

devops@testvm:~$ helm search repo bitnami/postgresql --versions | head -4
NAME                    CHART VERSION   APP VERSION     DESCRIPTION
bitnami/postgresql      16.1.2          17.0.1          PostgreSQL (Postgres) is an open source object-...
bitnami/postgresql      16.1.1          17.0.1          PostgreSQL (Postgres) is an open source object-...
bitnami/postgresql      16.0.6          16.4.0          PostgreSQL (Postgres) is an open source object-...
```

**Chart 16.x installs Postgres 17.** The two version columns are unrelated, and assuming they track together is a real mistake — pinning `--version 16.1.2` gives Postgres 17, not 16.

```
devops@testvm:~$ helm install pg bitnami/postgresql --version 16.1.2 \
    -n devboard-dev --create-namespace

NAME: pg
STATUS: deployed
REVISION: 1

devops@testvm:~$ kubectl get all -n devboard-dev
NAME          READY   STATUS    RESTARTS   AGE
pod/pg-postgresql-0   1/1     Running   0      62s

NAME                        TYPE        CLUSTER-IP      PORT(S)
service/pg-postgresql       ClusterIP   10.96.142.83    5432/TCP
service/pg-postgresql-hl    ClusterIP   None            5432/TCP

NAME                             READY   AGE
statefulset.apps/pg-postgresql   1/1     62s
```

**A StatefulSet plus two Services** — one normal, one headless. Exactly Day 56's pattern, produced by someone who knows the software.

```
devops@testvm:~$ helm get manifest pg -n devboard-dev | grep -c "^kind:"
7
```

Seven resources from one command: StatefulSet, two Services, a Secret, a ServiceAccount, a NetworkPolicy and a ConfigMap. The NetworkPolicy is the one I would not have written — Day 60's list of production gaps had exactly that missing.

---

## Task 4: Values

```
devops@testvm:~$ helm show values bitnami/postgresql | wc -l
1247
```

**1,247 lines of configurable values.** That is the trade Day 65 described for registry modules: enormous flexibility, and a large surface to read when something is wrong.

**`helm/postgres-values.yaml`**

```yaml
auth:
  username: devboard
  database: devboard
  password: devboard
  # existingSecret: devboard-postgres

primary:
  persistence:
    enabled: true
    size: 2Gi
    storageClass: ""
  resources:
    requests: { cpu: 100m, memory: 256Mi }
    limits: { cpu: 500m, memory: 512Mi }

readReplicas:
  replicaCount: 0

metrics:
  enabled: false
```

**`existingSecret` is the option that matters** and it is commented out here only because this is local. Putting a password in a values file is fine for a demo and is Day 27's leak in production — the chart supports pointing at a Secret created some other way, which is what Day 80 does properly.

```
devops@testvm:~$ helm upgrade --install pg bitnami/postgresql --version 16.1.2 \
    -n devboard-dev -f helm/postgres-values.yaml

devops@testvm:~$ kubectl get pvc -n devboard-dev
NAME                     STATUS   VOLUME       CAPACITY   AGE
data-pg-postgresql-0     Bound    pvc-8a3f...  2Gi        3m
```

**`upgrade --install` rather than `install`** — it installs if the release is absent and upgrades if it is present, so the same command works from a clean cluster or an existing one. That idempotency is what makes it safe in CI, and it is the form I would always use.

**Checking before applying:**

```
devops@testvm:~$ helm upgrade pg bitnami/postgresql -f helm/postgres-values.yaml --dry-run --debug | head -20
devops@testvm:~$ helm diff upgrade pg bitnami/postgresql -f helm/postgres-values.yaml
```

`helm diff` is a plugin (`helm plugin install https://github.com/databus23/helm-diff`) and it is the closest thing to `terraform plan` in the Helm world — it shows the change against what is **live**, where `--dry-run` only renders. Worth installing on day one.

---

## Task 5: Release management

```
devops@testvm:~$ helm upgrade pg bitnami/postgresql --version 16.1.2 \
    -n devboard-dev -f helm/postgres-values.yaml \
    --set primary.resources.limits.memory=1Gi

Release "pg" has been upgraded. Happy Helming!
REVISION: 3

devops@testvm:~$ helm history pg -n devboard-dev
REVISION  UPDATED                  STATUS       CHART                APP VERSION  DESCRIPTION
1         Sat Aug 15 09:14:22      superseded   postgresql-16.1.2    17.0.1       Install complete
2         Sat Aug 15 09:22:41      superseded   postgresql-16.1.2    17.0.1       Upgrade complete
3         Sat Aug 15 09:31:08      deployed     postgresql-16.1.2    17.0.1       Upgrade complete
```

**The `--set` trap from Day 59, worth repeating because it caught me again:**

```
devops@testvm:~$ helm upgrade pg bitnami/postgresql -n devboard-dev -f helm/postgres-values.yaml
devops@testvm:~$ helm get values pg -n devboard-dev | grep -A2 limits
    limits:
      cpu: 500m
      memory: 512Mi
```

The `1Gi` from the previous `--set` is gone. **Each upgrade starts from the chart defaults plus what you pass *this time*.** `--reuse-values` keeps the old ones; a values file avoids the problem entirely by being the source of truth. This is the strongest argument for never using `--set` for anything you want to persist.

```
devops@testvm:~$ helm rollback pg 2 -n devboard-dev
Rollback was a success! Happy Helming!

devops@testvm:~$ helm history pg -n devboard-dev | tail -2
4         Sat Aug 15 09:38:14      deployed     postgresql-16.1.2    17.0.1       Rollback to 2
```

**A rollback is revision 4, not a return to 2.** History only moves forward — Day 25's `git revert` versus `git reset` again.

**Two flags worth knowing on upgrade:**

```bash
helm upgrade --install pg bitnami/postgresql --atomic --timeout 5m
```

`--atomic` rolls back automatically if the upgrade fails or times out, so you are never left in a half-applied state. `--wait` blocks until pods are Ready. Both belong in a CI deploy step.

```
devops@testvm:~$ helm uninstall pg -n devboard-dev
release "pg" uninstalled

devops@testvm:~$ kubectl get pvc -n devboard-dev
NAME                   STATUS   VOLUME        CAPACITY   AGE
data-pg-postgresql-0   Bound    pvc-8a3f...   2Gi        24m
```

**The PVC survived.** `helm uninstall` removes what the release created, and a PVC from a StatefulSet's `volumeClaimTemplates` is created by the **StatefulSet controller**, not by Helm — so Helm never owned it. Day 56's behaviour, and it is a deliberate safety net that also means an uninstall/reinstall cycle silently reuses the old data.

---

## Task 6: Chart structure

```
chart/
├── Chart.yaml          name, version, appVersion, dependencies
├── values.yaml         defaults
├── .helmignore         what to exclude from the packaged .tgz
├── charts/             subcharts (dependencies), vendored here
├── crds/               CRDs, installed BEFORE templates and never upgraded
├── files/              arbitrary files, readable with .Files
└── templates/
    ├── _helpers.tpl    named templates. Leading _ means "not a manifest"
    ├── NOTES.txt       printed after install
    └── *.yaml          the actual resources
```

**Two of those have non-obvious behaviour:**

**`crds/`** is installed before anything in `templates/` and is **never upgraded or deleted** by Helm. That is deliberate — deleting a CRD deletes every object of that type — and it means a chart shipping CRDs cannot update them through Helm.

**`files/`** is read with `.Files`, which is how devboard's chart gets its SQL into a ConfigMap:

```yaml
  {{- (.Files.Glob "files/*.sql").AsConfig | nindent 2 }}
```

Two `.sql` files become two ConfigMap keys. Much better than embedding SQL in YAML — the editor highlights it and it can be run directly against a database.

### The built-in objects

| Object | Holds |
|---|---|
| `.Values` | Merged values |
| `.Chart` | `Chart.yaml` — `.Chart.Name`, `.Chart.Version`, `.Chart.AppVersion` |
| `.Release` | `.Release.Name`, `.Release.Namespace`, `.Release.Service`, `.Release.IsUpgrade` |
| `.Capabilities` | What the cluster supports — `.Capabilities.APIVersions.Has "..."` |
| `.Files` | Files in the chart, outside `templates/` |
| `.Template` | The current template's path, used by the checksum trick |

**`.Capabilities` is how a chart works across cluster versions** — checking whether an API exists before using it, rather than failing on an older cluster.

### The two helper patterns worth copying

From devboard's `_helpers.tpl`:

```
{{- define "devboard.fullname" -}}
{{- printf "%s-%s" .Release.Name (include "devboard.name" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}
```

`trunc 63` because that is the Kubernetes DNS label limit, and `trimSuffix "-"` because truncation can leave a trailing dash, which is invalid. Both are in every generated chart and both are load-bearing.

And the label split — full labels including the version, selector labels deliberately without it, because a Deployment's selector is immutable and a version label there breaks every upgrade. Day 59 covered why; devboard's chart is where I first saw it done in anger.

---

## Files in this folder

| Path | What it is |
|---|---|
| `helm/postgres-values.yaml` | Overrides for `bitnami/postgresql` |
| `helm/nginx-values.yaml` | Overrides for `bitnami/nginx`, NodePort for kind |

---

## What I learned

**1. Chart version and app version are unrelated, and assuming otherwise is a real mistake.** `bitnami/postgresql` chart 16.1.2 installs Postgres **17**. Pinning the chart version pins the packaging, not the software — you have to check `appVersion` separately.

**2. `--set` values are forgotten on the next upgrade.** Each upgrade starts from chart defaults plus what you pass that time, so a memory limit set with `--set` silently reverted. Values files are the only durable source of truth, which is why Day 80 is built entirely around them.

**3. `helm uninstall` leaves StatefulSet PVCs behind, because Helm never owned them.** The StatefulSet controller creates them from `volumeClaimTemplates`. A safety net, and also the reason an uninstall/reinstall can silently come back with the old data.

**Two extras:**

- `helm upgrade --install` is the form to always use — it works from an empty cluster or an existing release, which makes it safe in CI. Add `--atomic` so a failed upgrade rolls itself back.
- `helm diff` (a plugin) shows the change against what is **live**, where `--dry-run` only renders the templates. It is the closest thing Helm has to `terraform plan`.
