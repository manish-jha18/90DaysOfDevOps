# Day 84 – Introduction to GitOps and ArgoCD

Manifests in `argocd/` in this folder. Deployed onto the EKS cluster from Day 81.

Using **DevBoard** rather than AI-BankApp, as on Days 78–83. `mega-project` already carries the ArgoCD Applications.

---

## Task 1: GitOps

**The one-line version: CI pushes to git, CD pulls from git.**

Everything up to Day 83 was **push-based**. The pipeline had cluster credentials and ran `kubectl apply` or `helm upgrade` from a GitHub runner. GitOps inverts that — an agent inside the cluster watches a repository and applies what it finds.

```
PUSH (day 48, day 83)                 PULL (GitOps)

  CI runner                             CI runner
      │ holds kube credentials              │ holds NO cluster credentials
      │ kubectl apply                       │ git commit
      ▼                                     ▼
   cluster                             git repository
                                            ▲
                                            │ polls / webhook
                                       ArgoCD (in the cluster)
                                            │
                                            ▼
                                        cluster
```

### The four principles

**1. Declarative.** The system is described by data, not by a script. Every day from 51 onwards has been building towards this.

**2. Versioned and immutable.** Git is the source of truth, with full history and review.

**3. Pulled automatically.** An agent applies approved changes; nothing external needs access.

**4. Continuously reconciled.** The agent does not just apply once — it keeps checking, and corrects drift. That is the property that turns git from a record into a guarantee.

### Why the pull model matters more than it first looks

**No cluster credentials in CI.** Day 44's biggest risk was a `DOCKER_TOKEN` in GitHub secrets. A kubeconfig with cluster-admin is far worse, and push-based CD requires one. With GitOps the runner needs only a registry token and write access to a git repo.

**Drift is corrected, not just detected.** Day 64's `terraform plan -detailed-exitcode` on a schedule tells you something changed. ArgoCD's `selfHeal` puts it back within seconds.

**Every change has an author and a diff.** `kubectl edit` on a production deployment leaves no record of who or why. Under GitOps, that edit is reverted and the only way to make it stick is a commit.

**Rollback is `git revert`.** Not a separate mechanism to learn, and Day 25's argument applies — revert rather than reset, because history should move forward.

### Where it does not fit

**Secrets.** Git cannot hold a plaintext password. Days 71 and 82 covered both answers: Sealed Secrets or SOPS for encrypted-in-git, or External Secrets pointing at a vault. DevBoard uses the second.

**Anything imperative.** A one-off database migration, a manual failover, an emergency scale-up. GitOps is for desired state, and "run this once" is not a state.

**Cluster bootstrap.** Something has to install ArgoCD before ArgoCD can install anything — Day 81's Terraform does it, and that is the same chicken-and-egg as Day 64's state bucket.

---

## Task 2: Accessing ArgoCD

Day 81's Terraform installed it:

```hcl
resource "helm_release" "argocd" {
  count      = var.enable_argocd ? 1 : 0
  name       = "argocd"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  version    = var.argocd_chart_version
  namespace        = "argocd"
  create_namespace = true
  wait    = true
  timeout = 900
}
```

**`version` pinned to a variable**, not floating — a cluster built today matches one built next month.

```
devops@testvm:~$ kubectl get pods -n argocd
NAME                                              READY   STATUS    AGE
argocd-application-controller-0                   1/1     Running   4m
argocd-applicationset-controller-6d9f4b8c7-k7w    1/1     Running   4m
argocd-dex-server-5c8f2a91d4-p2nvx                1/1     Running   4m
argocd-notifications-controller-7d4f8b9c6d-2xk    1/1     Running   4m
argocd-redis-8prlv                                1/1     Running   4m
argocd-repo-server-6b8d9f4c2a-vz9lt               1/1     Running   4m
argocd-server-9e1c4a7b3f-m2plq                    1/1     Running   4m
```

**What each does**, because knowing this is what makes debugging possible:

| Component | Job |
|---|---|
| **application-controller** | The reconcile loop. Compares desired to live and syncs |
| **repo-server** | Clones git, renders Helm/Kustomize into plain manifests |
| **server** | API and UI. **Not** in the sync path at all |
| **redis** | Cache of rendered manifests |
| **dex** | SSO, if configured |
| **notifications-controller** | Day 85 |
| **applicationset-controller** | Generates Applications from a template |

**The server being outside the sync path matters:** ArgoCD keeps reconciling with the UI down. Conversely, a stuck sync is a controller or repo-server problem, and the UI will not show you why — `kubectl logs` on those two will.

```
devops@testvm:~$ kubectl -n argocd get secret argocd-initial-admin-secret \
    -o jsonpath='{.data.password}' | base64 -d; echo
xK9mQ2pR4wN6yB1c

devops@testvm:~$ kubectl port-forward svc/argocd-server -n argocd 8080:80 &
devops@testvm:~$ argocd login localhost:8080 --username admin --password xK9mQ2pR4wN6yB1c --insecure
'admin:login' logged in successfully
```

**`server.insecure: true`** in the install values is there because ArgoCD terminates TLS itself by default. Behind a proxy that is already terminating TLS, that produces a redirect loop. Day 82's Gateway would do the terminating.

**Delete the initial admin secret once you have changed the password** — it stays in the cluster otherwise, holding a working credential.

---

## Task 3: The Application manifest

**`argocd/devboard-app.yaml`**

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: devboard
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default

  source:
    repoURL: https://github.com/manish-jha18/devboard.git
    targetRevision: mega-project
    path: helm/devboard
    helm:
      releaseName: devboard
      valueFiles:
        - values.yaml

  destination:
    server: https://kubernetes.default.svc
    namespace: devboard

  ignoreDifferences:
    - group: apps
      kind: Deployment
      jsonPointers:
        - /spec/replicas

  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

**Four fields worth explaining properly.**

### `ignoreDifferences` on `/spec/replicas`

This is the most important field in the file and the least obvious.

Day 58 established that an HPA owns the replica count. Day 79's chart omits `replicas` when the HPA is enabled. But ArgoCD compares **live state** against **rendered manifests**, and the live Deployment has whatever the HPA set. Without this exclusion:

1. ArgoCD renders the chart, sees no `replicas`, defaults to 1
2. The HPA has scaled to 5
3. ArgoCD reports `OutOfSync`
4. With `selfHeal: true`, ArgoCD sets it to 1
5. The HPA sets it back to 5
6. Repeat every few seconds, forever

**Two controllers fighting over one field.** `ignoreDifferences` is how you tell ArgoCD that something else legitimately owns it — the same idea as Terraform's `lifecycle { ignore_changes }` from Day 62.

### `prune: true`

Deletes resources that were removed from git. **Off by default**, and without it deleting a manifest file leaves the object running in the cluster indefinitely — git says it is gone and the cluster disagrees.

The reason it is off by default is that a mistake here deletes things. `prune` plus a bad path in `source` means ArgoCD sees an empty directory and removes everything.

### `selfHeal: true`

Reverts manual changes. The property that makes git a guarantee rather than a record.

### `finalizers`

Without the finalizer, deleting the Application object leaves all its resources running — you get an orphaned application nothing manages. With it, ArgoCD cleans up first.

### Branch versus tag

`targetRevision: mega-project` is a **branch**, so ArgoCD follows every commit. That is right for dev and wrong for production. `argocd/devboard-app-pinned.yaml` shows the other shape:

```yaml
    targetRevision: v1.0.0    # an immutable tag
  syncPolicy:
    # no automated block - sync is a deliberate act
    syncOptions:
      - CreateNamespace=true
```

**Automated sync off, but `selfHeal` deliberately not the reason** — a production app still wants drift reverted; it just does not want a new *release* on every commit. Day 45's immutable-tag reasoning, applied to git refs.

---

## Task 4: Deploying

```
devops@testvm:~/day-84$ kubectl apply -f argocd/devboard-app.yaml
application.argoproj.io/devboard created

devops@testvm:~$ argocd app get devboard
Name:               argocd/devboard
Project:            default
Server:             https://kubernetes.default.svc
Namespace:          devboard
Repo:               https://github.com/manish-jha18/devboard.git
Target:             mega-project
Path:               helm/devboard
SyncWindow:         Sync Allowed
Sync Policy:        Automated (Prune)
Sync Status:        Synced to mega-project (8a3f91c)
Health Status:      Healthy

GROUP  KIND        NAMESPACE  NAME                        STATUS  HEALTH
       Namespace   devboard   devboard                    Synced
       ConfigMap   devboard   devboard-devboard-config    Synced
       Service     devboard   devboard-devboard-backend   Synced  Healthy
apps   Deployment  devboard   devboard-devboard-backend   Synced  Healthy
apps   StatefulSet devboard   devboard-devboard-postgres  Synced  Healthy
```

**Two independent statuses**, and conflating them is a common mistake:

- **Sync Status** — does the cluster match git?
- **Health Status** — are the workloads actually working?

`Synced` + `Degraded` is entirely possible and is the interesting case: the cluster matches git exactly, and what git says is broken. That points at the manifests, not at the sync.

**No Helm release exists in the cluster:**

```
devops@testvm:~$ helm list -n devboard
NAME  NAMESPACE  REVISION  STATUS  CHART  APP VERSION
```

Empty. **ArgoCD renders the chart itself** — `repo-server` runs `helm template` and applies the output. It never runs `helm install`, so there are no `sh.helm.release.v1.*` secrets and no `helm history`.

Day 80 predicted this and it is still surprising in practice. The consequences: `helm rollback` does not exist, ArgoCD's own history replaces it, and hooks behave differently — Helm hooks are translated into ArgoCD resource hooks, and `helm test` never runs.

---

## Task 5: The live view

```
devops@testvm:~$ argocd app diff devboard
===== apps/Deployment devboard/devboard-devboard-backend ======
25c25
<     replicas: 3
---
>     replicas: 1
```

**`argocd app diff` is the `terraform plan` of GitOps** — live versus desired, before syncing.

That particular diff is the HPA one, shown because `argocd app diff` reports it even though `ignoreDifferences` stops the controller acting on it. Worth knowing so it is not mistaken for a real problem.

```
devops@testvm:~$ argocd app resources devboard
GROUP  KIND         NAMESPACE  NAME                          ORPHANED
       Service      devboard   devboard-devboard-backend     No
apps   Deployment   devboard   devboard-devboard-backend     No
autoscaling HorizontalPodAutoscaler devboard ...-frontend    No
```

**`ORPHANED`** flags resources in the namespace that ArgoCD does not manage — anything created by hand, or left behind by a `prune: false` deletion.

```
devops@testvm:~$ argocd app history devboard
ID  DATE                           REVISION
0   2026-08-18 09:14:22 +0000 UTC  mega-project (8a3f91c)
1   2026-08-18 09:41:08 +0000 UTC  mega-project (c2f8b41)
```

Every sync recorded with its git revision. `argocd app rollback devboard 0` is Day 85.

---

## Task 6: Self-healing

The demonstration that makes GitOps concrete.

```
devops@testvm:~$ kubectl scale deploy -n devboard devboard-devboard-frontend --replicas=9
deployment.apps/devboard-devboard-frontend scaled

devops@testvm:~$ kubectl get deploy -n devboard devboard-devboard-frontend
NAME                         READY   UP-TO-DATE   AVAILABLE
devboard-devboard-frontend   3/9     9            3
```

Nothing happens for a while — that is `ignoreDifferences` on `/spec/replicas` working as designed. The HPA eventually pulls it back down.

**A field that is *not* ignored behaves completely differently:**

```
devops@testvm:~$ kubectl patch configmap -n devboard devboard-devboard-config \
    --type merge -p '{"data":{"POSTGRES_DB":"tampered"}}'
configmap/devboard-devboard-config patched

devops@testvm:~$ kubectl get configmap -n devboard devboard-devboard-config -o jsonpath='{.data.POSTGRES_DB}'
tampered

devops@testvm:~$ sleep 20
devops@testvm:~$ kubectl get configmap -n devboard devboard-devboard-config -o jsonpath='{.data.POSTGRES_DB}'
devboard
```

**Reverted in about 20 seconds, with no human involved.**

```
devops@testvm:~$ kubectl delete svc -n devboard devboard-devboard-backend
service "devboard-devboard-backend" deleted

devops@testvm:~$ sleep 20
devops@testvm:~$ kubectl get svc -n devboard devboard-devboard-backend
NAME                        TYPE        CLUSTER-IP      PORT(S)
devboard-devboard-backend   ClusterIP   10.96.201.44    8080/TCP
```

**Deleted and recreated.** The ClusterIP is different, which is worth noticing — ArgoCD recreated the object rather than restoring it, so anything that cached the old IP is broken until it re-resolves. Self-healing is not free.

```
devops@testvm:~$ kubectl get events -n argocd --field-selector reason=ResourceUpdated --sort-by=.lastTimestamp | tail -3
2m  ResourceUpdated  Application/devboard  Updated health status: Healthy
1m  ResourceUpdated  Application/devboard  Updated sync status: OutOfSync -> Synced
```

**The default reconcile interval is 3 minutes**, and these reverted in 20 seconds because ArgoCD also watches the cluster for changes to resources it manages. Polling is the fallback for changes it cannot observe.

**Turning `selfHeal` off** leaves ArgoCD reporting `OutOfSync` and doing nothing — useful during an incident when you genuinely need to change something live. Turning it back on is what reverts.

---

## Files in this folder

| Path | What it is |
|---|---|
| `argocd/install-values.yaml` | `server.insecure`, ClusterIP, resource requests |
| `argocd/devboard-app.yaml` | Branch-tracking, automated sync, prune + selfHeal |
| `argocd/devboard-app-pinned.yaml` | Tag-pinned, manual sync — the production shape |

---

## What I learned

**1. ArgoCD renders the chart itself, so there is no Helm release in the cluster.** `helm list` is empty, `helm history` does not exist, and `helm test` never runs. ArgoCD's own history replaces all of it. Day 80 predicted this and it is still disorienting the first time you go looking for a release that is not there.

**2. `ignoreDifferences` on `/spec/replicas` is not optional with an HPA.** Without it, ArgoCD and the HPA fight over the same field every few seconds forever. Two controllers owning one field is a general failure mode — Terraform's `ignore_changes` exists for the same reason.

**3. Sync status and health status are independent, and `Synced + Degraded` is the informative case.** It means the cluster matches git exactly and what git says is broken — which points the investigation at the manifests rather than at the delivery.

**Two extras:**

- `prune` is off by default because a wrong `path` in `source` plus `prune: true` deletes everything ArgoCD thinks was removed.
- Self-healing recreates rather than restores. The Service came back with a different ClusterIP, so it is a repair, not an undo.
