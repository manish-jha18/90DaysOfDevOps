# Day 52 – Namespaces and Deployments

Manifests in `manifests/` in this folder.

---

## Task 1: The default namespaces

```
devops@testvm:~/day-52$ kubectl get namespaces
NAME                 STATUS   AGE
default              Active   2d
kube-node-lease      Active   2d
kube-public          Active   2d
kube-system          Active   2d
local-path-storage   Active   2d
```

| Namespace | What it holds |
|---|---|
| `default` | Where your resources land if you do not say otherwise |
| `kube-system` | The control plane — apiserver, etcd, scheduler, CoreDNS, kube-proxy (Day 50) |
| `kube-public` | World-readable, even unauthenticated. Holds cluster info for bootstrapping |
| `kube-node-lease` | One Lease object per node, updated constantly as a heartbeat |
| `local-path-storage` | kind's dynamic storage provisioner. Not standard Kubernetes |

`kube-node-lease` is the interesting one. Node heartbeats used to be status updates on the Node object itself, which meant writing a large object to etcd every few seconds per node. Leases are tiny, so this scales to thousands of nodes. It is the mechanism behind the 40-second NotReady detection from Day 50.

**Not everything is namespaced:**

```
devops@testvm:~/day-52$ kubectl api-resources --namespaced=false | head -8
NAME                              SHORTNAMES   APIVERSION      KIND
componentstatuses                 cs           v1              ComponentStatus
namespaces                        ns           v1              Namespace
nodes                             no           v1              Node
persistentvolumes                 pv           v1              PersistentVolume
storageclasses                    sc           storage.k8s.io/v1  StorageClass
clusterroles                                   rbac.../v1      ClusterRole
```

Nodes, PersistentVolumes and StorageClasses are cluster-scoped — they are physical or cluster-wide things, so scoping them to a namespace would make no sense. **A PV is cluster-scoped but a PVC is namespaced**, which matters on Day 55.

---

## Task 2: Custom namespaces

**`manifests/namespaces.yaml`**

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: devboard-dev
  labels:
    environment: development
---
apiVersion: v1
kind: Namespace
metadata:
  name: devboard-prod
  labels:
    environment: production
```

`---` separates two YAML documents in one file. Convenient for related resources, and `kubectl apply -f` handles it.

```
devops@testvm:~/day-52$ kubectl apply -f manifests/namespaces.yaml
namespace/devboard-dev created
namespace/devboard-prod created

devops@testvm:~/day-52$ kubectl get ns -l environment
NAME            STATUS   AGE   
devboard-dev    Active   8s    
devboard-prod   Active   8s    
```

Three ways to target a namespace:

```
# per command
kubectl get pods -n devboard-dev

# in the manifest - the most reliable, since it cannot be forgotten
metadata:
  namespace: devboard-dev

# change the context default
kubectl config set-context --current --namespace=devboard-dev
```

I set the context default while working on this:

```
devops@testvm:~/day-52$ kubectl config set-context --current --namespace=devboard-dev
Context "kind-devops-cluster" modified.
devops@testvm:~/day-52$ kubectl config view --minify -o jsonpath='{..namespace}'
devboard-dev
```

Convenient and slightly dangerous — a forgotten default is how you delete something in the wrong namespace. Putting `namespace:` in the manifest is the safer habit, because the file is then unambiguous no matter what the context says.

**Namespaces isolate names, not networks.** Two namespaces can each have a Service called `postgres`, and they will not clash. But by default a pod in `devboard-dev` can still reach one in `devboard-prod` over the pod network — real isolation needs NetworkPolicies.

---

## Task 3: The first Deployment

**`manifests/frontend-deployment.yaml`**

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: devboard-frontend
  namespace: devboard-dev
  labels:
    app: devboard-frontend
spec:
  replicas: 3
  selector:
    matchLabels:
      app: devboard-frontend
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 0
  template:
    metadata:
      labels:
        app: devboard-frontend
    spec:
      containers:
        - name: devboard-frontend
          image: manishjha18/devboard-frontend:latest
          ports:
            - containerPort: 4173
```

**`apiVersion: apps/v1`**, not `v1`. Pods and Services are in the core group; Deployments, ReplicaSets, StatefulSets and DaemonSets are in `apps`. Getting this wrong gives `no matches for kind "Deployment" in version "v1"`.

**`selector.matchLabels` must match `template.metadata.labels`.** The selector is how the Deployment finds pods it owns. Kubernetes rejects a mismatch outright:

```
devops@testvm:~/day-52$ kubectl apply -f /tmp/mismatched.yaml
The Deployment "devboard-frontend" is invalid: spec.template.metadata.labels:
Invalid value: map[string]string{"app":"wrong"}: `selector` does not match template `labels`
```

The selector is also **immutable** after creation — changing it means deleting and recreating the Deployment.

```
devops@testvm:~/day-52$ kubectl apply -f manifests/frontend-deployment.yaml
deployment.apps/devboard-frontend created

devops@testvm:~/day-52$ kubectl get deployments
NAME                READY   UP-TO-DATE   AVAILABLE   AGE
devboard-frontend   3/3     3            3           41s

devops@testvm:~/day-52$ kubectl get pods -o wide
NAME                                 READY   STATUS    AGE   NODE
devboard-frontend-7d4f8b9c6d-2xk4p   1/1     Running   45s   devops-cluster-worker
devboard-frontend-7d4f8b9c6d-8mnq7   1/1     Running   45s   devops-cluster-worker2
devboard-frontend-7d4f8b9c6d-vz9lt   1/1     Running   45s   devops-cluster-worker
```

**Three pods spread across two workers.** Pod names are `<deployment>-<replicaset-hash>-<random>`. The middle segment identifies the ReplicaSet, which matters during a rollout.

### The ownership chain

```
devops@testvm:~/day-52$ kubectl get replicasets
NAME                           DESIRED   CURRENT   READY   AGE
devboard-frontend-7d4f8b9c6d   3         3         3       2m
```

```
Deployment  →  ReplicaSet  →  Pods
(rollouts)     (count)        (workload)
```

The Deployment does not manage pods directly. It manages **ReplicaSets**, and a ReplicaSet keeps N pods alive. That indirection is exactly what makes rolling updates possible — a rollout is one ReplicaSet scaling up while another scales down.

```
devops@testvm:~/day-52$ kubectl get pod devboard-frontend-7d4f8b9c6d-2xk4p \
    -o jsonpath='{.metadata.ownerReferences[0].kind}/{.metadata.ownerReferences[0].name}'
ReplicaSet/devboard-frontend-7d4f8b9c6d
```

---

## Task 4: Self-healing

```
devops@testvm:~/day-52$ kubectl delete pod devboard-frontend-7d4f8b9c6d-2xk4p
pod "devboard-frontend-7d4f8b9c6d-2xk4p" deleted

devops@testvm:~/day-52$ kubectl get pods
NAME                                 READY   STATUS    RESTARTS   AGE
devboard-frontend-7d4f8b9c6d-8mnq7   1/1     Running   0          4m
devboard-frontend-7d4f8b9c6d-p6rw2   1/1     Running   0          6s
devboard-frontend-7d4f8b9c6d-vz9lt   1/1     Running   0          4m
```

Still three. A **new** pod, `p6rw2`, six seconds old.

This is the reconcile loop from Day 50, visible. The ReplicaSet controller watches for pods matching its selector, counts two where it wants three, and creates one. Nobody told it to — it is comparing desired state to observed state, continuously.

Watching it live:

```
devops@testvm:~/day-52$ kubectl get pods -w
NAME                                 READY   STATUS              AGE
devboard-frontend-7d4f8b9c6d-8mnq7   1/1     Running             5m
devboard-frontend-7d4f8b9c6d-p6rw2   1/1     Terminating         1m
devboard-frontend-7d4f8b9c6d-k9x3v   0/1     Pending             0s
devboard-frontend-7d4f8b9c6d-k9x3v   0/1     ContainerCreating   0s
devboard-frontend-7d4f8b9c6d-k9x3v   1/1     Running             3s
```

Pending → ContainerCreating → Running in three seconds. Pending is the gap between the API server storing it and the scheduler assigning a node.

**Contrast with Day 51's bare pod:** deleting that one deleted it. Nothing owned it. The difference between a Pod and a Deployment is entirely about whether something is watching.

---

## Task 5: Scaling

```
devops@testvm:~/day-52$ kubectl scale deployment devboard-frontend --replicas=5
deployment.apps/devboard-frontend scaled

devops@testvm:~/day-52$ kubectl get pods
NAME                                 READY   STATUS    RESTARTS   AGE
devboard-frontend-7d4f8b9c6d-8mnq7   1/1     Running   0          8m
devboard-frontend-7d4f8b9c6d-k9x3v   1/1     Running   0          3m
devboard-frontend-7d4f8b9c6d-m2plq   1/1     Running   0          8s
devboard-frontend-7d4f8b9c6d-tw7fx   1/1     Running   0          8s
devboard-frontend-7d4f8b9c6d-vz9lt   1/1     Running   0          8m
```

Two new pods in eight seconds. Compare Day 34, where `docker compose up --scale web=3` failed on a port collision — here each pod has its own IP, so there is nothing to collide.

```
devops@testvm:~/day-52$ kubectl scale deployment devboard-frontend --replicas=2
devops@testvm:~/day-52$ kubectl get deployment devboard-frontend
NAME                READY   UP-TO-DATE   AVAILABLE   AGE
devboard-frontend   2/2     2            2           9m
```

**The imperative/declarative trap:** `kubectl scale` changes the cluster but not the file. Re-applying the manifest snaps it back to 3, silently. In a GitOps setup the file wins and any manual scale is reverted within minutes. The declarative equivalent is editing `replicas:` and applying — and if an HPA owns the replica count (Day 58), neither should be done by hand.

---

## Task 6: Rolling update

```
devops@testvm:~/day-52$ kubectl set image deployment/devboard-frontend \
    devboard-frontend=manishjha18/devboard-frontend:sha-8a3f91c
deployment.apps/devboard-frontend image updated

devops@testvm:~/day-52$ kubectl rollout status deployment/devboard-frontend
Waiting for deployment "devboard-frontend" rollout to finish: 1 out of 3 new replicas have been updated...
Waiting for deployment "devboard-frontend" rollout to finish: 2 out of 3 new replicas have been updated...
Waiting for deployment "devboard-frontend" rollout to finish: 1 old replicas are pending termination...
deployment "devboard-frontend" successfully rolled out
```

Two ReplicaSets during the rollout:

```
devops@testvm:~/day-52$ kubectl get replicasets
NAME                           DESIRED   CURRENT   READY   AGE
devboard-frontend-6b8d9f4c2a   3         3         3       48s
devboard-frontend-7d4f8b9c6d   0         0         0       12m
```

The new one at 3, the old one scaled to 0 but **kept**. That is what makes rollback instant — the old ReplicaSet is still there, just empty.

**`maxSurge: 1` and `maxUnavailable: 0`** are the settings that make this zero-downtime. `maxUnavailable: 0` means never drop below the desired count, so Kubernetes must add a new pod before removing an old one. `maxSurge: 1` caps how far above the count it can go. The default is 25% of each, which does allow a brief dip in capacity.

### Rollback

```
devops@testvm:~/day-52$ kubectl rollout history deployment/devboard-frontend
deployment.apps/devboard-frontend
REVISION  CHANGE-CAUSE
1         <none>
2         <none>

devops@testvm:~/day-52$ kubectl rollout undo deployment/devboard-frontend
deployment.apps/devboard-frontend rolled back

devops@testvm:~/day-52$ kubectl get deployment devboard-frontend \
    -o jsonpath='{.spec.template.spec.containers[0].image}'
manishjha18/devboard-frontend:latest
```

Back to the old image in seconds, because the old ReplicaSet only had to scale back up.

**`CHANGE-CAUSE <none>` is unhelpful**, and fixable with an annotation:

```
devops@testvm:~/day-52$ kubectl annotate deployment/devboard-frontend \
    kubernetes.io/change-cause="Update to sha-8a3f91c" --overwrite
```

### The `:latest` problem

Something worth being explicit about, given Day 45 tags images both ways.

```
devops@testvm:~/day-52$ kubectl set image deployment/devboard-frontend \
    devboard-frontend=manishjha18/devboard-frontend:latest
deployment.apps/devboard-frontend image unchanged
```

**`unchanged`.** Even though a new `:latest` had been pushed. Kubernetes compares the image *string*, and the string did not change — so no rollout happens and the old image keeps running.

This is why deployments should use the immutable `sha-` tag from Day 45, not `latest`. Changing the tag changes the string, which triggers a real rollout and makes it obvious what is deployed. `kubectl rollout restart` forces one, but that is a workaround for a tagging problem.

---

## Task 7: Cleanup

```
devops@testvm:~/day-52$ kubectl delete deployment devboard-frontend -n devboard-dev
deployment.apps "devboard-frontend" deleted

devops@testvm:~/day-52$ kubectl delete ns devboard-prod
namespace "devboard-prod" deleted
```

**Deleting a namespace deletes everything in it** — pods, deployments, services, configmaps, PVCs. Fast and total. It is the neatest cleanup and the easiest catastrophic mistake, which is the argument for `kubectl config current-context` before anything destructive.

Kept `devboard-dev` for the following days.

---

## Files in this folder

| Path | What it is |
|---|---|
| `manifests/namespaces.yaml` | Two namespaces in one multi-document file |
| `manifests/frontend-deployment.yaml` | 3 replicas, zero-downtime rolling update strategy |

---

## What I learned

**1. A Deployment manages ReplicaSets, not pods.** That extra layer is the whole mechanism behind rolling updates and instant rollback — a rollout is one ReplicaSet scaling up while another scales down, and the old one is kept at zero so `rollout undo` only has to scale it back.

**2. Self-healing is a reconcile loop, not a reaction.** Deleting a pod did not trigger an event handler; the controller simply observed two where it wanted three. The same loop handles node failure, scaling and rollouts.

**3. `:latest` breaks deployments silently.** `kubectl set image` with the same tag string reports `unchanged` and nothing rolls out, even though a new image was pushed. Immutable SHA tags from Day 45 are what make a deploy actually deploy.

**Two extras:**

- `maxUnavailable: 0` with `maxSurge: 1` is what makes a rollout genuinely zero-downtime. The defaults allow a brief capacity dip.
- `kubectl scale` diverges from the manifest, and re-applying silently reverts it. Fine for a test, wrong as a habit.
