# Day 51 – Kubernetes Manifests and Your First Pods

Three manifests in `manifests/` in this folder.

---

## Task 1: First pod

**`manifests/nginx-pod.yaml`**

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: nginx-pod
  namespace: default
  labels:
    app: nginx
    tier: frontend
spec:
  containers:
    - name: nginx
      image: nginx:1.25-alpine
      ports:
        - containerPort: 80
```

```
devops@testvm:~/day-51$ kubectl apply -f manifests/nginx-pod.yaml
pod/nginx-pod created

devops@testvm:~/day-51$ kubectl get pods
NAME        READY   STATUS    RESTARTS   AGE
nginx-pod   1/1     Running   0          12s

devops@testvm:~/day-51$ kubectl get pod nginx-pod -o wide
NAME        READY   STATUS    RESTARTS   AGE   IP           NODE                    NOMINATED NODE
nginx-pod   1/1     Running   0          31s   10.244.1.3   devops-cluster-worker   <none>
```

**`READY 1/1`** is containers ready out of containers in the pod, not pods. A pod with two containers shows `2/2`.

The scheduler put it on `devops-cluster-worker`, and it has a cluster-internal IP of `10.244.1.3`.

`containerPort: 80` is documentation only, exactly like Docker's `EXPOSE` from Day 31 — it publishes nothing. The pod IP is reachable from inside the cluster regardless, and reaching it from outside needs a Service.

---

## Task 2: A custom pod

**`manifests/busybox-pod.yaml`**

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: busybox-pod
  labels:
    app: busybox
    tier: tools
spec:
  containers:
    - name: busybox
      image: busybox:1.36
      command: ["sh", "-c", "while true; do echo alive at $(date); sleep 30; done"]
  restartPolicy: Always
```

**The `command` is not optional here**, and this is the mistake worth making once. My first version had no command:

```
devops@testvm:~/day-51$ kubectl get pods
NAME          READY   STATUS             RESTARTS      AGE
busybox-pod   0/1     CrashLoopBackOff   3 (22s ago)   72s
```

`busybox` with no arguments runs `sh`, which finds no input, exits immediately with code 0, and the pod restarts it forever. Same lesson as Day 30's `daemon off;` — **a container stops when PID 1 exits**, and Kubernetes wraps that in a restart loop.

The exponential backoff is visible in the RESTARTS column: 10s, 20s, 40s, up to 5 minutes.

With the command:

```
devops@testvm:~/day-51$ kubectl apply -f manifests/busybox-pod.yaml
devops@testvm:~/day-51$ kubectl logs busybox-pod
alive at Tue Jul 28 09:22:14 UTC 2026
alive at Tue Jul 28 09:22:44 UTC 2026

devops@testvm:~/day-51$ kubectl exec -it busybox-pod -- sh
/ # wget -qO- http://10.244.1.3
<!DOCTYPE html>
<html><head><title>Welcome to nginx!</title></head>
/ # exit
```

**Pod-to-pod networking works with no configuration.** Every pod gets a routable IP in the cluster and any pod can reach any other. That is a core Kubernetes guarantee, and it is why there is no Docker-style `--network` flag — the flat network already exists.

The third manifest, `devboard-frontend-pod.yaml`, runs my own image the same way:

```
devops@testvm:~/day-51$ kubectl apply -f manifests/devboard-frontend-pod.yaml
devops@testvm:~/day-51$ kubectl get pods -l project=devboard
NAME                READY   STATUS    RESTARTS   AGE
devboard-frontend   1/1     Running   0          38s
```

---

## Task 3: Imperative vs declarative

**Imperative** — tell Kubernetes what to *do*:

```
devops@testvm:~/day-51$ kubectl run test-nginx --image=nginx:1.25-alpine
pod/test-nginx created

devops@testvm:~/day-51$ kubectl delete pod test-nginx
pod "test-nginx" deleted
```

**Declarative** — tell it what you *want*, in a file:

```
devops@testvm:~/day-51$ kubectl apply -f manifests/nginx-pod.yaml
pod/nginx-pod created

devops@testvm:~/day-51$ kubectl apply -f manifests/nginx-pod.yaml
pod/nginx-pod unchanged
```

**`unchanged`, not an error.** `apply` compares desired state to actual state and does nothing if they match. That is idempotency — the Day 17 property, now a first-class feature of the tool.

`create` behaves differently:

```
devops@testvm:~/day-51$ kubectl create -f manifests/nginx-pod.yaml
Error from server (AlreadyExists): pods "nginx-pod" already exists
```

| | Imperative | Declarative |
|---|---|---|
| Commands | `run`, `create`, `expose`, `scale`, `edit` | `apply -f` |
| Source of truth | Whatever is in the cluster | The YAML file |
| Reviewable | No | Yes, it is in git |
| Repeatable | No | Yes |
| Good for | Quick tests, debugging, generating YAML | Everything real |

The genuinely useful trick is using imperative commands to *write* the declarative file:

```
devops@testvm:~/day-51$ kubectl run nginx-pod --image=nginx:1.25-alpine \
    --dry-run=client -o yaml > generated.yaml
```

`--dry-run=client` builds the object without sending it to the cluster. Far faster than typing the boilerplate, and it is how I would produce a Deployment or Service skeleton rather than remembering the exact field names.

---

## Task 4: Validating before applying

```
devops@testvm:~/day-51$ kubectl apply -f manifests/nginx-pod.yaml --dry-run=client
pod/nginx-pod configured (dry run)

devops@testvm:~/day-51$ kubectl apply -f manifests/nginx-pod.yaml --dry-run=server
pod/nginx-pod configured (server dry run)
```

**The two dry-run modes are not the same.**

`--dry-run=client` only checks that the YAML parses and the fields look plausible. It never contacts the cluster.

`--dry-run=server` sends the object to the API server, which runs full validation and admission controllers, then discards it instead of persisting. It catches things the client cannot — an unknown field, a bad `apiVersion`, a resource quota violation, an admission webhook rejection.

Breaking it deliberately:

```
devops@testvm:~/day-51$ sed 's/containerPort/containerPorts/' manifests/nginx-pod.yaml > /tmp/bad.yaml
devops@testvm:~/day-51$ kubectl apply -f /tmp/bad.yaml --dry-run=server
error: error validating "/tmp/bad.yaml": error validating data:
ValidationError(Pod.spec.containers[0].ports[0]): unknown field "containerPorts"
in io.k8s.api.core.v1.ContainerPort
```

Caught, with the exact path. **Server dry-run is what I would put in CI** — it validates against the actual cluster's API version rather than against a schema copy that may be out of date.

`kubectl explain` is the other tool that removes guesswork:

```
devops@testvm:~/day-51$ kubectl explain pod.spec.containers.resources
KIND:       Pod
FIELD:      resources <ResourceRequirements>

DESCRIPTION:
    Compute Resources required by this container.

FIELDS:
  limits    <map[string]Quantity>
  requests  <map[string]Quantity>
```

Faster than the website, and it reflects the version actually running.

---

## Task 5: Labels and filtering

```
devops@testvm:~/day-51$ kubectl get pods --show-labels
NAME                READY   STATUS    AGE   LABELS
busybox-pod         1/1     Running   6m    app=busybox,tier=tools
devboard-frontend   1/1     Running   4m    app=devboard-frontend,project=devboard,tier=frontend
nginx-pod           1/1     Running   9m    app=nginx,tier=frontend
```

```
devops@testvm:~/day-51$ kubectl get pods -l tier=frontend
NAME                READY   STATUS    RESTARTS   AGE
devboard-frontend   1/1     Running   0          4m
nginx-pod           1/1     Running   0          9m

devops@testvm:~/day-51$ kubectl get pods -l 'tier in (frontend,tools)'
NAME                READY   STATUS    RESTARTS   AGE
busybox-pod         1/1     Running   0          6m
devboard-frontend   1/1     Running   0          4m
nginx-pod           1/1     Running   0          9m

devops@testvm:~/day-51$ kubectl get pods -l 'app!=nginx,tier=frontend'
NAME                READY   STATUS    RESTARTS   AGE
devboard-frontend   1/1     Running   0          4m
```

Adding one at runtime:

```
devops@testvm:~/day-51$ kubectl label pod nginx-pod environment=dev
pod/nginx-pod labeled
devops@testvm:~/day-51$ kubectl get pods -l environment=dev
NAME        READY   STATUS    RESTARTS   AGE
nginx-pod   1/1     Running   0          11m
```

**Labels are not decoration — they are the wiring.** A Service finds its pods with a label selector. A Deployment identifies the pods it owns with a label selector. An HPA finds its target the same way. Getting a label wrong does not throw an error; it produces a Service with no endpoints, which is a much harder failure to spot. Day 53 covers that.

**Labels versus annotations:** labels are for *selecting* and are indexed, so keep them short. Annotations hold arbitrary metadata nothing selects on — a build URL, a change-cause, a checksum.

---

## Task 6: Cleanup

```
devops@testvm:~/day-51$ kubectl delete -f manifests/
pod "busybox-pod" deleted
pod "devboard-frontend" deleted
pod "nginx-pod" deleted

devops@testvm:~/day-51$ kubectl get pods
No resources found in default namespace.
```

`kubectl delete -f <directory>` deletes everything defined in it, which is the counterpart to `apply -f <directory>`.

`kubectl delete pods -l tier=frontend` deletes by label instead.

**Deleting a bare Pod deletes it permanently.** Nothing recreates it. That is the whole reason bare Pods are a learning tool rather than a real deployment unit — which is Day 52.

---

## Files in this folder

| Path | What it is |
|---|---|
| `manifests/nginx-pod.yaml` | The minimal pod |
| `manifests/busybox-pod.yaml` | Needs an explicit long-running command |
| `manifests/devboard-frontend-pod.yaml` | My own image from Day 45 |

---

## What I learned

**1. A container that exits kills the pod, and Kubernetes turns that into `CrashLoopBackOff`.** BusyBox with no command exits instantly. Same root cause as Day 30's `daemon off;`, but the symptom is a restart loop with exponential backoff rather than a stopped container.

**2. `apply` is idempotent, `create` is not.** Re-applying an unchanged manifest prints `unchanged`, which is what makes declarative config safe to run repeatedly — from a script, from CI, from anywhere.

**3. Labels are functional, not cosmetic.** Services, Deployments and HPAs all find their targets by label selector. A typo produces something that looks fine and silently matches nothing.

**Two extras:**

- `--dry-run=server` catches unknown fields and admission failures that `--dry-run=client` cannot. Worth having in CI.
- `kubectl run ... --dry-run=client -o yaml` generates the boilerplate, so the imperative commands are most useful as a way to write declarative files.
