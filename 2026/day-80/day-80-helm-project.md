# Day 80 – Helm Project: Multi-Environment Deployment and CI/CD

Chart in `helm/devboard/` — Day 79's chart at version 0.2.0, with hooks added and three environment values files.

---

## Task 1: Environment-specific values

Three files, one chart. Every difference between environments is visible by diffing them.

### `values-dev.yaml`

```yaml
postgres:
  storage:
    size: 1Gi
  resources:
    requests: { cpu: 25m, memory: 64Mi }
    limits: { cpu: 250m, memory: 128Mi }

backend:
  replicas: 1
  image:
    tag: latest
    pullPolicy: Always

frontend:
  service:
    type: NodePort
    nodePort: 30080
  hpa:
    enabled: false

observability:
  enabled: false
```

**`tag: latest` with `pullPolicy: Always` is correct here and wrong everywhere else.** Dev wants whatever CI just pushed. And `Always` is required — without it, Kubernetes sees the same image string and does not re-pull, so a new `latest` never arrives. Day 52's `kubectl set image` reporting `unchanged` is the same failure.

`NodePort` because kind has no load balancer (Day 53).

### `values-staging.yaml`

```yaml
backend:
  replicas: 2
  image:
    tag: sha-8a3f91c
    pullPolicy: IfNotPresent

frontend:
  hpa:
    enabled: true
    minReplicas: 2
    maxReplicas: 4

ingress:
  enabled: true
  host: staging.devboard.example.com
  tls:
    enabled: true

observability:
  enabled: true
```

**Staging pins a real SHA — the same artefact that will go to prod.** That is the entire point of staging: if it runs a different image, it has proved nothing. Day 45's immutable tag, used as intended.

### `values-prod.yaml`

```yaml
postgres:
  storage:
    size: 50Gi
    storageClassName: gp3
  resources:
    requests: { cpu: 500m, memory: 2Gi }
    limits: { cpu: 2000m, memory: 4Gi }

backend:
  replicas: 3
  image:
    tag: sha-8a3f91c
    pullPolicy: IfNotPresent

frontend:
  hpa:
    enabled: true
    minReplicas: 3
    maxReplicas: 10

ingress:
  enabled: true
  host: devboard.example.com
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
  tls:
    enabled: true

probes:
  liveness:
    initialDelaySeconds: 30
    periodSeconds: 15
    failureThreshold: 5

affinity:
  podAntiAffinity:
    preferredDuringSchedulingIgnoredDuringExecution:
      - weight: 100
        podAffinityTerm:
          labelSelector:
            matchLabels:
              app.kubernetes.io/name: devboard
          topologyKey: kubernetes.io/hostname
```

**Three prod-specific decisions:**

**Looser probes.** A production pod under load starts slower and responds slower. Day 57's liveness probe kills the container, so a tight threshold restarts a pod that is merely busy — which makes an overload worse.

**Pod anti-affinity** spreads replicas across nodes. `preferred` rather than `required`, so a two-node cluster still schedules three replicas instead of leaving one Pending forever. Day 60's WordPress had no anti-affinity and all replicas could land on one node, which makes the replica count decorative.

**`pullPolicy: IfNotPresent`, never `Always`.** With a pinned SHA there is nothing new to pull, and `Always` means a registry outage stops a restarting pod from starting. On a pinned tag, `Always` is pure downside risk.

**And the most important thing in the file is what is missing:**

```yaml
# NO postgres.password here on purpose. A production password in a
# committed values file is the day 27 leak. Supply it at deploy time:
#   --set postgres.password="$DB_PASSWORD"
# or better, replace the Secret template with an ExternalSecret.
```

devboard's real chart takes the second option — an **ExternalSecret** pointing at AWS Secrets Manager, with the Terraform from Day 66 creating the secret and the Pod Identity role. The password never exists in git or in a CI variable at all.

### Using them

```
devops@testvm:~/day-80$ helm upgrade --install devboard-dev ./helm/devboard \
    -n devboard-dev --create-namespace -f helm/devboard/values-dev.yaml

devops@testvm:~/day-80$ helm upgrade --install devboard-staging ./helm/devboard \
    -n devboard-staging --create-namespace -f helm/devboard/values-staging.yaml

devops@testvm:~/day-80$ helm list -A
NAME               NAMESPACE           REVISION  STATUS     CHART            APP VERSION
devboard-dev       devboard-dev        1         deployed   devboard-0.2.0   1.0.0
devboard-staging   devboard-staging    1         deployed   devboard-0.2.0   1.0.0
```

**Same chart, two releases, two namespaces.** They cannot collide because every resource name is prefixed with the release name — the `fullname` helper from Day 79 doing its job.

**Diffing environments is a genuine review tool:**

```
devops@testvm:~/day-80$ diff <(helm template x ./helm/devboard -f helm/devboard/values-dev.yaml) \
                             <(helm template x ./helm/devboard -f helm/devboard/values-prod.yaml) \
  | grep -E "^[<>].*(replicas|image:|cpu|memory|storage)" | head -12
<     replicas: 1
>     replicas: 3
<           image: "manishjha18/devboard-backend:latest"
>           image: "manishjha18/devboard-backend:sha-8a3f91c"
<               cpu: 25m
>               cpu: 500m
<               memory: 64Mi
>               memory: 2Gi
<         storage: 1Gi
>         storage: 50Gi
```

The exact difference between dev and prod, mechanically. Without Helm that means comparing two directories of YAML by eye.

**Values files are merged, not replaced**, so a base plus an overlay works:

```
helm upgrade --install devboard ./helm/devboard \
  -f values-common.yaml -f values-prod.yaml
```

Later files win per key. Worth knowing: **lists are replaced wholesale, not merged.** Setting `tolerations` in both files means the later one wins entirely.

---

## Task 2: Hooks

**`templates/hooks.yaml`** — two hooks doing very different jobs.

### A pre-install/pre-upgrade gate

```yaml
  annotations:
    "helm.sh/hook": pre-install,pre-upgrade
    "helm.sh/hook-weight": "-5"
    "helm.sh/hook-delete-policy": before-hook-creation,hook-succeeded
spec:
  backoffLimit: 2
  activeDeadlineSeconds: {{ .Values.hooks.dbCheck.timeoutSeconds }}
```

Runs before any workload is created or updated. **If it fails, Helm aborts the release** — nothing is deployed against a database that is not ready.

**`hook-delete-policy` is the field that trips people up.** A Job's spec is immutable, so a leftover Job from the previous release makes the next upgrade fail with `field is immutable`. The two policies together are the correct pair:

- `before-hook-creation` — delete any existing one before running
- `hook-succeeded` — delete on success

**Deliberately not `hook-failed`**, so a failed Job survives and its logs can be read. A hook that deletes itself on failure is a hook you cannot debug.

**`activeDeadlineSeconds`** so a hung database fails the release rather than hanging the deploy forever.

### A test hook

```yaml
  annotations:
    "helm.sh/hook": test
```

**The `test` hook does not run on install.** It runs only on `helm test <release>`, which makes it safe to ship in the chart.

```
devops@testvm:~$ helm test devboard-dev -n devboard-dev
NAME: devboard-dev
TEST SUITE:     devboard-dev-devboard-smoke-test
Last Started:   Sun Aug 16 10:14:22 2026
Phase:          Succeeded

devops@testvm:~$ kubectl logs -n devboard-dev devboard-dev-devboard-smoke-test
backend health
{"status":"ok"}
frontend responds
HTTP 200
smoke test passed
```

**This is the post-deploy verification step for CI**, and it is better than a `curl` in a pipeline because it runs **inside the cluster** — it exercises the Services and cluster DNS, not just an ingress. Day 48's `delegate_to: localhost` health check tested the external path; this tests the internal one.

### Hook reference

| Hook | Runs |
|---|---|
| `pre-install` | Before any resource is created |
| `post-install` | After all resources are created |
| `pre-upgrade` / `post-upgrade` | Around an upgrade |
| `pre-delete` / `post-delete` | Around an uninstall |
| `pre-rollback` / `post-rollback` | Around a rollback |
| `test` | Only on `helm test` |

**`hook-weight` orders them** — lower runs first, and it is a string, not a number. `"10"` sorts before `"9"` lexically, so pad them or keep them single-digit.

**The limitation worth knowing:** hook resources are **not** tracked as part of the release. `helm uninstall` does not remove them unless a delete policy already did, and they do not appear in `helm get manifest`.

---

## Task 3: Packaging and versioning

```
devops@testvm:~/day-80$ helm package helm/devboard
Successfully packaged chart and saved it to: /home/devops/day-80/devboard-0.2.0.tgz

devops@testvm:~/day-80$ tar tzf devboard-0.2.0.tgz
devboard/Chart.yaml
devboard/values.yaml
devboard/templates/_helpers.tpl
devboard/templates/backend.yaml
...
devboard/files/01_schema.sql
```

**`.helmignore` excluded the `values-*.yaml` files**, which is deliberate. Environment values belong to the deployment repository, not to the chart — a chart shipped with someone else's production hostnames in it is wrong.

```
devops@testvm:~/day-80$ helm show chart devboard-0.2.0.tgz | grep version
version: 0.2.0
devops@testvm:~/day-80$ helm install test ./devboard-0.2.0.tgz --dry-run > /dev/null && echo "installable"
installable
```

### Versioning

**Semver, and the two numbers move independently:**

| Change | Bump |
|---|---|
| Template fix, no interface change | `version` patch — 0.2.0 → 0.2.1 |
| New optional value | `version` minor — 0.2.0 → 0.3.0 |
| Renamed or removed a value | `version` major — 0.2.0 → 1.0.0 |
| New application image | `appVersion` only |

**A renamed value is a breaking change** even though nothing in Kubernetes broke — every caller's values file stops working. That is the case that justifies a major bump, and it is easy to under-rate.

### Publishing

Any HTTP server with an `index.yaml` is a chart repository:

```
devops@testvm:~/day-80$ mkdir -p charts && cp devboard-0.2.0.tgz charts/
devops@testvm:~/day-80$ helm repo index charts --url https://manish-jha18.github.io/charts
devops@testvm:~/day-80$ cat charts/index.yaml | head -12
apiVersion: v1
entries:
  devboard:
  - apiVersion: v2
    appVersion: "1.0.0"
    created: "2026-08-16T10:22:41Z"
    digest: 8a3f91c4d2e58b1a6c9e0d4a1f27b8a35c6e9f2d1b4a7c0e3f6a9d2b5c8e1f4a
    name: devboard
    urls:
    - https://manish-jha18.github.io/charts/devboard-0.2.0.tgz
    version: 0.2.0
```

GitHub Pages serving that directory is a working chart repository, free.

**OCI registries are the modern alternative** and are simpler — no `index.yaml` to regenerate:

```
devops@testvm:~$ helm push devboard-0.2.0.tgz oci://registry-1.docker.io/manishjha18
devops@testvm:~$ helm install devboard oci://registry-1.docker.io/manishjha18/devboard --version 0.2.0
```

Charts live alongside images in the same registry with the same credentials (Day 45). This is what I would use.

---

## Task 4: Helm in the GitOps pipeline

Where Helm sits between Day 48's CI and Days 84–86's ArgoCD.

```
  git push
     │
     ▼
┌─────────────────────────── CI (day 48) ──────────────────────────┐
│  test → build image → trivy scan → push  manishjha18/...:sha-8a3f91c │
│                                                                   │
│  then: bump the image tag in the DEPLOYMENT repo's values file    │
└───────────────────────────────┬───────────────────────────────────┘
                                │  git commit to the deployment repo
                                ▼
┌────────────────────────── CD (days 84-86) ───────────────────────┐
│  ArgoCD watches the deployment repo                              │
│    → renders the chart with values-prod.yaml                     │
│    → diffs against the live cluster                              │
│    → syncs                                                        │
└───────────────────────────────────────────────────────────────────┘
```

**The pipeline never runs `helm upgrade`.** It commits a one-line change to a values file, and ArgoCD does the applying. That is the GitOps inversion — CI pushes to git, CD pulls from git.

**Why that matters:** the cluster's state is whatever is in the repository. There is no way to deploy something that is not committed, so a manual `kubectl edit` is detected as drift and reverted. Day 64's Terraform drift detection, applied to Kubernetes and running continuously.

devboard's ArgoCD Application does exactly this:

```yaml
  source:
    repoURL: https://github.com/manish-jha18/devboard.git
    targetRevision: mega-project
    path: helm/devboard
    helm:
      valueFiles:
        - values.yaml
```

ArgoCD renders the chart itself — it does not shell out to `helm install`, so **there is no Helm release history in the cluster**. `helm list` shows nothing; ArgoCD's own history replaces it. That surprised me and it is worth knowing before looking for a release that is not there.

**The two-repository split** is the other convention: application code in one repo, deployment manifests and values in another. CI writes to the second one. It keeps a deploy from requiring a code review and stops an application change and an infrastructure change sharing a commit.

**Where `helm upgrade` still belongs:** the imperative form is right for third-party infrastructure — an ingress controller, cert-manager, the observability stack from Day 77. Those are installed once and rarely change, and putting them behind GitOps adds ceremony without much benefit.

---

## Task 5: Production practices

What I would insist on for a chart that matters.

**Pin everything.** Chart versions in `Chart.yaml` dependencies, image tags to SHAs, and `.Chart.AppVersion` never as `latest`. Day 45, Day 65 and Day 71 all landed on this; Helm is the fourth.

**No secrets in values files.** Either `--set` at deploy time from a CI secret, or an ExternalSecret. A committed production password is Day 27's leak with a longer half-life, because a values file looks like configuration rather than a credential.

**`--atomic --timeout 10m` on every automated upgrade.** A failed or hung upgrade rolls itself back rather than leaving half a release applied.

**A `test` hook, and run it after deploy.** Verification inside the cluster catches Service and DNS problems that an external check cannot.

**`helm lint` and `helm template | kubectl apply --dry-run=server` in CI.** Lint checks the chart is well-formed; server dry-run checks the output is valid against the real API. Day 79 showed only the second catches a misplaced field.

**Resource requests and limits on everything.** A container with none is BestEffort QoS and is evicted first (Day 57).

**A `checksum/config` annotation** on anything consuming a ConfigMap or Secret as env vars, or config changes silently never reach the pods.

**Document every value.** A comment per value in `values.yaml`, and `helm-docs` to generate a README from them. A chart nobody else can configure is not reusable.

**Do not template what does not vary.** Every `{{ }}` is something to debug later. If a value is the same everywhere, hardcode it.

---

## Task 6: Cleanup

```
devops@testvm:~/day-80$ helm uninstall devboard-dev -n devboard-dev
devops@testvm:~/day-80$ helm uninstall devboard-staging -n devboard-staging

devops@testvm:~$ kubectl get pvc -A | grep devboard
devboard-dev       data-devboard-dev-devboard-postgres-0       Bound   1Gi
devboard-staging   data-devboard-staging-devboard-postgres-0   Bound   5Gi
```

**PVCs survive**, for Day 56's reason — the StatefulSet controller created them, so Helm never owned them.

```
devops@testvm:~$ kubectl delete namespace devboard-dev devboard-staging
```

Deleting the namespace takes everything, PVCs included.

---

## Files in this folder

| Path | What it is |
|---|---|
| `helm/devboard/` | Day 79's chart at 0.2.0 |
| `helm/devboard/templates/hooks.yaml` | pre-install/pre-upgrade DB gate, plus a `test` smoke test |
| `helm/devboard/values-dev.yaml` | Small, `latest` + `Always`, NodePort |
| `helm/devboard/values-staging.yaml` | Pinned SHA, HPA, ingress with TLS |
| `helm/devboard/values-prod.yaml` | Larger, looser probes, anti-affinity, **no password** |

---

## What I learned

**1. `hook-delete-policy` is what makes a Job hook usable twice.** A Job's spec is immutable, so a leftover from the previous release fails the next upgrade with `field is immutable`. `before-hook-creation,hook-succeeded` is the right pair — and deliberately *not* `hook-failed`, so a failure survives long enough to read its logs.

**2. In GitOps, CI never runs `helm upgrade`.** It commits an image tag to a values file and ArgoCD applies it. Which means ArgoCD renders the chart itself and there is **no Helm release history in the cluster** — `helm list` is empty and ArgoCD's history replaces it.

**3. `pullPolicy` has to match the tag strategy or deploys silently do nothing.** `latest` needs `Always` or a new image is never pulled. A pinned SHA wants `IfNotPresent`, because with `Always` a registry outage stops a restarting pod that already has the image locally.

**Two extras:**

- Values files merge per key, but **lists are replaced wholesale**. A base-plus-overlay pattern works for maps and quietly does not for arrays.
- Renaming a value in `values.yaml` is a **major** version bump even though nothing in Kubernetes broke — every caller's values file stops working.
