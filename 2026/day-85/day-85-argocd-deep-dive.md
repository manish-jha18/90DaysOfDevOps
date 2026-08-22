# Day 85 – ArgoCD Deep Dive: Sync Strategies, Rollbacks and Multi-App Management

Manifests in `argocd/` in this folder.

---

## Task 1: Sync strategies

Four dials, and they are independent:

| Setting | Default | Does |
|---|---|---|
| `automated` | off | Sync without being asked |
| `automated.prune` | off | Delete what git no longer has |
| `automated.selfHeal` | off | Revert manual drift |
| `syncOptions` | — | Per-app behaviour, e.g. `CreateNamespace=true` |

**All three off is a valid and useful configuration.** ArgoCD then acts as a drift *detector* — it shows `OutOfSync` and a diff, and a human clicks sync. That is what a regulated environment usually wants.

**The four combinations that make sense:**

| Config | Behaviour | For |
|---|---|---|
| Nothing automated | Detect only | Production with change control |
| `automated` only | Deploys new commits, ignores drift | Rare — usually a mistake |
| `automated` + `selfHeal` | Deploys and reverts, leaves orphans | Cautious production |
| All three | Full reconciliation | Dev, staging, and confident production |

**`automated` without `selfHeal` is the odd one out.** It applies new commits but leaves a manual `kubectl edit` in place — so the cluster silently diverges from git while still looking managed. Either commit to reconciliation or do not.

**Sync options worth knowing:**

```yaml
    syncOptions:
      - CreateNamespace=true      # or the first sync fails on a missing namespace
      - ServerSideApply=true      # for large CRDs, see below
      - PruneLast=true            # delete removed resources AFTER creating new ones
      - RespectIgnoreDifferences=true
      - ApplyOutOfSyncOnly=true   # only touch what differs - faster on big apps
```

**`ServerSideApply=true`** is the one that comes up unexpectedly. Client-side apply stores the whole manifest in a `last-applied-configuration` annotation, and annotations are capped at **262144 bytes**. cert-manager's CRDs exceed that, so the sync fails with a `metadata.annotations: Too long` error that says nothing about CRDs. devboard's `cert-manager.yaml` carries that exact note.

---

## Task 2: Sync waves

**The problem:** ArgoCD applies everything at once. That works until one resource depends on another existing first — a `ClusterSecretStore` needs the External Secrets CRDs, a `ClusterIssuer` needs cert-manager's.

**Sync waves are an ordering annotation:**

```yaml
metadata:
  annotations:
    argocd.argoproj.io/sync-wave: "0"
```

Lower runs first. **ArgoCD waits for every resource in a wave to be Healthy before starting the next.** That "Healthy" part is what makes it more than a sort order — it is a dependency barrier.

The platform stack, laid out by wave:

```
wave 0   external-secrets          operators that install CRDs
         cert-manager

wave 1   external-secrets-config   ClusterSecretStore  ← needs wave-0 CRDs
         cert-manager-config       ClusterIssuers      ← needs wave-0 CRDs
         observability-prometheus  storage backend

wave 2   observability-collector   needs prometheus to exist

wave 3   observability-grafana     datasources point at waves 1-2

wave 4   observability-config      dashboards, ServiceMonitors
         observability-dashboards

wave 5   ollama                    heavy, and depends on storage
```

**Two things this encodes that are not obvious:**

**Operators and their configuration are always two waves apart.** The CRD has to exist before anything of that kind can be created. Putting a `ClusterIssuer` in the same wave as cert-manager gives `no matches for kind "ClusterIssuer"`.

**Grafana is wave 3, not wave 1**, because its provisioned datasources reference Prometheus and Loki by service name. It would start either way and its datasources would be broken.

```
devops@testvm:~$ kubectl apply -f argocd/platform-app.yaml
application.argoproj.io/platform created

devops@testvm:~$ watch -n2 'argocd app list -o name'
argocd/platform
argocd/cert-manager
argocd/external-secrets
argocd/cert-manager-config
argocd/external-secrets-config
argocd/observability-prometheus
argocd/observability-grafana
```

**Children appearing in wave order**, several seconds apart. One `kubectl apply` bootstrapped the whole platform.

### The cert-manager ordering trap

devboard's comment records a failure that waves alone do not fix:

> cert-manager checks for the Gateway API CRDs only at **STARTUP**. Boot it before Envoy Gateway and every Certificate sits Pending.

**A startup-time check is invisible to sync waves.** cert-manager starts, does not find the Gateway API CRDs, disables its Gateway solver, and reports itself Healthy. Wave 1 proceeds, the ClusterIssuers are created, and every Certificate then sits Pending with no error explaining why.

```
devops@testvm:~$ kubectl rollout restart deploy cert-manager -n cert-manager
```

That is the fix, and it is the kind of thing you only learn by hitting it. The general lesson: **a wave barrier waits for Healthy, and Healthy does not mean "has everything it needs".**

Two related hooks:

```yaml
    argocd.argoproj.io/hook: PreSync          # Helm's pre-install (day 80)
    argocd.argoproj.io/hook-delete-policy: HookSucceeded
    argocd.argoproj.io/sync-options: SkipDryRunOnMissingResource=true
```

That last one is for a resource whose CRD does not exist at plan time — ArgoCD dry-runs everything before applying, and without it a wave-1 resource fails validation because its wave-0 CRD is not there yet.

---

## Task 3: Rollbacks

```
devops@testvm:~$ argocd app history devboard
ID  DATE                           REVISION
0   2026-08-18 09:14:22 +0000 UTC  mega-project (8a3f91c)
1   2026-08-18 09:41:08 +0000 UTC  mega-project (c2f8b41)
2   2026-08-18 10:02:14 +0000 UTC  mega-project (7f4e9d2)

devops@testvm:~$ argocd app rollback devboard 1
Rollback 'devboard' to 1
Application 'devboard' rolled back
```

**A rollback is a sync to an older git revision**, not a stored snapshot the way Helm's is. ArgoCD re-renders the chart at that commit and applies the result.

**And with `automated` on, it does not stick:**

```
devops@testvm:~$ argocd app get devboard | grep -E "Sync Status|Revision"
Sync Status:  OutOfSync from mega-project (7f4e9d2)

devops@testvm:~$ sleep 180 && argocd app get devboard | grep "Sync Status"
Sync Status:  Synced to mega-project (7f4e9d2)
```

**Rolled forward again within one reconcile interval**, because git still says `7f4e9d2` and automated sync exists to make the cluster match git.

**That is not a bug — it is the model working.** An `argocd app rollback` on an automated app is a temporary override, useful for the ninety seconds it takes to confirm the previous version is fine.

**The real rollback is `git revert`:**

```
devops@testvm:~$ git revert 7f4e9d2 && git push
```

ArgoCD picks it up and syncs. Day 25's argument, arriving for the third time: revert rather than reset, because history should move forward and a revert is a reviewable commit.

**When `argocd app rollback` is genuinely right:** the app has automated sync off. Then it *is* the deploy mechanism, and rolling back is a legitimate operation rather than a fight with the controller.

**During an incident**, the honest sequence is:

```
devops@testvm:~$ argocd app set devboard --sync-policy none    # stop the fight
devops@testvm:~$ argocd app rollback devboard 1                # restore service
# then fix it properly in git, and re-enable
devops@testvm:~$ argocd app set devboard --sync-policy automated
```

Disabling automation first is the step people skip, and it is why the rollback appears not to work.

---

## Task 4: App of Apps

**`argocd/platform-app.yaml`** is one Application whose source is a **directory of other Application manifests**.

```yaml
  source:
    repoURL: https://github.com/manish-jha18/devboard.git
    targetRevision: mega-project
    path: gitops/argocd/platform
  destination:
    namespace: argocd
```

**The destination is `argocd`**, because the resources this app manages are Application objects, which live there. Each child then deploys to its own namespace.

**Why bother:**

**One object to bootstrap a cluster.** `kubectl apply -f platform-app.yaml` on a fresh cluster brings up cert-manager, External Secrets, the observability stack and everything else — in the right order, from git.

**Adding a component is a new file.** Drop `platform/redis.yaml` into the directory, commit, and ArgoCD creates the Application. No cluster access needed.

**Removing one is deleting a file**, because the parent has `prune: true`. That is also the sharp edge — a mistaken deletion removes the whole component.

**The parent is self-managing.** Editing `platform-app.yaml` in git updates the parent, which updates the children.

```
devops@testvm:~$ argocd app get platform
Name:        argocd/platform
Sync Status: Synced to mega-project (8a3f91c)
Health:      Healthy

GROUP        KIND         NAMESPACE  NAME                      STATUS  HEALTH
argoproj.io  Application  argocd     cert-manager              Synced  Healthy
argoproj.io  Application  argocd     cert-manager-config       Synced  Healthy
argoproj.io  Application  argocd     external-secrets          Synced  Healthy
argoproj.io  Application  argocd     observability-prometheus  Synced  Healthy
argoproj.io  Application  argocd     observability-grafana     Synced  Healthy
```

**The parent's health is the aggregate of its children.** One child Degraded turns the parent Degraded, which is a genuinely useful single indicator for "is the platform up".

**ApplicationSet is the next step**, generating Applications from a template rather than listing them:

```yaml
kind: ApplicationSet
spec:
  generators:
    - list:
        elements:
          - env: dev
          - env: staging
          - env: prod
  template:
    metadata:
      name: 'devboard-{{env}}'
    spec:
      source:
        helm:
          valueFiles: ['values-{{env}}.yaml']
      destination:
        namespace: 'devboard-{{env}}'
```

Three environments from one template, using Day 80's values files. Generators exist for git directories, cluster lists and pull requests — the PR generator creating a preview environment per open PR is the impressive one.

**App of Apps for a heterogeneous set** (cert-manager, Prometheus, Ollama — all different). **ApplicationSet for a homogeneous set** (the same app across environments or clusters).

---

## Task 5: Notifications

**`argocd/notifications.yaml`**

```yaml
data:
  service.slack: |
    token: $slack-token

  template.app-sync-failed: |
    message: |
      :x: *{{.app.metadata.name}}* sync FAILED
      Revision: {{.app.status.operationState.syncResult.revision}}
      Error: {{.app.status.operationState.message}}
      <{{.context.argocdUrl}}/applications/{{.app.metadata.name}}|Open in ArgoCD>

  trigger.on-sync-failed: |
    - when: app.status.operationState.phase in ['Error', 'Failed']
      send: [app-sync-failed]
      oncePer: app.status.operationState.syncResult.revision

  subscriptions: |
    - recipients:
        - slack:devops-alerts
      triggers:
        - on-sync-failed
        - on-health-degraded
```

**`$slack-token` refers to a key in `argocd-notifications-secret`**, not an inline value. The `$` prefix is the indirection — Day 71's vault pattern in another form.

**`oncePer` is the field that makes this bearable.** Without it, a persistently failing sync notifies on **every reconcile loop** — every three minutes, indefinitely. `oncePer: <revision>` means one message per git revision, so a broken commit produces one alert rather than 480 a day.

This is Alertmanager's grouping and inhibition from Day 76, solving the same problem in a different tool. Any alerting system that does not dedupe becomes noise, and noise gets muted.

**`subscriptions` at the ConfigMap level** subscribes every Application at once, rather than annotating each one. Per-app subscriptions are an annotation:

```yaml
  annotations:
    notifications.argoproj.io/subscribe.on-sync-failed.slack: devboard-team
```

**Which triggers are worth having:** `on-sync-failed` and `on-health-degraded`, always. `on-sync-succeeded` in dev where it is a useful heartbeat, and off in production where it is 40 messages a day nobody reads.

---

## Task 6: Projects and RBAC

**`argocd/appproject.yaml`**

The `default` project permits any repo to deploy anything to anywhere. Fine for one team, wrong the moment there are two.

```yaml
spec:
  sourceRepos:
    - https://github.com/manish-jha18/devboard.git

  destinations:
    - server: https://kubernetes.default.svc
      namespace: devboard
    - server: https://kubernetes.default.svc
      namespace: devboard-*

  clusterResourceWhitelist:
    - group: ""
      kind: Namespace

  clusterResourceBlacklist:
    - group: rbac.authorization.k8s.io
      kind: ClusterRole
    - group: rbac.authorization.k8s.io
      kind: ClusterRoleBinding
```

**Three boundaries, and the third is the one that matters:**

**`sourceRepos`** — this project can only deploy from DevBoard's repo. Someone cannot point an Application at their own fork.

**`destinations`** — only into `devboard` and `devboard-*`. It cannot deploy into `kube-system` or `argocd`.

**`clusterResourceBlacklist` on ClusterRole and ClusterRoleBinding** is the privilege-escalation stop. **Without it, a team with write access to a git repo can grant itself cluster-admin** — commit a ClusterRoleBinding, ArgoCD applies it with its own high privileges, and the boundary is gone. ArgoCD runs with broad permissions by design, so the project is where you constrain what it will use them for.

Day 49's least-privilege reasoning, in the highest-stakes place it has appeared.

**Project roles for humans:**

```yaml
  roles:
    - name: developer
      policies:
        - p, proj:devboard:developer, applications, get, devboard/*, allow
        - p, proj:devboard:developer, applications, sync, devboard/*, allow
        - p, proj:devboard:developer, applications, delete, devboard/*, deny
      groups:
        - devboard-developers
```

Casbin syntax — `p, subject, resource, action, object, effect`. Developers can view and sync but not delete, and `groups` maps to an SSO group from Dex.

**Sync windows** are the other feature worth knowing:

```yaml
  syncWindows:
    - kind: deny
      schedule: '0 17 * * 5'
      duration: 63h
      applications: ['devboard-prod']
```

No production syncs from Friday 5pm to Monday 8am. A policy expressed as configuration rather than as a rule people are asked to remember.

---

## Files in this folder

| Path | What it is |
|---|---|
| `argocd/platform-app.yaml` | The App of Apps parent |
| `argocd/platform/*.yaml` | Six child Applications across waves 0–3 |
| `argocd/appproject.yaml` | Repo, destination and cluster-resource boundaries; a developer role |
| `argocd/notifications.yaml` | Slack service, templates, triggers with `oncePer` |

---

## What I learned

**1. `argocd app rollback` does not stick on an app with automated sync.** ArgoCD rolls forward again within one reconcile interval, because git still says the newer commit. The real rollback is `git revert`, and during an incident you disable the sync policy *first* — which is the step that makes the difference between "rollback does not work" and understanding why.

**2. `clusterResourceBlacklist` on ClusterRole and ClusterRoleBinding is the privilege-escalation stop.** ArgoCD applies manifests with broad permissions, so anyone with write access to a watched repo could otherwise commit a ClusterRoleBinding and grant themselves cluster-admin. The AppProject is where that gets constrained.

**3. A sync wave waits for Healthy, and Healthy does not mean "has what it needs".** cert-manager checks for the Gateway API CRDs only at startup, reports itself Healthy without them, and every Certificate then hangs Pending with no error. A `rollout restart` fixes it — and the general lesson is that ordering by health does not cover startup-time capability checks.

**Two extras:**

- `oncePer` on a notification trigger turns a persistent failure from 480 messages a day into one per git revision. The same problem Alertmanager's grouping solves.
- `ServerSideApply=true` for anything with large CRDs. Client-side apply stores the manifest in a 262144-byte annotation, and cert-manager's CRDs exceed it — with an error that never mentions CRDs.
