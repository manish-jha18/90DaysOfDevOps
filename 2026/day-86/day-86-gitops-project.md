# Day 86 – GitOps Project: End-to-End CI/CD Pipeline

Workflow in `.github/workflows/gitops-cd.yml`, drift test in `scripts/drift-test.sh`.

The whole point of the day is one change flowing from `git push` to running on EKS, with **nothing in the pipeline holding cluster credentials**.

---

## Task 1: The GitOps CI pipeline

**`.github/workflows/gitops-cd.yml`** is Day 48's pipeline with the last job replaced.

```yaml
jobs:
  build-test:      # day 48
  security:        # day 49
  tag:             # sha-8a3f91c, computed once
  docker-backend:  # build, scan, push
  docker-frontend:
  update-manifest: # ← the only new job
```

The first five are unchanged. The sixth is where GitOps happens:

```yaml
  update-manifest:
    runs-on: ubuntu-latest
    needs: [tag, docker-backend, docker-frontend]
    permissions:
      contents: write
    steps:
      - uses: actions/checkout@v4

      - name: Update the image tags in values.yaml
        env:
          TAG: ${{ needs.tag.outputs.sha_tag }}
        run: |
          yq -i ".backend.image.tag = strenv(TAG)"  helm/devboard/values.yaml
          yq -i ".frontend.image.tag = strenv(TAG)" helm/devboard/values.yaml

      - name: Commit and push
        run: |
          git config user.name "manish-jha18"
          git config user.email "manishkumar181999@gmail.com"
          if git diff --quiet; then
            echo "tags unchanged, nothing to commit"
            exit 0
          fi
          git add helm/devboard/values.yaml
          git commit -m "chore: deploy $TAG [skip ci]"
          git pull --rebase
          git push
```

**No `kubectl`. No `helm`. No kubeconfig.** The job's entire output is a commit.

**Four details that are load-bearing:**

**`yq -i` rather than `sed`.** yq edits the YAML structure; sed matches text. A `sed 's/tag: .*/tag: new/'` hits every `tag:` in the file, including ones under other keys. This is exactly Day 38's lesson — a change that produces valid YAML with the wrong meaning is worse than one that errors.

**`strenv(TAG)` rather than interpolation.** `yq -i ".tag = \"$TAG\""` would break on a tag containing a quote, and it puts the value into the expression where yq parses it. `strenv` reads the environment variable as a literal string — the same reasoning as Day 43's `env:` block for untrusted input.

**`[skip ci]` in the commit message.** Without it: push → build → commit → push → build. An infinite loop that burns runner minutes until someone notices. Filtering on `paths-ignore` for the values file is the alternative.

**`git pull --rebase` before pushing.** Two merges finishing close together both try to push, and the second is rejected as behind. A rebase-and-retry is the difference between a pipeline that occasionally fails for no real reason and one that does not.

**`permissions: contents: write` on that job only**, not at the workflow level. Day 49's least privilege — the build jobs cannot write to the repo.

### The two-repository split

The checkout carries a comment about what a real setup does:

```yaml
        with:
          # In a real setup this is a SEPARATE repository.
          #   repository: manish-jha18/devboard-deploy
          #   token: ${{ secrets.DEPLOY_REPO_TOKEN }}
```

**Why separate:**

- A deploy does not need a code review, and a code change should not carry a deployment.
- Different access control — an SRE may deploy without commit rights to the application.
- The application repo's history stays about the application, not about 400 "chore: deploy sha-xxxx" commits.
- Reverting a deploy is a revert in the deployment repo, with no code involvement.

One repo is simpler and fine to start with. The moment more than one person deploys, the split earns itself.

---

## Task 2: Setting it up

**On the CI side** — Day 44's secrets, plus one:

```
devops@testvm:~$ gh secret list
NAME                  UPDATED
DOCKER_TOKEN          2 weeks ago
DOCKER_USERNAME       2 weeks ago
DEPLOY_REPO_TOKEN     1 minute ago
```

`DEPLOY_REPO_TOKEN` is a fine-grained PAT with **contents: write on the deployment repo only**. Not the default `GITHUB_TOKEN`, which cannot push to another repository.

**And that is the whole list.** No `KUBE_CONFIG`, no cluster CA, no service account token. That is the security argument for GitOps in one `gh secret list`.

**On the cluster side**, nothing new — Day 84's Application already watches the repo.

**Making it fast.** ArgoCD polls every 3 minutes by default. A webhook makes it immediate:

```
devops@testvm:~$ gh api repos/manish-jha18/devboard/hooks -f name=web \
  -f 'config[url]=https://argocd.devboard.example.com/api/webhook' \
  -f 'config[content_type]=json' \
  -f 'config[secret]='"$WEBHOOK_SECRET" \
  -f 'events[]=push'
```

Polling remains the fallback, which is the right shape — a missed webhook delays a deploy by three minutes rather than losing it.

---

## Task 3: The full pipeline

One trivial change, followed end to end.

```
devops@testvm:~/devboard$ sed -i 's/DevBoard/DevBoard v2/' frontend/src/components/layout/Logo.jsx
devops@testvm:~/devboard$ git commit -am "Update the logo text" && git push
```

**CI:**

```
devops@testvm:~$ gh run watch
✓ build-test / build-test          1m24s
✓ security / secret-scanning         38s
✓ security / dependency-scan         52s
✓ tag                                 3s
✓ docker-backend / docker          1m41s
✓ docker-frontend / docker         2m18s
✓ update-manifest                    12s

devops@testvm:~$ git pull && git log --oneline -2
c4d2e58 chore: deploy sha-a91f3c4 [skip ci]
a91f3c4 Update the logo text
```

**Two commits: mine, and CI's.** The second is the deployment.

```
devops@testvm:~$ git show c4d2e58 --stat
 helm/devboard/values.yaml | 4 ++--

devops@testvm:~$ git show c4d2e58 | grep -E "^[+-].*tag:"
-    tag: sha-8a3f91c
+    tag: sha-a91f3c4
-    tag: sha-8a3f91c
+    tag: sha-a91f3c4
```

**A four-line diff is the entire deployment**, and it is reviewable, revertable and attributable.

**CD:**

```
devops@testvm:~$ argocd app get devboard --refresh | grep -E "Sync Status|Revision"
Sync Status:  OutOfSync from mega-project (c4d2e58)

devops@testvm:~$ sleep 30 && argocd app get devboard | grep -E "Sync Status|Health"
Sync Status:  Synced to mega-project (c4d2e58)
Health Status: Healthy

devops@testvm:~$ kubectl get deploy -n devboard devboard-devboard-frontend \
    -o jsonpath='{.spec.template.spec.containers[0].image}'
manishjha18/devboard-frontend:sha-a91f3c4
```

```
devops@testvm:~$ ADDR=$(kubectl get gateway devboard-gateway -n devboard -o jsonpath='{.status.addresses[0].value}')
devops@testvm:~$ curl -s "http://$ADDR/" | grep -o "DevBoard v2"
DevBoard v2
```

**About seven minutes from push to live**, and roughly six of that is CI. The CD half is a git poll and a rolling update.

```
devops@testvm:~$ argocd app history devboard | tail -2
3   2026-08-19 10:02:14 +0000 UTC  mega-project (8a3f91c)
4   2026-08-19 10:14:47 +0000 UTC  mega-project (c4d2e58)
```

**Every deployment is a git commit, and every git commit is an ArgoCD revision.** Two histories that cannot disagree.

---

## Task 4: Drift detection and recovery

**`scripts/drift-test.sh`** runs three cases.

```
devops@testvm:~/day-86/scripts$ ./drift-test.sh
=== baseline ===
sync: Synced   health: Healthy

=== drift 1: scale a deployment by hand ===
replicas in git: 3
scaled to 7 - waiting for argocd to notice...
reverted to 3 after ~15s

=== drift 2: edit a configmap by hand ===
patched - waiting...
reverted to 'devboard' after ~20s

=== drift 3: delete a resource entirely ===
deleted - waiting for argocd to recreate it...
recreated after ~10s
```

**All three reverted without a human**, in 10–20 seconds. ArgoCD watches the resources it manages, so the 3-minute poll is only the fallback.

### The case that does not revert

```
=== the one drift argocd will NOT revert ===
spec.replicas on a HPA-managed deployment is in ignoreDifferences,
so a manual scale there is permanent until the HPA overrides it.
```

Day 84's `ignoreDifferences` block. **A deliberately unmanaged field is genuinely unmanaged** — and that is worth being explicit about, because "ArgoCD reverts everything" is not true and assuming it is means a manual change persisting silently.

```
devops@testvm:~$ kubectl get events -n argocd --field-selector reason=ResourceUpdated --sort-by=.lastTimestamp | tail -3
30s   ResourceUpdated  Application/devboard  Updated sync status: OutOfSync -> Synced
25s   ResourceUpdated  Application/devboard  Updated health status: Progressing -> Healthy
```

**The audit trail is the other half of the value.** Not just that drift was fixed, but that it happened at all — which is a security signal. Someone editing production by hand shows up in ArgoCD's events whether or not they meant to be noticed.

**Turning self-heal off during an incident**, because the honest answer is that sometimes you have to:

```
devops@testvm:~$ argocd app set devboard --sync-policy none
devops@testvm:~$ kubectl scale deploy -n devboard devboard-devboard-backend --replicas=10
# ... incident over ...
devops@testvm:~$ argocd app set devboard --sync-policy automated
```

ArgoCD reverts to git the moment it is re-enabled. The discipline is to make the emergency change *and then commit it* if it should persist.

---

## Task 5: The complete pipeline

Everything from Day 22 onwards, in one diagram.

```
  developer
     │  git push  (day 22-28)
     ▼
┌───────────────────── CI ─── GitHub Actions (days 38-49) ─────────────────────┐
│                                                                              │
│  build & test        go test, vitest                          day 44         │
│  security            gitleaks, govulncheck, hadolint          day 49         │
│  docker build        multi-stage, non-root                    day 35         │
│  trivy scan          GATE - fails before push                 day 49         │
│  docker push         manishjha18/...:sha-a91f3c4              day 45         │
│  update manifest     yq the tag into values.yaml              day 86         │
│                                                                              │
│  NO cluster credentials anywhere in this box                                 │
└──────────────────────────────────┬───────────────────────────────────────────┘
                                   │ git commit
                                   ▼
                          ┌─────────────────┐
                          │  git repository │  ← the single source of truth
                          └────────┬────────┘
                                   │ poll / webhook
                                   ▼
┌───────────────────── CD ─── ArgoCD on EKS (days 84-86) ──────────────────────┐
│                                                                              │
│  detect      OutOfSync                                                       │
│  render      helm template  (day 79-80)                                      │
│  apply       rolling update, maxUnavailable: 0    day 52                     │
│  reconcile   selfHeal every 3 min                                            │
└──────────────────────────────────┬───────────────────────────────────────────┘
                                   ▼
┌───────────────── EKS, built by Terraform (days 61-67, 81-83) ────────────────┐
│                                                                              │
│  Gateway API + cert-manager        day 82                                    │
│  External Secrets ← Secrets Manager, via Pod Identity   day 81               │
│  StatefulSet + EBS gp3             days 55-56, 82                            │
│  HPA + metrics-server              day 58                                    │
│                                                                              │
│  observed by Prometheus / Loki / Tempo / Grafana        days 73-77           │
└──────────────────────────────────────────────────────────────────────────────┘
```

**Where each earlier block ended up:**

| Days | In the pipeline |
|---|---|
| 1–21 | Linux and shell — the scripts, the debugging, the reflexes |
| 22–28 | Git — the substrate the whole thing runs on |
| 29–37 | Docker — the artefact CI produces |
| 38–49 | GitHub Actions — the CI half |
| 50–60 | Kubernetes — what the manifests describe |
| 61–67 | Terraform — the cluster itself |
| 68–72 | Ansible — the nodes, runners and bastions |
| 73–77 | Observability — how you know any of it works |
| 78–80 | Helm — the packaging git holds |
| 81–83 | EKS — production Kubernetes |
| 84–86 | ArgoCD — the CD half |

**The thing I did not expect:** the interesting failures were almost never in the tool being learned. They were in the seams — an init container missing so the backend raced Postgres, a subnet tag missing so a load balancer never got an address, `ignoreDifferences` missing so two controllers fought over one field. Each block on its own worked; joining them is where the work is.

**What is still missing** to call this genuinely production:

- **Progressive delivery.** A rolling update is not a canary. Argo Rollouts or Flagger would shift traffic gradually and roll back on a metrics regression — which is where Days 73–77's observability finally becomes part of the deployment decision rather than a dashboard.
- **Multi-cluster.** One cluster, no DR. ArgoCD can drive many, and ApplicationSet's cluster generator is built for it.
- **Policy enforcement.** Nothing stops a manifest requesting privileged containers. OPA Gatekeeper or Kyverno as an admission gate — Day 49's shift-left, applied at the cluster.
- **Database migrations.** The one genuinely imperative step, and GitOps has no good answer. An Argo PreSync hook is the usual place, and it is uncomfortable.

---

## Task 6: Teardown

Day 83's script, with ArgoCD handled first.

```
devops@testvm:~$ argocd app delete devboard --cascade
devops@testvm:~$ argocd app delete platform --cascade
```

**`--cascade` and the finalizer matter.** Deleting an Application without cascade leaves every resource running and unmanaged. And the parent `platform` app must go before its children, or the App-of-Apps recreates anything you delete individually.

Then Day 83's ordering, unchanged:

```
devops@testvm:~/day-83/scripts$ ./teardown.sh
=== 1/5 delete Gateways and LoadBalancer Services ===
=== 2/5 wait for the load balancers to actually disappear ===
  all gone
=== 3/5 uninstall the helm release and delete PVCs ===
=== 4/5 delete the namespace ===
=== 5/5 terraform destroy ===
Destroy complete! Resources: 71 destroyed.

=== verifying nothing is left billing ===
eks clusters:
devboard vpcs:
nat gateways:
elastic ips:
unattached volumes:
load balancers:
```

**One addition to the checklist when ArgoCD is involved:** disable auto-sync before tearing down, or ArgoCD helpfully recreates what you are trying to delete. Self-healing does not know the difference between drift and a teardown.

```
devops@testvm:~$ aws ce get-cost-and-usage --time-period Start=2026-08-19,End=2026-08-20 \
    --granularity DAILY --metrics UnblendedCost \
    --query 'ResultsByTime[0].Total.UnblendedCost.Amount' --output text
9.12
```

---

## Files in this folder

| Path | What it is |
|---|---|
| `.github/workflows/gitops-cd.yml` | CI ending in a git commit, not a deploy |
| `scripts/drift-test.sh` | Three drift cases, plus the one ArgoCD will not revert |

---

## What I learned

**1. The CI pipeline holds no cluster credentials at all.** `gh secret list` is a Docker token and a repo PAT. Every push-based pipeline before this needed a kubeconfig with broad cluster rights sitting in a CI secret — removing that is the strongest argument for GitOps, and it is visible in one command.

**2. `[skip ci]` is not optional when CI commits to the repo it watches.** Without it: push, build, commit, push, build — an infinite loop burning runner minutes. And `git pull --rebase` before pushing, because two merges finishing together otherwise fail the second one.

**3. "ArgoCD reverts everything" is not true, and the exceptions are the ones that matter.** A field in `ignoreDifferences` is genuinely unmanaged, so a manual scale on an HPA-backed deployment persists silently. Knowing which fields are excluded is part of knowing what the cluster guarantees.

**Two extras:**

- `yq -i` with `strenv()`, never `sed`. sed matches text and can produce valid YAML with the wrong meaning — Day 38's worst case, in a pipeline that runs unattended.
- Disable auto-sync before a teardown. Self-healing cannot tell a deliberate deletion from drift, and will happily recreate what you are removing.
