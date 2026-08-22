# Day 57 – Resource Requests, Limits and Probes

Manifests in `manifests/` in this folder.

---

## Task 1: Requests and limits

**`manifests/resources.yaml`**

```yaml
spec:
  containers:
    - name: app
      image: nginx:1.25-alpine
      resources:
        requests:
          cpu: 100m
          memory: 64Mi
        limits:
          cpu: 250m
          memory: 128Mi
```

**They do completely different jobs.**

**`requests`** are for the **scheduler**. It sums the requests of all pods on a node and only places a new pod where the remaining capacity fits. Requests are a reservation — the pod is guaranteed this much.

**`limits`** are for the **kubelet and the kernel**, enforced at runtime as cgroup limits. Exactly Day 29's cgroups, exposed as a field.

```
devops@testvm:~/day-57$ kubectl apply -f manifests/resources.yaml
pod/resource-demo created

devops@testvm:~/day-57$ kubectl describe node devops-cluster-worker | grep -A6 "Allocated resources"
Allocated resources:
  Resource           Requests     Limits
  --------           --------     ------
  cpu                450m (22%)   750m (37%)
  memory             242Mi (6%)   484Mi (12%)
```

The node tracks requests against capacity. **Only requests count for scheduling** — a node can be overcommitted on limits, because most containers do not use their full limit at once.

### CPU and memory behave differently when exceeded

| | CPU | Memory |
|---|---|---|
| Over the limit | **Throttled** — slowed down | **OOMKilled** — container killed |
| Compressible? | Yes | No |

CPU is compressible: the kernel just gives the process fewer time slices. Memory is not — you cannot give a process less memory than it has already allocated, so the only option is to kill it.

**Units worth knowing:**

- `100m` = 100 millicores = 0.1 of a CPU core. `1000m` = `1`.
- `Mi` is mebibytes (1024²), `M` is megabytes (1000²). `128Mi` ≈ 134 MB. Mixing them up gives a limit ~7% smaller than intended.

### QoS classes

```
devops@testvm:~/day-57$ kubectl get pod resource-demo -n devboard-dev -o jsonpath='{.status.qosClass}'
Burstable
```

Kubernetes assigns a class from the requests and limits, and it decides eviction order under node pressure:

| Class | When | Evicted |
|---|---|---|
| **Guaranteed** | requests == limits, for every resource | Last |
| **Burstable** | requests set, limits higher or absent | Second |
| **BestEffort** | nothing set | **First** |

**A pod with no resources set is BestEffort and is killed first** when a node runs out of memory. That is the strongest practical argument for always setting at least requests — DevBoard's `backend-deployment.yml` on the `feat/k8s` branch has none, so those pods are first in the queue to be evicted.

---

## Task 2: OOMKilled

**`manifests/oom-demo.yaml`** — asks for 200M with a 100Mi limit.

```
devops@testvm:~/day-57$ kubectl apply -f manifests/oom-demo.yaml
pod/oom-demo created

devops@testvm:~/day-57$ kubectl get pod oom-demo -n devboard-dev
NAME       READY   STATUS      RESTARTS   AGE
oom-demo   0/1     OOMKilled   0          8s

devops@testvm:~/day-57$ kubectl describe pod oom-demo -n devboard-dev | grep -A5 "Last State"
    Last State:     Terminated
      Reason:       OOMKilled
      Exit Code:    137
      Started:      Sun, 02 Aug 2026 10:14:22 +0000
      Finished:     Sun, 02 Aug 2026 10:14:24 +0000
```

**Exit code 137** — Day 30's table, 128 + 9 = SIGKILL. Same code as `docker kill`, and here the killer is the kernel's OOM killer acting on the cgroup limit.

Two seconds from start to death.

**Diagnosing this in the wild:** a container in `CrashLoopBackOff` with exit code 137 and no useful application log is almost always this. The application did not crash — the kernel killed it mid-execution, so there is no stack trace and often no final log line. `kubectl describe pod` and looking at `Last State` is the only reliable way to see it.

Also worth knowing: with `restartPolicy: Always` in a Deployment, this becomes an endless restart loop, and `kubectl get pods` flickers between `Running` and `OOMKilled` depending on when you look.

---

## Task 3: Pending — requesting too much

**`manifests/pending-demo.yaml`** — requests 50 whole cores.

```
devops@testvm:~/day-57$ kubectl apply -f manifests/pending-demo.yaml
pod/pending-demo created

devops@testvm:~/day-57$ kubectl get pod pending-demo -n devboard-dev
NAME           READY   STATUS    RESTARTS   AGE
pending-demo   0/1     Pending   0          45s

devops@testvm:~/day-57$ kubectl describe pod pending-demo -n devboard-dev | tail -5
Events:
  Type     Reason            Age   From               Message
  ----     ------            ----  ----               -------
  Warning  FailedScheduling  48s   default-scheduler  0/3 nodes are available:
           1 node(s) had untolerated taint {node-role.kubernetes.io/control-plane: },
           2 Insufficient cpu. preemption: 0/3 nodes are available.
```

**Pending forever, not failed.** The scheduler keeps retrying, so it stays Pending indefinitely.

The message is precise: two workers have insufficient CPU, and the control plane is excluded by a **taint**. Taints are how the control plane keeps ordinary workloads off itself; a pod needs a matching toleration to land there.

**`Pending` and `OOMKilled` are opposite failures.** Pending means the *request* is too large to schedule; OOMKilled means the *limit* was too small at runtime. Both come from getting resources wrong, in opposite directions.

Deleted it — a Pending pod does nothing but clutter.

---

## Task 4: Liveness probe

```yaml
livenessProbe:
  httpGet:
    path: /health
    port: 8080
  periodSeconds: 10
  failureThreshold: 3
```

**A failing liveness probe restarts the container.**

Its purpose is narrow: recover from a process that is running but stuck — a deadlock, an exhausted thread pool, an event loop that has wedged. The process is alive so nothing crashes, but it will never serve another request. Only a restart fixes it.

Watching one fail:

```
devops@testvm:~/day-57$ kubectl exec -n devboard-dev deploy/devboard-backend -- kill -STOP 1
devops@testvm:~/day-57$ kubectl get pods -n devboard-dev -l app=devboard-backend -w
NAME                                READY   STATUS    RESTARTS      AGE
devboard-backend-5c8f2a91d4-k7wqz   1/1     Running   0             4m
devboard-backend-5c8f2a91d4-k7wqz   0/1     Running   0             4m32s
devboard-backend-5c8f2a91d4-k7wqz   0/1     Running   1 (2s ago)    4m34s
devboard-backend-5c8f2a91d4-k7wqz   1/1     Running   1             4m41s
```

```
devops@testvm:~/day-57$ kubectl describe pod -n devboard-dev -l app=devboard-backend | grep -A3 Events
Events:
  Warning  Unhealthy  35s (x3 over 55s)  kubelet  Liveness probe failed: Get "http://10.244.1.14:8080/health":
                                                  context deadline exceeded
  Normal   Killed     35s                kubelet  Container devboard-backend failed liveness probe, will be restarted
```

Three consecutive failures at 10-second intervals, then a restart. `RESTARTS` went to 1 and the pod recovered.

**Getting a liveness probe wrong is worse than not having one.** If it hits an endpoint that depends on the database, then a database outage makes every pod fail liveness and restart — turning a recoverable dependency failure into a cluster-wide crash loop that also hammers the recovering database. **A liveness endpoint must check only the process itself**, never its dependencies.

---

## Task 5: Readiness probe

```yaml
readinessProbe:
  httpGet:
    path: /health
    port: 8080
  periodSeconds: 5
  failureThreshold: 2
```

**A failing readiness probe removes the pod from Service endpoints. It does not restart anything.**

```
devops@testvm:~/day-57$ kubectl get endpoints devboard-backend -n devboard-dev
NAME               ENDPOINTS                             AGE
devboard-backend   10.244.1.14:8080,10.244.2.12:8080     8m

# make one pod fail readiness
devops@testvm:~/day-57$ kubectl exec -n devboard-dev devboard-backend-5c8f2a91d4-k7wqz -- \
    sh -c "iptables -A INPUT -p tcp --dport 8080 -j DROP" 2>/dev/null || true

devops@testvm:~/day-57$ kubectl get pods -n devboard-dev -l app=devboard-backend
NAME                                READY   STATUS    RESTARTS   AGE
devboard-backend-5c8f2a91d4-k7wqz   0/1     Running   0          9m
devboard-backend-5c8f2a91d4-p2nvx   1/1     Running   0          9m

devops@testvm:~/day-57$ kubectl get endpoints devboard-backend -n devboard-dev
NAME               ENDPOINTS          AGE
devboard-backend   10.244.2.12:8080   9m
```

**`0/1` but `Running`, and one endpoint instead of two.** The container was not restarted; it was just taken out of rotation. Traffic goes only to the healthy pod.

This is the probe that matters most day to day:

- **During a rolling update** (Day 52), a new pod receives no traffic until readiness passes. That is what makes `maxUnavailable: 0` actually mean zero downtime — without a readiness probe, "available" means "container started", and traffic hits a pod that is still booting.
- **During a transient dependency failure**, a pod can report not-ready, stop receiving traffic, and recover without being killed.

| | Liveness | Readiness |
|---|---|---|
| On failure | Restarts the container | Removes it from Service endpoints |
| Recovers from | Deadlock, wedged process | Slow start, temporary dependency loss |
| Should check | The process only | The process and, cautiously, dependencies |
| Missing it means | Stuck pods stay stuck | Traffic to pods that cannot serve it |

**Readiness may check dependencies; liveness must not.** A backend with no database connection is not *ready* — but restarting it will not conjure a database, so it is still *alive*.

---

## Task 6: Startup probe

```yaml
startupProbe:
  httpGet:
    path: /health
    port: 8080
  failureThreshold: 30
  periodSeconds: 2
```

**A startup probe suppresses the other two until it passes once.** 30 × 2s gives up to 60 seconds to start; liveness and readiness stay quiet during that window.

It exists to resolve a real conflict. A slow-starting application — a JVM, something running migrations — might need 60 seconds. Without a startup probe you have two bad options:

- **A short liveness period**: the app is killed at 30 seconds, restarts, is killed again. A permanent crash loop for an application that would have worked.
- **A long `initialDelaySeconds`**: the app starts in 5 seconds but liveness does not begin checking for 60, so a genuine deadlock in the first minute goes unnoticed.

A startup probe gives a generous budget for the first start and a tight one afterwards.

```
devops@testvm:~/day-57$ kubectl describe pod -n devboard-dev -l app=devboard-backend | grep -E "Liveness|Readiness|Startup"
    Liveness:   http-get http://:8080/health delay=0s timeout=1s period=10s #success=1 #failure=3
    Readiness:  http-get http://:8080/health delay=0s timeout=1s period=5s #success=1 #failure=2
    Startup:    http-get http://:8080/health delay=0s timeout=1s period=2s #success=1 #failure=30
```

**Probe types:** `httpGet` (2xx/3xx is healthy), `tcpSocket` (can it be connected to), and `exec` (a command exiting 0). DevBoard's Postgres uses `exec` with `pg_isready`, which is right — there is no HTTP endpoint to hit.

### The bug in DevBoard's own manifest

Worth recording, because it validates cleanly and does the wrong thing.

`frontend-deployment.yml` on the `feat/k8s` branch has:

```yaml
    spec:
      containers:
      - name: devboard-frontend
        image: ...
        ports:
        - containerPort: 4173
      resources:              # <-- 6 spaces: a sibling of `containers`
        requests:
          cpu: 10m
```

`resources` is indented at **pod spec** level, not **container** level. It belongs inside the container, two levels deeper:

```yaml
      containers:
      - name: devboard-frontend
        image: ...
        ports:
        - containerPort: 4173
        resources:            # <-- 8 spaces: a field of the container
          requests:
            cpu: 10m
```

The YAML is valid, which is why nothing catches it locally. `kubectl apply --dry-run=server` does:

```
devops@testvm:~/day-57$ kubectl apply -f frontend-deployment.yml --dry-run=server
error: error validating data: ValidationError(Deployment.spec.template.spec):
unknown field "resources" in io.k8s.api.core.v1.PodSpec
```

Day 51's point exactly — client dry-run checks the YAML, server dry-run checks the schema. And Day 38's point: a YAML mistake that parses is worse than one that errors, because the file *looks* right and the resources are silently absent, leaving the pod BestEffort and first to be evicted.

`manifests/probes.yaml` in this folder has it at the correct level, with a comment.

---

## Task 7: Cleanup

```
devops@testvm:~/day-57$ kubectl delete -f manifests/ --ignore-not-found
pod "oom-demo" deleted
pod "pending-demo" deleted
pod "resource-demo" deleted
deployment.apps "devboard-backend" deleted
```

---

## Files in this folder

| Path | What it demonstrates |
|---|---|
| `manifests/resources.yaml` | Requests and limits, correctly placed |
| `manifests/oom-demo.yaml` | Exceeds its memory limit → OOMKilled, exit 137 |
| `manifests/pending-demo.yaml` | Requests 50 cores → Pending forever |
| `manifests/probes.yaml` | Startup, liveness and readiness on the DevBoard backend |

---

## What I learned

**1. Liveness restarts, readiness removes from load balancing.** They look similar and behave completely differently. The important corollary: **a liveness probe must never check a dependency**, or a database outage turns into every pod restarting in a loop and making recovery harder.

**2. Requests and limits fail in opposite directions.** Too large a request means `Pending` forever — the scheduler cannot place it. Too small a limit means `OOMKilled` at runtime. Both are resource mistakes, and the symptoms look nothing alike.

**3. A pod with no resources set is BestEffort and is evicted first.** That is the practical reason to set at least requests on everything, even a small frontend.

**Two extras:**

- Exit code 137 with no application log is almost always OOMKilled. `kubectl describe pod` and read `Last State` — the process was killed mid-execution, so there is no stack trace to find.
- Indentation puts `resources` on the pod spec instead of the container, the YAML still parses, and the limits silently do not exist. `--dry-run=server` catches it; nothing else does.
