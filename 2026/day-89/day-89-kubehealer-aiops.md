# Day 89 – Production AI Agents: KubeHealer and AIOps

Broken apps in `chaos/`. KubeHealer itself lives in its own repo (`TrainWithShubham/kubehealer`) — this is what I ran and what I found reading it.

Days 87 and 88 built agents that **look**. Today's one **acts**, which changes every question about it.

---

## Task 1: AIOps and the guardrails

**AIOps is using AI for operations work — watching, diagnosing, remediating.** The useful framing is not "AI replaces the on-call engineer" but "AI handles the boring 80% and knows when to wake someone up". An image typo does not need a human. A missing ConfigMap does.

### The six guardrails

| Guardrail | Why | In KubeHealer |
|---|---|---|
| Human approval | Nothing destructive without a yes | `wait_condition(self._all_decided)` — the workflow blocks on a signal |
| Scope limits | Only where it is allowed | `HealerInput.namespace`, one namespace per run |
| Audit trail | Every action recorded | Temporal history: every activity, input and output |
| Reversible fixes | Patches, not replacements | `patch_namespaced_deployment`, so the old ReplicaSet stays for rollback |
| Timeouts and retries | No infinite loops | `start_to_close_timeout=30s`, `RetryPolicy(maximum_attempts=3)` |
| Escalation | Know your limits | `action: "skip"` when the fix needs a human decision |

**The one I did not expect, and the best thing in the codebase**, is a seventh: *validate the model's output before executing it*.

```python
VALID_ACTIONS = {"restart_pod", "fix_image", "patch_resources", "skip"}
MEMORY_PATTERN = re.compile(r"^\d+[EPTGMK]i?$")
IMAGE_PATTERN  = re.compile(r"^[a-zA-Z0-9][a-zA-Z0-9_./:@-]+$")

def _validate_fix(diagnosis: Diagnosis) -> str | None:
    if diagnosis.action not in VALID_ACTIONS:
        return f"Invalid action '{diagnosis.action}'..."
    if diagnosis.action == "fix_image":
        if not IMAGE_PATTERN.match(diagnosis.fix_details.get("image", "")):
            return f"Image '{image}' contains invalid characters"
    ...
```

**The model's output is untrusted input.** It is a string from a probabilistic system, going into a call that changes a running cluster. The action has to be one of four known verbs; a memory value has to look like `128Mi`; an image name cannot contain a space or a shell metacharacter. That is input validation, and it is the same instinct as never interpolating a user string into a shell command.

It runs in two places — once when parsing Claude's JSON, and again in `execute_fix` immediately before the patch. Belt and braces on the only step that writes.

### Why Temporal

The failure that matters: the agent patches `web-app`, then the process dies before it records that it did. Restart it and it re-diagnoses from scratch — a second Claude call, a second patch, and no idea the first one happened.

**Temporal records every completed activity in a durable event history.** On restart, the workflow code is replayed from the top, and each activity call it reaches returns the recorded result instead of executing again. The code does not know it crashed.

The important nuance: **replay does not re-run the activity.** Claude is not called twice. The patch is not applied twice. That is the difference between durable execution and "just retry it".

Which is also why activities have to be the only place with side effects. Anything non-deterministic inside the workflow function — a clock read, a random value, an HTTP call — produces a different path on replay and Temporal aborts with a non-determinism error. `cli.py` has explicit handling for exactly that, which tells you it happens in practice.

### When not to use an agent

| Agent | Plain automation |
|---|---|
| Cause is unknown, needs reasoning | Cause is known, fix is fixed |
| Several possible causes | One cause, one fix |
| A human reads the output | Nothing human in the loop |
| Root cause analysis, triage | Scaling, restarts, deploys |

**Day 58's HPA is not an agent and should not be.** "CPU above 70% → add a replica" is a rule. Putting an LLM in that path adds latency, cost and non-determinism to a decision that has one correct answer. The same is true for ArgoCD's self-heal from Day 86 — drift detection is a diff, not a judgement.

The agent earns its place where the input is unstructured and the answer is not knowable in advance. `kubectl describe` output is unstructured. That is the tell.

---

## Task 2: Setup

```
devops@testvm:~$ git clone https://github.com/TrainWithShubham/kubehealer.git
devops@testvm:~$ cd kubehealer
devops@testvm:~/kubehealer$ cat requirements.txt
temporalio>=1.9.0
anthropic>=0.42.0
kubernetes>=31.0.0
python-dotenv>=1.0.0
```

**Four dependencies, and no LangChain.** Straight to the Anthropic SDK, the official Kubernetes client instead of shelling out to `kubectl`, and Temporal for the durability. That is a deliberately smaller surface than Days 87–88.

```
devops@testvm:~/kubehealer$ ./setup.sh

╔═══════════════════════════════════════╗
║     KubeHealer Demo — Cluster Setup   ║
╚═══════════════════════════════════════╝

  [OK] kind
  [OK] kubectl
  [OK] docker

  Creating Kind cluster 'kubehealer'...
  [OK] Cluster created
```

Terminal 2:

```
devops@testvm:~$ temporal server start-dev
CLI 1.1.1 (Server 1.25.2, UI 2.31.2)
Server:  localhost:7233
UI:      http://localhost:8233
```

Terminal 3:

```
devops@testvm:~/kubehealer$ cp .env.example .env    # ANTHROPIC_API_KEY=...
devops@testvm:~/kubehealer$ source .venv/bin/activate
(.venv) devops@testvm:~/kubehealer$ python3 worker.py

  [OK] Anthropic API key
  [OK] Kubernetes cluster

  KubeHealer worker started. Waiting for tasks...
```

`worker.py` runs its own pre-flight before importing anything — key present, cluster reachable — and exits 1 with a readable message if not. Failing fast at startup rather than three activities into a workflow is the same instinct as Day 19's health checks.

**`.env` is gitignored and only `.env.example` is committed**, holding `sk-ant-your-key-here`. Same rule I have followed since Day 44.

---

## Task 3: Three broken apps

`chaos/` in this folder. **Deployments, not bare Pods**, and that is not cosmetic — see below.

```
devops@testvm:~/day-89$ kubectl apply -f chaos/
deployment.apps/web-app created
deployment.apps/config-app created
deployment.apps/memory-app created

devops@testvm:~/day-89$ kubectl get pods
NAME                          READY   STATUS                       RESTARTS      AGE
config-app-7f4d8b9c6d-x2pql   0/1     CreateContainerConfigError   0             45s
memory-app-6b9f7c8d5e-k4nvz   0/1     CrashLoopBackOff             3 (18s ago)   45s
web-app-5c8d94b7f6-h9wmt      0/1     ImagePullBackOff             0             45s
```

| App | Break | Symptom | Fixable? |
|---|---|---|---|
| `web-app` | `nginx:latestt` (double t) | ImagePullBackOff | yes — one character |
| `memory-app` | `stress --vm-bytes 100M` under a `10Mi` limit | OOMKilled → CrashLoopBackOff | yes — raise the limit |
| `config-app` | `envFrom` a ConfigMap that does not exist | CreateContainerConfigError | **no** |

**Why the third one is the interesting one.** The agent can diagnose it perfectly — the ConfigMap `app-config` is missing. But it cannot fix it, because it has no idea what keys belong in it. Creating an empty ConfigMap would make the pod start and the app misbehave in a way that is much harder to find than a pod that will not start. **Failing loudly beats starting wrong**, and knowing that is a property of the design, not of the model.

### Pod vs Deployment

The day's instructions say to apply bare `kind: Pod` manifests. I used Deployments, because the fix path does not work otherwise:

```python
deployment_name = _get_deployment_name(pod_name, namespace)
deployment = apps_v1.read_namespaced_deployment(name=deployment_name, namespace=namespace)
```

`_get_deployment_name` walks `ownerReferences`: Pod → ReplicaSet → Deployment. A bare pod has no owner, so it falls through to the string heuristic, returns the pod's own name, and `read_namespaced_deployment` raises 404.

And even without that, **a Pod's `spec.containers[].image` is immutable** — there is nothing to patch. The whole `fix_image` action only means anything against a controller. KubeHealer's own `chaos/` directory is Deployments, so the code and the repo agree; only the instructions differ.

The ownerReference walk is also just the correct way to do it. Splitting `web-app-5c8d94b7f6-h9wmt` on dashes and dropping the last two segments happens to work here, and breaks the moment a deployment name contains something that looks like a hash. The code does it properly and keeps the split as a logged fallback.

---

## Task 4: Running it

```
(.venv) devops@testvm:~/kubehealer$ python3 starter.py
🚀 Starting KubeHealer workflow (id=kubehealer-1755855218)...
   Namespace: default
```

Worker side:

```
INFO  Scanning namespace 'default' for unhealthy pods
INFO  Found 3 unhealthy pod(s)
INFO    web-app-5c8d94b7f6-h9wmt: ImagePullBackOff — Back-off pulling image "nginx:latestt"
INFO    memory-app-6b9f7c8d5e-k4nvz: OOMKilled — Container was killed due to out-of-memory
INFO    config-app-7f4d8b9c6d-x2pql: CreateContainerConfigError — configmap "app-config" not found
INFO  Diagnosing: web-app-5c8d94b7f6-h9wmt (ImagePullBackOff)
INFO  Asking Claude to diagnose pod
INFO  Collected 34 lines of diagnostic info
INFO  Diagnosis: [HIGH] Image tag typo: nginx:latestt does not exist
INFO  Action: fix_image — The image tag has an extra 't'; nginx:latest is correct
INFO  Diagnosing: memory-app-6b9f7c8d5e-k4nvz (OOMKilled)
INFO  Diagnosis: [HIGH] Memory limit of 10Mi is far below what the process needs
INFO  Action: patch_resources — stress allocates 100M but the limit is 10Mi
INFO  Diagnosing: config-app-7f4d8b9c6d-x2pql (CreateContainerConfigError)
INFO  Diagnosis: [MEDIUM] Referenced ConfigMap 'app-config' does not exist
INFO  Action: skip — Creating the ConfigMap requires knowing its contents
INFO  Fixing web-app-5c8d94b7f6-h9wmt: fix_image
INFO  Patched deployment 'web-app' image to 'nginx:latest'
INFO  Fixing memory-app-6b9f7c8d5e-k4nvz: patch_resources
INFO  Patched deployment 'memory-app' memory limit to '256Mi'
INFO  Skipping config-app-7f4d8b9c6d-x2pql: Creating the ConfigMap requires knowing its contents
```

```
Healed 2/3 pods:

  [+] web-app-5c8d94b7f6-h9wmt: fix_image -- Patched image to nginx:latest
  [+] memory-app-6b9f7c8d5e-k4nvz: patch_resources -- Patched memory limit to 256Mi
  [-] config-app-7f4d8b9c6d-x2pql: skipped -- Creating the ConfigMap requires knowing its contents

📊 View workflow trace: http://localhost:8233/namespaces/default/workflows/kubehealer-1755855218
```

```
devops@testvm:~$ kubectl get pods
NAME                          READY   STATUS                       RESTARTS   AGE
config-app-7f4d8b9c6d-x2pql   0/1     CreateContainerConfigError   0          6m
memory-app-7d5c8f9a4b-t8jrq   1/1     Running                      0          52s
web-app-6f9c7d5b8a-m3kwx      1/1     Running                      0          71s
```

**Two fixed, one correctly refused.** New pod hashes on the two that were patched, because patching a Deployment rolls a new ReplicaSet — which is the reversible part of the guardrail table. `kubectl rollout undo` puts either of them back.

### The approval gate

`starter.py` passes `auto_approve=True`, so that run applied fixes without asking. The interactive path is `cli.py`, which drives the conversational workflow and holds:

```python
self._phase = "awaiting_approval"
await workflow.wait_condition(self._all_decided)
```

```
you> heal the cluster

  I found 3 unhealthy pods.

  1. web-app        HIGH    Image tag typo (nginx:latestt -> nginx:latest)
                            fix_image
  2. memory-app     HIGH    Memory limit 10Mi, process needs ~100M
                            patch_resources -> 256Mi
  3. config-app     MEDIUM  ConfigMap 'app-config' missing
                            skip - I cannot know what belongs in it

  Approve 1 and 2? [yes/no]:
```

**`wait_condition` is a Temporal wait, not a Python one.** The workflow suspends and the worker is free; the state is in Temporal, not in the process. It can sit there for a day and survive a worker restart. In production the resume signal is a Slack button or a PagerDuty ack rather than a terminal prompt — and that only works because the wait is durable.

One thing I would change: `HealerInput.auto_approve` defaults to `True`. **For something that patches a live cluster, the safe default is off**, and `starter.py` passing it explicitly makes that easy to miss.

### The prompt

Reading `llm_activities.py`, the system prompt is more constrained than I expected:

```
Respond ONLY with valid JSON, no markdown, no explanation outside the JSON:
{ "pod_name": ..., "root_cause": ..., "severity": ...,
  "action": "one of: restart_pod, fix_image, patch_resources, skip", ... }
```

**The model is not asked what to do. It is asked to pick from four verbs and fill in a struct.** That is what makes the output validatable at all, and it is the difference between a demo and something you would point at a cluster.

Worth being honest about one line in it though:

```
Common patterns:
- "latestt" is a typo for "latest"
```

The answer to broken-image.yaml is written into the prompt. Fine for a demo that has to work on stage; on a real cluster that hint does not exist and the diagnosis is doing more work. I would not read the `web-app` result as proof of much.

---

## Task 5: Crash recovery

The part I actually wanted to see.

```
devops@testvm:~/day-89$ kubectl delete -f chaos/ && kubectl apply -f chaos/
(.venv) devops@testvm:~/kubehealer$ python3 worker.py &
[1] 48213
(.venv) devops@testvm:~/kubehealer$ python3 starter.py
🚀 Starting KubeHealer workflow (id=kubehealer-1755856044)...
```

Killed mid-diagnosis, after two pods and before the third:

```
INFO  Found 3 unhealthy pod(s)
INFO  Diagnosing: web-app-5c8d94b7f6-h9wmt (ImagePullBackOff)
INFO  Diagnosis: [HIGH] Image tag typo: nginx:latestt does not exist
INFO  Diagnosing: memory-app-6b9f7c8d5e-k4nvz (OOMKilled)
INFO  Diagnosis: [HIGH] Memory limit of 10Mi is far below what the process needs
INFO  Diagnosing: config-app-7f4d8b9c6d-x2pql (CreateContainerConfigError)

(.venv) devops@testvm:~/kubehealer$ kill %1
[1]+  Terminated              python3 worker.py
```

The workflow is not dead — it is unassigned. Temporal has the history; there is just no worker to poll the queue.

```
(.venv) devops@testvm:~/kubehealer$ python3 worker.py

  [OK] Anthropic API key
  [OK] Kubernetes cluster

  KubeHealer worker started. Waiting for tasks...
INFO  Diagnosing: config-app-7f4d8b9c6d-x2pql (CreateContainerConfigError)
INFO  Asking Claude to diagnose pod
INFO  Diagnosis: [MEDIUM] Referenced ConfigMap 'app-config' does not exist
INFO  Fixing web-app-5c8d94b7f6-h9wmt: fix_image
INFO  Patched deployment 'web-app' image to 'nginx:latest'
...
Healed 2/3 pods
```

**It resumed at pod three.** Note what is *not* in that output: no "Scanning namespace", no re-diagnosis of `web-app` or `memory-app`. Two completed Claude calls were replayed from history, not re-issued. Two API calls saved, and — much more to the point — no chance of the fix phase applying a patch twice.

Temporal UI at `:8233`, on the workflow's Event History:

```
  1   WorkflowExecutionStarted
  5   ActivityTaskScheduled       scan_cluster
  7   ActivityTaskCompleted       3 PodIssue results
  9   ActivityTaskScheduled       get_pod_details    web-app
 11   ActivityTaskCompleted
 13   ActivityTaskScheduled       diagnose_pod
 15   ActivityTaskCompleted       action=fix_image
 ...
 27   ActivityTaskScheduled       diagnose_pod       config-app
 29   ActivityTaskTimedOut        START_TO_CLOSE            <- the kill
 31   WorkflowTaskScheduled                                 <- new worker
 33   ActivityTaskStarted         diagnose_pod (attempt 2)
```

**Every activity, with its input and output, and the crash sitting in the middle of it.** The audit trail is not something anyone had to implement — it is a side effect of how the engine works. For a system that modifies infrastructure, "what did it do, in what order, with what input" answered for free is worth as much as the recovery.

---

## Task 6: The three days

| Day | Built | Pattern | Can it change anything? |
|---|---|---|---|
| 87 | Error explainer, Docker agent | one LLM call → ReAct | no (one guarded restart) |
| 88 | Multi-tool agent, MCP server, CI analyzer | multi-domain, tools as a service | no |
| 89 | KubeHealer | durable execution, approval, validation | **yes** |

```
Day 87   LLM explains what an error means            passive
   |
Day 88   agent investigates across 3 domains         autonomous investigation
   |
Day 89   agent investigates, proposes, and patches   autonomous action
```

**Everything gets harder at the last arrow.** Days 87 and 88 were fun and the worst case was a wrong answer. Day 89's worst case is a patched Deployment. That is why the day is mostly guardrails, output validation and durability, and only incidentally about the model.

Six principles, in the order they actually mattered:

1. **Tools are CLI wrappers.** Nothing clever. Eight lines each.
2. **The ReAct loop is domain-agnostic.** Docker, Kubernetes, CI — same code shape.
3. **MCP makes tools a service.** Write once, any client uses them.
4. **The model's output is untrusted input.** Allowlist the actions, regex the values, validate before executing.
5. **Durability is required once the agent writes.** A crash mid-fix without it means unknown state.
6. **Know when not to.** If the answer is knowable in advance, write an `if`.

### Where it plugs into the rest

| Days | How today connects |
|---|---|
| 29–37 Docker | Day 87's tools wrap the same commands, unchanged |
| 38–49 Actions | Day 88's analyzer diagnoses the pipelines I wrote |
| 50–60 Kubernetes | Reading `describe` output is the entire diagnosis step |
| 61–67 Terraform | An agent reading `terraform plan` is the obvious next tool |
| 73–77 Observability | The real gap — KubeHealer reads events, not metrics |
| 84–86 ArgoCD | And the real conflict — see below |

**The observability gap.** KubeHealer only sees pod state. Every problem it can find is one `kubectl get pods` already shows. The failures that actually hurt — p99 latency creeping, a queue backing up, an error rate at 2% — are in Prometheus, and nothing here queries it. A `promql_query` tool feeding Day 76's Grafana data into the same diagnosis loop is the version of this I would actually want on call.

**The GitOps conflict, which is not hypothetical.** Day 86's ArgoCD has `selfHeal: true`. KubeHealer patches a Deployment in the cluster. ArgoCD sees a live state that differs from git and reverts it, probably within seconds. **The agent's fix loses.**

And it should. Git is the source of truth — that was the whole argument of Day 84. A cluster-side patch is exactly the drift `drift-test.sh` proves gets reverted.

So the correct shape for an agent under GitOps is not `kubectl patch`. It is **open a pull request**: the agent diagnoses, proposes a one-line change to `helm/devboard/values.yaml`, and a human merges it. The audit trail is the PR, the approval gate is the review, the rollback is a revert, and Day 86's pipeline deploys it. All four guardrails already exist and I do not have to build any of them.

**That is the thing I take from this block.** The interesting question is not what the agent can do — it is where in an existing pipeline it is allowed to act. Under GitOps, the answer is: at the pull request, like everyone else.

---

## Cleanup

```
devops@testvm:~$ kind delete cluster --name kubehealer
Deleting cluster "kubehealer" ...
devops@testvm:~$ # ctrl-c the temporal server
devops@testvm:~$ deactivate
```

Nothing cloud-side today — Kind is local, and Day 83's teardown already emptied AWS. The only running cost was the Anthropic key, about 15 Claude calls across all the runs.

---

## Files in this folder

| Path | What it is |
|---|---|
| `chaos/broken-image.yaml` | `nginx:latestt` → ImagePullBackOff, auto-fixable |
| `chaos/oom.yaml` | 100M of stress under a 10Mi limit → OOMKilled, auto-fixable |
| `chaos/missing-config.yaml` | Missing ConfigMap → the one that must be escalated |

---

## What I learned

**1. The model's output is untrusted input, and this is the whole game.** `_validate_fix` allowlists the action to four verbs, regexes the memory value against `^\d+[EPTGMK]i?$`, and checks the image name for shell metacharacters — all before anything touches the cluster. A diagnosis is a string from a probabilistic system going into a call that changes production. Treating it like a form field from the internet is the correct instinct, and it is what separates this from Days 87–88.

**2. Temporal replays completed activities instead of re-running them.** I killed the worker mid-diagnosis and the restart resumed at pod three — no re-scan, no repeated Claude calls, no chance of applying the same patch twice. "Just retry the script" would have re-diagnosed everything and re-patched what was already fixed. For an agent that writes to infrastructure, that distinction is the reason durability is not optional.

**3. Under GitOps, an agent should open a pull request, not patch the cluster.** Day 86's `selfHeal: true` would revert every fix KubeHealer applies, within seconds — and correctly, because git is the source of truth. The right integration is a one-line PR against `values.yaml`: the review is the approval gate, the PR is the audit trail, a revert is the rollback, and the existing pipeline deploys it. All four guardrails come for free from a pipeline I already built.

**Two extras:**

- The chaos manifests have to be Deployments. `fix_image` patches `spec.template.spec.containers[].image` on a Deployment reached by walking ownerReferences from the pod; a bare Pod has no owner and its image field is immutable anyway. The day's instructions say Pods, KubeHealer's own `chaos/` says Deployments, and the code only works with the latter.
- `HealerInput.auto_approve` defaults to `True`. For something that patches a running cluster the safe default is off, and having `starter.py` pass it explicitly makes it easy not to notice.
