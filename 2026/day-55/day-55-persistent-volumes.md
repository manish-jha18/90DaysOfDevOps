# Day 55 – Persistent Volumes and Claims

Manifests in `manifests/` in this folder. Day 32's volume problem, at cluster scale.

---

## Task 1: The problem

```
devops@testvm:~/day-55$ kubectl run pg-ephemeral -n devboard-dev --image=postgres:16-alpine \
    --env="POSTGRES_PASSWORD=devboard" --env="POSTGRES_USER=devboard" --env="POSTGRES_DB=devboard"
pod/pg-ephemeral created

devops@testvm:~/day-55$ kubectl exec -n devboard-dev pg-ephemeral -- \
    psql -U devboard -d devboard -c "CREATE TABLE notes (id SERIAL, body TEXT);"
CREATE TABLE

devops@testvm:~/day-55$ kubectl exec -n devboard-dev pg-ephemeral -- \
    psql -U devboard -d devboard -c "INSERT INTO notes (body) VALUES ('this will not survive');"
INSERT 0 1

devops@testvm:~/day-55$ kubectl exec -n devboard-dev pg-ephemeral -- \
    psql -U devboard -d devboard -c "SELECT * FROM notes;"
 id |         body
----+-----------------------
  1 | this will not survive
(1 row)
```

Delete and recreate:

```
devops@testvm:~/day-55$ kubectl delete pod pg-ephemeral -n devboard-dev
devops@testvm:~/day-55$ kubectl run pg-ephemeral -n devboard-dev --image=postgres:16-alpine \
    --env="POSTGRES_PASSWORD=devboard" --env="POSTGRES_USER=devboard" --env="POSTGRES_DB=devboard"

devops@testvm:~/day-55$ kubectl exec -n devboard-dev pg-ephemeral -- \
    psql -U devboard -d devboard -c "SELECT * FROM notes;"
ERROR:  relation "notes" does not exist
```

Gone, for exactly the Day 32 reason — the container's writable layer is created and destroyed with it.

**Worse in Kubernetes than in Docker**, because pods are deliberately disposable. A node drain, a rolling update, an eviction under memory pressure, a rescheduled pod after node failure — all of these destroy and recreate pods as normal operation. In Docker you at least have to type `docker rm`.

`emptyDir` is the volume type that survives a **container** restart but not a pod deletion, which is useful for scratch space and useless for a database.

---

## Task 2: A PersistentVolume

**`manifests/persistent-volume.yaml`**

```yaml
apiVersion: v1
kind: PersistentVolume
metadata:
  name: postgres-pv
  labels:
    app: devboard-postgres
spec:
  capacity:
    storage: 1Gi
  accessModes:
    - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  storageClassName: manual
  hostPath:
    path: /mnt/devboard-postgres
```

```
devops@testvm:~/day-55$ kubectl apply -f manifests/persistent-volume.yaml
persistentvolume/postgres-pv created

devops@testvm:~/day-55$ kubectl get pv
NAME          CAPACITY   ACCESS MODES   RECLAIM POLICY   STATUS      CLAIM   STORAGECLASS   AGE
postgres-pv   1Gi        RWO            Retain           Available           manual         8s
```

**`Available`** — it exists and nothing has claimed it.

**A PV is cluster-scoped**, not namespaced. It represents a piece of actual storage, which does not belong to a namespace. The PVC that claims it *is* namespaced — that split from Day 52 matters here.

### Access modes

| Mode | Short | Meaning |
|---|---|---|
| ReadWriteOnce | RWO | One **node** can mount it read-write |
| ReadOnlyMany | ROX | Many nodes, read-only |
| ReadWriteMany | RWX | Many nodes, read-write |
| ReadWriteOncePod | RWOP | Exactly one **pod** |

**RWO is per node, not per pod** — a detail I had wrong. Two pods on the *same* node can both mount an RWO volume. Two pods on different nodes cannot.

RWX is the one most storage does not support. AWS EBS and GCE PD are block devices and are RWO only; RWX needs a network filesystem such as NFS or EFS. Trying to run three replicas sharing one EBS volume simply does not work, and the pods sit Pending.

### Reclaim policy

- **Retain** — the PV survives PVC deletion, keeping the data. Requires manual cleanup before it can be reused.
- **Delete** — the PV and the underlying storage are deleted with the claim. The default for dynamic provisioning.

`Retain` on anything holding data worth keeping. `Delete` is convenient and is how people lose databases.

### hostPath's limitation

`hostPath` mounts a directory from **the node's** filesystem. On a multi-node cluster that is a trap: a pod rescheduled to another node finds an empty directory, because the data is on the first node's disk. It looks like the data vanished.

Fine for a single-node cluster or a demo. Never for anything real — that is what a network-backed storage class is for.

---

## Task 3: A PersistentVolumeClaim

**`manifests/persistent-volume-claim.yaml`**

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: postgres-pvc
  namespace: devboard-dev
spec:
  storageClassName: manual
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 500Mi
```

```
devops@testvm:~/day-55$ kubectl apply -f manifests/persistent-volume-claim.yaml
persistentvolumeclaim/postgres-pvc created

devops@testvm:~/day-55$ kubectl get pvc -n devboard-dev
NAME           STATUS   VOLUME        CAPACITY   ACCESS MODES   STORAGECLASS   AGE
postgres-pvc   Bound    postgres-pv   1Gi        RWO            manual         6s

devops@testvm:~/day-55$ kubectl get pv
NAME          CAPACITY   ACCESS MODES   RECLAIM POLICY   STATUS   CLAIM                       STORAGECLASS
postgres-pv   1Gi        RWO            Retain           Bound    devboard-dev/postgres-pvc   manual
```

**`Bound`** on both sides. The PV now names its claim.

**The claim asked for 500Mi and got the whole 1Gi.** Binding is not partitioning — the claim is matched to a PV that is *at least* big enough, and it gets all of it. One PV binds to exactly one PVC.

Matching requires the **storage class, access mode and capacity** all to be compatible. Mismatch any of them and the claim sits `Pending` with no error:

```
devops@testvm:~/day-55$ kubectl get pvc bad-pvc -n devboard-dev
NAME      STATUS    VOLUME   CAPACITY   ACCESS MODES   STORAGECLASS   AGE
bad-pvc   Pending                                      wrong-class    30s

devops@testvm:~/day-55$ kubectl describe pvc bad-pvc -n devboard-dev | tail -3
Events:
  Type    Reason         Age   From                         Message
  Normal  FailedBinding  12s   persistentvolume-controller  no persistent volumes available for this claim and no storage class is set
```

`kubectl describe` has the reason. `kubectl get` alone shows only `Pending`, which is the usual first sighting of the problem.

---

## Task 4: Using the PVC

**`manifests/postgres-with-pvc.yaml`** — the relevant part:

```yaml
          env:
            - name: PGDATA
              value: /var/lib/postgresql/data/pgdata
          volumeMounts:
            - name: data
              mountPath: /var/lib/postgresql/data
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: postgres-pvc
```

**`PGDATA` pointing at a subdirectory is not optional**, and this is worth explaining. Postgres refuses to initialise into a non-empty directory, and a freshly mounted volume very often contains `lost+found`. So the mount goes at `/var/lib/postgresql/data` and Postgres is told to use `data/pgdata` beneath it.

Without it:

```
initdb: error: directory "/var/lib/postgresql/data" exists but is not empty
```

The pod crash-loops with an error that says nothing about volumes. DevBoard's own manifests hit this — one of the commits on the `feat/k8s` branch is literally "Fix PGDATA variable and readiness probe command".

```
devops@testvm:~/day-55$ kubectl apply -f manifests/postgres-with-pvc.yaml
deployment.apps/postgres created

devops@testvm:~/day-55$ kubectl exec -n devboard-dev deploy/postgres -- \
    psql -U devboard -d devboard -c "CREATE TABLE notes (id SERIAL, body TEXT);"
CREATE TABLE
devops@testvm:~/day-55$ kubectl exec -n devboard-dev deploy/postgres -- \
    psql -U devboard -d devboard -c "INSERT INTO notes (body) VALUES ('this should survive');"
INSERT 0 1
```

Destroy the pod:

```
devops@testvm:~/day-55$ kubectl delete pod -n devboard-dev -l app=devboard-postgres
pod "postgres-6d9f4b8c7a-x2mkp" deleted

devops@testvm:~/day-55$ kubectl get pods -n devboard-dev -l app=devboard-postgres
NAME                        READY   STATUS    RESTARTS   AGE
postgres-6d9f4b8c7a-k7wqz   1/1     Running   0          14s

devops@testvm:~/day-55$ kubectl exec -n devboard-dev deploy/postgres -- \
    psql -U devboard -d devboard -c "SELECT * FROM notes;"
 id |        body
----+---------------------
  1 | this should survive
(1 row)
```

**Different pod, same data.**

Even after deleting the whole Deployment:

```
devops@testvm:~/day-55$ kubectl delete deployment postgres -n devboard-dev
devops@testvm:~/day-55$ kubectl get pvc -n devboard-dev
NAME           STATUS   VOLUME        CAPACITY   STORAGECLASS   AGE
postgres-pvc   Bound    postgres-pv   1Gi        manual         12m
```

The PVC and the data outlive the workload entirely. That is the point — storage has a lifecycle independent of pods.

---

## Task 5: StorageClasses

```
devops@testvm:~/day-55$ kubectl get storageclass
NAME                 PROVISIONER             RECLAIMPOLICY   VOLUMEBINDINGMODE      AGE
standard (default)   rancher.io/local-path   Delete          WaitForFirstConsumer   3d
```

kind ships `local-path` as the default. On EKS it would be `gp2` or `gp3` backed by EBS; on GKE `standard-rwo`.

A StorageClass is **a template for creating storage on demand**. It names a provisioner, a reclaim policy and a binding mode.

**`VOLUMEBINDINGMODE: WaitForFirstConsumer`** is the field worth understanding. With `Immediate`, a PV is created as soon as the claim is — possibly on a node that cannot then run the pod, leaving it Pending forever. `WaitForFirstConsumer` delays creation until a pod is scheduled, so the volume is created on the right node. For any node-local storage this is the correct setting.

`(default)` means a PVC with no `storageClassName` uses this class. Setting `storageClassName: ""` explicitly opts out and forces static binding.

---

## Task 6: Dynamic provisioning

**`manifests/dynamic-pvc.yaml`**

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: postgres-pvc-dynamic
  namespace: devboard-dev
spec:
  storageClassName: standard
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 1Gi
```

**No PV written by hand.**

```
devops@testvm:~/day-55$ kubectl apply -f manifests/dynamic-pvc.yaml
persistentvolumeclaim/postgres-pvc-dynamic created

devops@testvm:~/day-55$ kubectl get pvc postgres-pvc-dynamic -n devboard-dev
NAME                   STATUS    VOLUME   CAPACITY   ACCESS MODES   STORAGECLASS   AGE
postgres-pvc-dynamic   Pending                                      standard       5s
```

**Pending — and correctly so.** `WaitForFirstConsumer` means nothing is provisioned until a pod needs it.

```
devops@testvm:~/day-55$ kubectl describe pvc postgres-pvc-dynamic -n devboard-dev | tail -3
Events:
  Normal  WaitForFirstConsumer  8s  persistentvolume-controller
          waiting for first consumer to be created before binding
```

Creating a pod that uses it:

```
devops@testvm:~/day-55$ kubectl get pvc postgres-pvc-dynamic -n devboard-dev
NAME                   STATUS   VOLUME                                     CAPACITY   STORAGECLASS   AGE
postgres-pvc-dynamic   Bound    pvc-3f8a2c91-d4e7-4b1a-9c8e-0d4a1f27b8a3   1Gi        standard       48s

devops@testvm:~/day-55$ kubectl get pv
NAME                                       CAPACITY   RECLAIM POLICY   STATUS   CLAIM                               STORAGECLASS
postgres-pv                                1Gi        Retain           Bound    devboard-dev/postgres-pvc           manual
pvc-3f8a2c91-d4e7-4b1a-9c8e-0d4a1f27b8a3   1Gi        Delete           Bound    devboard-dev/postgres-pvc-dynamic   standard
```

**A PV appeared on its own**, named after the claim's UID, with reclaim policy `Delete` from the StorageClass.

| | Static | Dynamic |
|---|---|---|
| Who creates the PV | An admin, by hand | The provisioner, automatically |
| When | Before the claim | When a pod needs it |
| Reclaim policy | Whatever the PV says | From the StorageClass |
| Good for | Pre-existing storage, specific hardware | Almost everything |

Dynamic is the normal case on any cloud. Static exists for storage that already exists and must be attached to a particular claim.

**Note the reclaim policy difference.** `Delete` means deleting the PVC destroys the underlying storage. Convenient in dev, and the reason a `kubectl delete namespace` can take a production database with it. Anything valuable gets `Retain`.

---

## Task 7: Cleanup

```
devops@testvm:~/day-55$ kubectl delete pvc postgres-pvc-dynamic -n devboard-dev
persistentvolumeclaim "postgres-pvc-dynamic" deleted

devops@testvm:~/day-55$ kubectl get pv
NAME          CAPACITY   RECLAIM POLICY   STATUS   CLAIM                       STORAGECLASS
postgres-pv   1Gi        Retain           Bound    devboard-dev/postgres-pvc   manual
```

The dynamic PV is gone with its claim — `Delete` policy.

```
devops@testvm:~/day-55$ kubectl delete pvc postgres-pvc -n devboard-dev
devops@testvm:~/day-55$ kubectl get pv
NAME          CAPACITY   RECLAIM POLICY   STATUS     CLAIM                       STORAGECLASS
postgres-pv   1Gi        Retain           Released   devboard-dev/postgres-pvc   manual
```

**`Released`, not `Available`.** The static PV survived, but it will not accept a new claim while it still references the old one — the data is still there and Kubernetes will not hand it to someone else. Reusing it means clearing the `claimRef` by hand, or deleting and recreating the PV.

Recreated the PVC and Postgres deployment for Day 56.

---

## Files in this folder

| Path | What it is |
|---|---|
| `manifests/persistent-volume.yaml` | Static hostPath PV, `Retain` policy |
| `manifests/persistent-volume-claim.yaml` | Claim binding to it |
| `manifests/dynamic-pvc.yaml` | Dynamic claim, no PV written by hand |
| `manifests/postgres-with-pvc.yaml` | Postgres using the PVC, with the `PGDATA` fix |

---

## What I learned

**1. `PGDATA` has to point at a subdirectory of the mount.** A mounted volume usually contains `lost+found`, and Postgres refuses to initialise into a non-empty directory. The resulting crash loop says nothing about volumes, which makes it a genuinely hard first debug. This is a real fix in DevBoard's own k8s commit history.

**2. ReadWriteOnce is per node, not per pod.** Two pods on the same node can share an RWO volume; two on different nodes cannot. And RWX is unsupported by most block storage, so "three replicas sharing one EBS volume" is not a thing that works.

**3. Reclaim policy is what decides whether data survives.** `Delete` on a dynamic PV means deleting the PVC destroys the storage. `Retain` keeps it, but leaves the PV `Released` and unusable until the old `claimRef` is cleared.

**Two extras:**

- `WaitForFirstConsumer` delays provisioning until a pod is scheduled, so node-local storage is created on the right node. A PVC sitting Pending with that event is working as designed.
- A PV is cluster-scoped, a PVC is namespaced. Storage is physical; the claim on it belongs to a team.
