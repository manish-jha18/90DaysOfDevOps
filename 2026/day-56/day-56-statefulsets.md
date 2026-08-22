# Day 56 – StatefulSets

Manifests in `manifests/` in this folder.

---

## Task 1: The problem

A Deployment treats its pods as **interchangeable**. That is the whole design — any pod can serve any request, so replacing one with another is free.

Databases break every part of that assumption.

```
devops@testvm:~/day-56$ kubectl get pods -n devboard-dev -l app=devboard-frontend
NAME                                 READY   STATUS    AGE
devboard-frontend-7d4f8b9c6d-2xk4p   1/1     Running   3m
devboard-frontend-7d4f8b9c6d-8mnq7   1/1     Running   3m
devboard-frontend-7d4f8b9c6d-vz9lt   1/1     Running   3m
```

**Random names.** Delete one and the replacement has a different name and a different IP.

Three things a database needs that a Deployment cannot give:

**A stable name.** Postgres replication needs a primary at a fixed address. `devboard-frontend-7d4f8b9c6d-2xk4p` becoming `...-k9x3v` on restart makes that impossible.

**Its own storage.** Every pod in a Deployment mounts the **same** PVC. For a stateless app that is fine; for three database replicas it means three processes writing to one volume, which corrupts it. And RWO would not allow it across nodes anyway (Day 55).

**Ordered startup.** A replica cannot initialise before the primary exists. Deployments start everything at once.

A StatefulSet provides all three.

---

## Task 2: The headless Service

**`manifests/headless-service.yaml`**

```yaml
apiVersion: v1
kind: Service
metadata:
  name: postgres
  namespace: devboard-dev
spec:
  clusterIP: None
  selector:
    app: devboard-postgres
  ports:
    - protocol: TCP
      port: 5432
      targetPort: 5432
```

**`clusterIP: None`** is what makes it headless.

```
devops@testvm:~/day-56$ kubectl get svc postgres -n devboard-dev
NAME       TYPE        CLUSTER-IP   EXTERNAL-IP   PORT(S)    AGE
postgres   ClusterIP   None         <none>        5432/TCP   9s
```

`CLUSTER-IP: None`. No virtual IP, no kube-proxy rules, no load balancing.

A normal Service gives one IP that round-robins to a random backend. For a database that is wrong — you need to address a *specific* replica. A headless Service instead returns **all the pod IPs** on a DNS lookup, and gives each pod its own DNS name.

---

## Task 3: The StatefulSet

**`manifests/postgres-statefulset.yaml`**

```yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: postgres
  namespace: devboard-dev
spec:
  serviceName: postgres        # must name the headless service
  replicas: 3
  selector:
    matchLabels:
      app: devboard-postgres
  template:
    metadata:
      labels:
        app: devboard-postgres
    spec:
      terminationGracePeriodSeconds: 10
      containers:
        - name: postgres
          image: postgres:16-alpine
          ports:
            - containerPort: 5432
              name: postgres
          env:
            - name: PGDATA
              value: /var/lib/postgresql/data/pgdata
            # ... POSTGRES_USER / PASSWORD / DB from configmap and secret
          readinessProbe:
            exec:
              command: ["sh", "-c", "pg_isready -U $POSTGRES_USER -d $POSTGRES_DB"]
            initialDelaySeconds: 10
            periodSeconds: 5
          volumeMounts:
            - name: data
              mountPath: /var/lib/postgresql/data
  volumeClaimTemplates:
    - metadata:
        name: data
      spec:
        storageClassName: standard
        accessModes:
          - ReadWriteOnce
        resources:
          requests:
            storage: 1Gi
```

**`volumeClaimTemplates` is the key difference from a Deployment.** It is a template, not a volume — Kubernetes creates **one PVC per pod** from it.

Watching them come up:

```
devops@testvm:~/day-56$ kubectl apply -f manifests/
devops@testvm:~/day-56$ kubectl get pods -n devboard-dev -l app=devboard-postgres -w
NAME         READY   STATUS              AGE
postgres-0   0/1     Pending             0s
postgres-0   0/1     ContainerCreating   2s
postgres-0   1/1     Running             14s
postgres-1   0/1     Pending             0s
postgres-1   0/1     ContainerCreating   1s
postgres-1   1/1     Running             13s
postgres-2   0/1     Pending             0s
postgres-2   1/1     Running             12s
```

**Two things immediately different from a Deployment.**

**Names are ordinal:** `postgres-0`, `postgres-1`, `postgres-2`. No random hash. Predictable, and stable across restarts.

**Startup is sequential.** `postgres-1` did not begin until `postgres-0` was **Ready** — not merely created, but passing its readiness probe. That is why the readiness probe matters more here than in a Deployment: without one, "ready" means "container started", and a replica could begin before the primary can accept connections.

```
devops@testvm:~/day-56$ kubectl get pvc -n devboard-dev
NAME              STATUS   VOLUME                                     CAPACITY   STORAGECLASS   AGE
data-postgres-0   Bound    pvc-1a4c7d0e-3f6a-9b2c-5d8e-1f4a7b0c3d6e   1Gi        standard       2m
data-postgres-1   Bound    pvc-9d2e5f8a-1b4c-7d0e-3f6a-9b2c5d8e1f4a   1Gi        standard       2m
data-postgres-2   Bound    pvc-5c8e1f4a-7b0c-3d6e-9f2a-5b8c1d4e7f0a   1Gi        standard       2m
```

**Three separate PVCs**, named `<volumeClaimTemplate-name>-<statefulset-name>-<ordinal>`. Each pod has its own storage. A Deployment with `replicas: 3` would have had one PVC shared by all three.

---

## Task 4: Stable network identity

```
devops@testvm:~/day-56$ kubectl run dns-test -n devboard-dev --rm -it \
    --image=busybox:1.36 --restart=Never -- sh

/ # nslookup postgres
Name:      postgres.devboard-dev.svc.cluster.local
Address 1: 10.244.1.12 postgres-0.postgres.devboard-dev.svc.cluster.local
Address 2: 10.244.2.9  postgres-1.postgres.devboard-dev.svc.cluster.local
Address 3: 10.244.1.13 postgres-2.postgres.devboard-dev.svc.cluster.local
```

**Three addresses from one lookup**, each labelled with its pod name. A normal Service would have returned one virtual IP.

Individual pods are addressable:

```
/ # nslookup postgres-0.postgres
Name:      postgres-0.postgres.devboard-dev.svc.cluster.local
Address 1: 10.244.1.12

/ # nc -zv postgres-0.postgres 5432
postgres-0.postgres (10.244.1.12:5432) open
```

The pattern is:

```
<pod-name>.<service-name>.<namespace>.svc.cluster.local
postgres-0 . postgres    . devboard-dev
```

This is why `serviceName:` is mandatory in a StatefulSet — it is what builds these names.

**Proving stability by deleting a pod:**

```
devops@testvm:~/day-56$ kubectl get pod postgres-1 -n devboard-dev -o wide
NAME         READY   STATUS    AGE   IP           NODE
postgres-1   1/1     Running   8m    10.244.2.9   devops-cluster-worker2

devops@testvm:~/day-56$ kubectl delete pod postgres-1 -n devboard-dev
pod "postgres-1" deleted

devops@testvm:~/day-56$ kubectl get pod postgres-1 -n devboard-dev -o wide
NAME         READY   STATUS    AGE   IP            NODE
postgres-1   1/1     Running   18s   10.244.2.11   devops-cluster-worker2
```

**Same name, different IP.** The name is stable; the IP is not. So `postgres-1.postgres` keeps working while the underlying address changed — which is exactly what a replication config needs.

---

## Task 5: Stable storage

```
devops@testvm:~/day-56$ kubectl exec -n devboard-dev postgres-1 -- \
    psql -U devboard -d devboard -c "CREATE TABLE marker (note TEXT);"
CREATE TABLE
devops@testvm:~/day-56$ kubectl exec -n devboard-dev postgres-1 -- \
    psql -U devboard -d devboard -c "INSERT INTO marker VALUES ('written on postgres-1');"
INSERT 0 1
```

Confirming the volumes really are separate:

```
devops@testvm:~/day-56$ kubectl exec -n devboard-dev postgres-0 -- \
    psql -U devboard -d devboard -c "SELECT * FROM marker;"
ERROR:  relation "marker" does not exist
```

**`postgres-0` cannot see it.** Three independent databases, three independent volumes.

That is worth being explicit about: **a StatefulSet does not replicate data.** It gives each replica stable storage and a stable name; making them into a cluster is the database's job, through Patroni, an operator, or configured streaming replication. Three Postgres pods from this manifest are three unrelated databases.

Deleting the pod:

```
devops@testvm:~/day-56$ kubectl delete pod postgres-1 -n devboard-dev
devops@testvm:~/day-56$ kubectl exec -n devboard-dev postgres-1 -- \
    psql -U devboard -d devboard -c "SELECT * FROM marker;"
         note
-----------------------
 written on postgres-1
(1 row)
```

**New pod, same PVC, same data.** The PVC is matched to the pod by ordinal, so `postgres-1` always gets `data-postgres-1`.

---

## Task 6: Ordered scaling

```
devops@testvm:~/day-56$ kubectl scale statefulset postgres -n devboard-dev --replicas=5
statefulset.apps/postgres scaled

devops@testvm:~/day-56$ kubectl get pods -n devboard-dev -l app=devboard-postgres -w
postgres-3   0/1     Pending             0s
postgres-3   1/1     Running             13s
postgres-4   0/1     Pending             0s
postgres-4   1/1     Running             12s
```

**Up in order: 3, then 4.** Each waits for the previous to be Ready.

Scaling down:

```
devops@testvm:~/day-56$ kubectl scale statefulset postgres -n devboard-dev --replicas=2
devops@testvm:~/day-56$ kubectl get pods -n devboard-dev -l app=devboard-postgres -w
postgres-4   1/1     Terminating   3m
postgres-3   1/1     Terminating   3m
postgres-2   1/1     Terminating   18m
```

**Down in reverse: 4, 3, then 2.** Highest ordinal first, one at a time.

The reason is that ordinal 0 is conventionally the primary. Scaling down from the top removes replicas and leaves the primary until last. Removing pods in a random order could take out the primary while replicas still depend on it.

```
devops@testvm:~/day-56$ kubectl get pvc -n devboard-dev
NAME              STATUS   VOLUME                                     CAPACITY   AGE
data-postgres-0   Bound    pvc-1a4c7d0e-...                           1Gi        22m
data-postgres-1   Bound    pvc-9d2e5f8a-...                           1Gi        22m
data-postgres-2   Bound    pvc-5c8e1f4a-...                           1Gi        22m
data-postgres-3   Bound    pvc-7f0a3b6c-...                           1Gi        6m
data-postgres-4   Bound    pvc-2e5f8a1b-...                           1Gi        6m
```

**Five PVCs remain, although only two pods exist.** Scaling down deletes pods and **keeps their volumes**, deliberately — scaling back to 5 reattaches the original data to `postgres-3` and `postgres-4`.

Safe, and a slow storage leak. Unused PVCs have to be deleted by hand:

```
devops@testvm:~/day-56$ kubectl delete pvc data-postgres-3 data-postgres-4 -n devboard-dev
```

Newer Kubernetes has `persistentVolumeClaimRetentionPolicy` to automate this, but the default is still Retain.

### StatefulSet vs Deployment

| | Deployment | StatefulSet |
|---|---|---|
| Pod names | `name-hash-random` | `name-0`, `name-1`, … |
| Name stable across restart | No | **Yes** |
| Storage | One PVC shared by all | **One PVC per pod** |
| Startup order | All at once | Sequential, 0 → N |
| Shutdown order | All at once | Reverse, N → 0 |
| Rolling update order | Any | Reverse, N → 0 |
| DNS per pod | No | Yes, via a headless Service |
| PVC deleted on scale-down | n/a | No, kept |
| Use for | Stateless apps | Databases, queues, anything with per-instance identity |

**Use a Deployment unless you genuinely need one of these properties.** StatefulSets are slower to scale, slower to update, and leave PVCs behind. Reaching for one because "the app has data" is usually wrong — DevBoard's backend is stateless and belongs in a Deployment even though it talks to a database.

DevBoard's `feat/k8s` branch has both `postgres-deployment.yml` and `postgres-statefulset.yml`, which is a useful comparison: the Deployment with `replicas: 1` and one PVC is the honest choice for a single local database, and the StatefulSet is what you would grow into.

---

## Task 7: Cleanup

```
devops@testvm:~/day-56$ kubectl delete statefulset postgres -n devboard-dev
statefulset.apps "postgres" deleted

devops@testvm:~/day-56$ kubectl get pvc -n devboard-dev
NAME              STATUS   VOLUME             CAPACITY   AGE
data-postgres-0   Bound    pvc-1a4c7d0e-...   1Gi        28m
data-postgres-1   Bound    pvc-9d2e5f8a-...   1Gi        28m
```

**Deleting the StatefulSet does not delete the PVCs.** Deliberate — that is the last line of defence against deleting a workload and losing the database with it.

```
devops@testvm:~/day-56$ kubectl delete pvc -n devboard-dev -l app=devboard-postgres
devops@testvm:~/day-56$ kubectl delete svc postgres -n devboard-dev
```

---

## Files in this folder

| Path | What it is |
|---|---|
| `manifests/headless-service.yaml` | `clusterIP: None`, gives each pod a DNS name |
| `manifests/postgres-statefulset.yaml` | 3 replicas, `volumeClaimTemplates`, readiness probe |

---

## What I learned

**1. `volumeClaimTemplates` gives each pod its own PVC.** That single field is the difference between three databases each with their own storage and three processes corrupting one shared volume. A Deployment with `replicas: 3` and a PVC does the wrong thing quietly.

**2. A StatefulSet gives identity, not replication.** Three Postgres pods came up with stable names and stable storage and were three **unrelated** databases — `postgres-0` could not see the table written on `postgres-1`. Clustering is the database's job; Kubernetes only provides the scaffolding.

**3. Ordering depends on the readiness probe.** `postgres-1` waited for `postgres-0` to be **Ready**, not merely started. Without a readiness probe, "ready" means the container process exists, and the ordering guarantee becomes meaningless.

**Two extras:**

- Scaling down keeps the PVCs, so data returns if you scale back up — and unused volumes accumulate until deleted by hand.
- Deleting a StatefulSet leaves its PVCs behind, which has saved someone's database more than once.
