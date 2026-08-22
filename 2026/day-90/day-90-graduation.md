# Day 90 – Grand Finale: The Complete DevOps Journey

No new tools today. Just working out what I actually have.

---

## The timeline

| Days | Block | What it left me with |
|---|---|---|
| 1–13 | Linux | Processes, systemd, permissions, ownership, LVM. Everything else runs on this. |
| 14–15 | Networking | DNS, CIDR, ports, `ss`. Enough to debug why something cannot reach something else. |
| 16–21 | Shell scripting | 22 scripts. `set -euo pipefail`, traps, functions, cron. |
| 22–28 | Git & GitHub | Branching, rebase, stash, cherry-pick, reset vs revert, `gh`. |
| 29–37 | Docker | Layers, multi-stage builds, volumes, networks, Compose, Docker Hub. |
| 38–49 | GitHub Actions | 31 workflow files. Reusable workflows, matrices, secrets, caching, DevSecOps. |
| 50–60 | Kubernetes | 28 manifests. Pods → Deployments → Services → PVCs → StatefulSets → probes → HPA. |
| 61–67 | Terraform | State, remote backends, modules, workspaces. Built the bootstrap bucket first. |
| 68–72 | Ansible | 35 files, a 3-role project, Vault. |
| 73–77 | Observability | Prometheus, Grafana, Loki, OpenTelemetry, Alertmanager, all in Compose. |
| 78–80 | Helm | Built the devboard chart from scratch, then dev/staging/prod values and hooks. |
| 81–83 | Amazon EKS | Terraform-provisioned, Gateway API, cert-manager, External Secrets, gp3. |
| 84–86 | ArgoCD & GitOps | App of Apps, sync waves, AppProject RBAC, CI that ends in a git commit. |
| 87–89 | Agentic AI | ReAct agents, MCP, KubeHealer with Temporal. |

**Seven weeks in, the day folders stopped being exercises and started being a system.** Day 61's Terraform built the cluster that Day 84's ArgoCD deploys into, using the chart from Day 79, watched by the stack from Day 77.

---

## Task 1: One change, all 90 days

Tracing the logo-text change I pushed on Day 86:

```
1.  I edit a file on a Linux VM                          days 1-13
       in a shell I can actually drive                   days 16-21
2.  git commit, git push                                 days 22-28
3.  GitHub Actions wakes up                              days 38-47
       go test / vitest                                  day 44
       gitleaks, govulncheck, trivy - the gate           day 49
4.  docker build, multi-stage, non-root                  days 29-37
       push manishjha18/devboard-*:sha-a91f3c4           day 45
5.  the pipeline yq's the tag into values.yaml
       and commits it. no kubectl anywhere.              day 86
6.  ArgoCD sees the commit, renders the chart            days 78-80, 84
       and applies it to EKS                             days 81-83
7.  onto a cluster Terraform built                       days 61-67
       on nodes Ansible configured                       days 68-72
8.  Prometheus scrapes it, Loki has the logs,
       Grafana shows both, Alertmanager pages            days 73-77
9.  when it breaks, an agent reads the events
       and says what is wrong                            days 87-89
10. the fix goes through git, ArgoCD syncs, repeat
```

**Seven minutes end to end, and six of those are CI.**

The thing I did not see coming: **almost every real problem lived in a seam, not in a tool.** Each block worked fine on its own. What broke was Postgres not being ready when the backend started, a load balancer with no address because a subnet tag was missing, ArgoCD and the HPA fighting over `spec.replicas`. Learning the tools took 90 days; learning that the joins are where the bugs are took about five.

---

## Task 2: The project that carried it

The course used AI-BankApp. I used **[devboard](https://github.com/manish-jha18/devboard)** instead — the project I had been working on through this DevOps course. A Go backend with a React frontend and Postgres, so I could not copy-paste past anything I did not understand.

| Day | What devboard got |
|---|---|
| 36 | Dockerised: multi-stage, non-root, `manishjha18/devboard-*` |
| 48 | Full CI: build, test, scan, push |
| 49 | DevSecOps: trivy gate, SHA-pinned actions, least-privilege `permissions:` |
| 60 | Capstone deploy on Kubernetes |
| 66 | EKS cluster from the registry modules |
| 79 | 12 raw manifests → a Helm chart |
| 80 | v0.2.0: dev/staging/prod values, hooks, `checksum/config` |
| 83 | Production on EKS: Gateway API, TLS, External Secrets, gp3 |
| 84 | ArgoCD Application, pointed at the chart in git |
| 85 | App of Apps, sync waves, AppProject with a ClusterRole blacklist |
| 86 | CI that ends in a commit — no kubeconfig in the pipeline at all |
| 88 | An agent that answers "CI passed, but is it actually running?" |

**One repo, thirteen blocks.** That is why the write-ups cross-reference each other — they are describing the same thing at different stages.

---

## Task 3: Skills inventory

Honest, and this is the useful part of today.

| Skill | Days | 1–5 | Where I actually am |
|---|---|---|---|
| Linux command line | 1–13 | **4** | Comfortable. LVM I would need to look up again. |
| Shell scripting | 16–21 | **4** | I write these without thinking now. `set -euo pipefail` is muscle memory. |
| Git & GitHub | 22–28 | **4** | Rebase and cherry-pick are fine. Recovering a bad rebase, less so. |
| Docker | 29–37 | **4** | Solid. Multi-stage and layer caching finally make sense. |
| CI/CD (Actions) | 38–49 | **4** | The strongest block. 31 workflows, and I debugged real YAML failures. |
| Kubernetes | 50–60 | **3** | I can deploy and debug. Networking internals and RBAC edges, no. |
| Terraform | 61–67 | **3** | Modules and workspaces fine. State recovery I have only read about. |
| Ansible | 68–72 | **3** | Playbooks and roles yes. I have not run it against real fleet drift. |
| Observability | 73–77 | **3** | Stack up, dashboards built. PromQL past `rate()` and `histogram_quantile()` is shaky. |
| Helm | 78–80 | **3** | I can write a chart. Template debugging still costs me time. |
| Amazon EKS | 81–83 | **2** | Honest 2. It worked, then I tore it down. Two weeks does not make this a 3. |
| ArgoCD / GitOps | 84–86 | **3** | The model clicked hard. Operating it through a real incident, not yet. |
| Agentic AI | 87–89 | **2** | Three days. I understand the pattern; I have not run one anywhere real. |

**The two 2s are correct and I am not going to inflate them.** EKS and agents are the newest and the least practised, and both were mostly local or short-lived. The README says redo anything under 3 — those two are the ones, and the difference between them is that EKS costs money to practise and agents do not.

**Where I am genuinely useful right now:** Linux, shell, Git, Docker and GitHub Actions. That is a real CI/CD engineer's toolkit, and it is the half I would put on a CV without hedging.

---

## Top 5 aha moments

**1. Valid YAML can mean the wrong thing, and that is worse than an error.** Day 38. Then it happened for real — devboard's `frontend-deployment.yml` had `resources:` indented at pod level instead of container level. Parses fine. `kubectl apply --dry-run=server` rejects it, and if it had gone through, the pods would have been BestEffort QoS and first to be evicted. **`--dry-run=client` would not have caught it.** A parser telling you a file is fine is not the same as it being right.

**2. CI does not need cluster credentials.** Day 86. Every pipeline I had written before that held a kubeconfig with broad rights in a CI secret. After the switch, `gh secret list` is a Docker token and a repo PAT. The pipeline's entire output is a git commit. **One command shows the whole security argument for GitOps**, and I did not really believe it until I saw the list.

**3. Two controllers will fight over one field, silently and forever.** Day 84. The HPA owns `spec.replicas`; git also declares it. ArgoCD reports OutOfSync permanently and with `selfHeal` on it reverts the HPA every few seconds. The fix is three lines of `ignoreDifferences`. **The lesson is bigger than ArgoCD:** whenever two systems can write the same field, decide which one owns it, in writing.

**4. Guardrails go in the code, not in the prompt.** Day 87. I could tell an agent "never restart the database" and it would usually listen. `if name not in RESTARTABLE` listens every time. Then Day 89 took it further — the model's diagnosis is validated against an action allowlist and a regex before it touches anything, because **an LLM's output is untrusted input.** Same instinct as never interpolating a user string into a shell command, which is Day 17.

**5. Almost every bug is at a boundary.** Day 82 taught it hardest. Also: cert-manager checks for the Gateway API CRDs only at *startup*, so boot it first and every certificate sits Pending forever with nothing in the logs saying why. Nothing is wrong with cert-manager. Nothing is wrong with Envoy Gateway. **The order they start in is the bug.**

---

## The hardest day

**Day 82 — EKS networking and storage.**

A Gateway with no address. `kubectl get gateway` showed it created and healthy, the controller logs said nothing useful, and AWS had no load balancer. Nothing was in an error state. Nothing was in *any* state.

It was a missing subnet tag. The AWS Load Balancer Controller finds subnets by tag, and without `kubernetes.io/role/elb` it finds none — so it does not fail, it just never provisions. **A silent no-op, which is the worst failure mode there is**, because there is nothing to search for.

What got me through was giving up on the logs and going back to first principles: the controller has to pick subnets somehow, so how does it pick? That question found it in about ten minutes, after two hours of reading logs that were never going to say anything.

**What I took from it:** when a component does nothing at all rather than failing, stop reading logs and start asking how it discovers what it acts on. Silence usually means a discovery step found zero of something.

Honourable mentions: **Day 13 (LVM)** was the hardest of the early ones — nothing before it required holding four abstractions at once. **Day 20 (the log analyzer)** was the first day I wrote something over 100 lines that had to actually work.

---

## Task 4: What comes next

**Three months, not a list of thirty things.**

**First — the two 2s.**
- **EKS.** The gap is that I tore it down and never operated it. Fix: keep a small cluster up for two weeks and break things on purpose. A node drain, a full PVC, an expired certificate.
- **Agents.** Cheap to practise, so no excuse. The specific thing I want: an agent that opens a **pull request** instead of patching, because Day 89 proved a cluster-side patch loses to `selfHeal` anyway. The PR is the audit trail, the review is the approval gate, and Day 86's pipeline deploys it.

**Second — the gap I found rather than the ones the syllabus listed.** KubeHealer only reads pod state. Every problem it can diagnose is one `kubectl get pods` already shows. The failures that actually page you — p99 latency creeping, a queue backing up, an error rate at 2% — live in Prometheus, and nothing I built queries it. **A `promql_query` tool wiring Day 76's data into Day 89's diagnosis loop** is the most useful thing I could build next, and it is mine, not off a list.

**Third — the missing production pieces**, in order of how much they would bother me on call:
- **Progressive delivery.** A rolling update is not a canary. Argo Rollouts, so a metrics regression rolls itself back — which is where the observability block finally becomes part of the deploy decision instead of a dashboard.
- **Policy at admission.** Nothing currently stops a privileged container. Kyverno.
- **Database migrations.** The one genuinely imperative step, and GitOps has no clean answer for it.

**Certification: CKA, and only CKA.** Kubernetes is where I sit at 3 and use daily. It is hands-on, so I cannot pass it by reading. AWS SAA and Terraform Associate can wait — collecting certificates for things I do not use yet is not a plan.

**The portfolio project is already done.** devboard is on GitHub with the Terraform, the chart, the workflows and the ArgoCD apps. What is missing is the write-up. **That is worth more than the next tool** — nobody can tell from a repo that I know why `ignoreDifferences` is there.

---

## Advice for whoever starts tomorrow

**Pick one project and stay with it from day 29.** The single best decision I made was pointing every block at devboard instead of the sample app. It means you cannot copy-paste past something you do not understand, and by Day 80 you are extending work you already know rather than starting fresh.

**Type the commands. All of them.** Reading `kubectl describe` output is not the same skill as reading it at 11pm when something is broken. The days where I copied and moved on are exactly the topics I rated 2 and 3.

**Write down what broke, not what worked.** My notes are useful because they say "this parsed fine and was still wrong" and "the load balancer never appeared and nothing logged an error". Six months from now, the working config will be in git. The traps will not be anywhere unless you wrote them down.

**Two days in one is fine. Zero days is not.** I doubled up plenty — 90 days of tasks in 78 calendar days. Skipping entirely is where people stop, because the gap grows faster than the guilt.

**Do not fake your skills inventory.** I put EKS at 2 after three days of it working perfectly, because working once is not the same as knowing it. An honest 2 tells you where to go next. An inflated 4 tells you nothing and eventually gets found out in an interview.

**And you will be slower than the schedule.** Day 82 took me an afternoon of staring at a Gateway that would not get an address. That afternoon taught me more than three smooth days did. **The days where nothing works are the ones doing the work.**

---

## Where I actually ended up

**The tools will change.** Half of what I learned will look different in three years, and Days 87–89 barely existed as a topic when this challenge was first written.

**The patterns will not.** Declare state instead of mutating it. Package once, configure per environment. Make one place the source of truth and make everything else reconcile to it. Instrument before you need to. Put the guardrail in code, never in a request.

**And the actual outcome is smaller and more useful than a tool list:** I can now sit in front of something broken that I have never seen before and work out where to look. Ninety days ago I could not. That is the whole thing.

90 days. 93 markdown files, 31 workflow files, 28 Kubernetes manifests, 35 Ansible files, 22 shell scripts, a Helm chart and an EKS cluster I built and tore down.

On to the next thing.
