# Day 60 – Capstone: WordPress + MySQL on Kubernetes

Everything from Days 50–59 in one stack. Manifests in `manifests/`, numbered in apply order.

```
manifests/
├── 00-namespace.yaml
├── 01-config-and-secrets.yaml
├── 02-mysql.yaml
├── 03-wordpress.yaml
├── 04-service.yaml
└── 05-hpa.yaml
```

The numeric prefixes matter — `kubectl apply -f manifests/` processes files alphabetically, so the namespace exists before anything is placed in it.

---

## Task 1: Namespace

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: capstone
  labels:
    environment: capstone
```

```
devops@testvm:~/day-60$ kubectl apply -f manifests/00-namespace.yaml
namespace/capstone created
```

Every resource carries `namespace: capstone` in its own metadata rather than relying on `-n` or a context default. Day 52's lesson — a manifest that names its namespace cannot be applied to the wrong one by accident.

---

## Task 2: MySQL

**Config and secrets first** (Day 54):

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: wordpress-secrets
  namespace: capstone
type: Opaque
stringData:
  MYSQL_ROOT_PASSWORD: capstone-root-pw
  MYSQL_PASSWORD: capstone-wp-pw
```

`stringData` rather than base64 `data`, because a reviewer can actually read it. These are throwaway local values — a real password here would be the Day 27 leak, made worse by looking encrypted.

**MySQL as a StatefulSet** (Day 56), with a headless Service:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: mysql
  namespace: capstone
spec:
  clusterIP: None
  selector:
    app: mysql
  ports:
    - port: 3306
```

**Why a StatefulSet for a single replica?** Two reasons that hold even at `replicas: 1`:

- **`volumeClaimTemplates` gives the pod its own PVC**, and that PVC survives deleting the StatefulSet. A Deployment with a hand-written PVC works, but nothing stops someone later scaling it to 2 and having two MySQL processes write to one volume.
- **A stable name.** `mysql-0` is always `mysql-0`.

The probes are `exec`, not `httpGet` — MySQL has no HTTP endpoint:

```yaml
          readinessProbe:
            exec:
              command: ["sh", "-c", "mysqladmin ping -h127.0.0.1 -uroot -p$MYSQL_ROOT_PASSWORD"]
            initialDelaySeconds: 20
            periodSeconds: 5
          livenessProbe:
            exec:
              command: ["sh", "-c", "mysqladmin ping -h127.0.0.1 -uroot -p$MYSQL_ROOT_PASSWORD"]
            initialDelaySeconds: 60
            periodSeconds: 20
```

**Liveness is far more relaxed than readiness** — 60s delay, 20s period, versus 20s and 5s. Day 57's reasoning: readiness controls traffic and should react quickly; liveness kills the container and should be slow to fire. An aggressive liveness probe on a database under load restarts it precisely when it is busiest.

```
devops@testvm:~/day-60$ kubectl apply -f manifests/01-config-and-secrets.yaml -f manifests/02-mysql.yaml
configmap/wordpress-config created
secret/wordpress-secrets created
service/mysql created
statefulset.apps/mysql created

devops@testvm:~/day-60$ kubectl get pods -n capstone -w
NAME      READY   STATUS              RESTARTS   AGE
mysql-0   0/1     Pending             0          0s
mysql-0   0/1     ContainerCreating   0          2s
mysql-0   0/1     Running             0          8s
mysql-0   1/1     Running             0          34s
```

**26 seconds between `Running` and `1/1`.** That gap is the readiness probe — the container was up but MySQL was still initialising. Without a readiness probe the pod would have been marked ready at 8 seconds and WordPress would have connected to a database that was not accepting connections.

---

## Task 3: WordPress

```yaml
spec:
  # no replicas: field - the HPA owns it
  selector:
    matchLabels:
      app: wordpress
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 0
```

**No `replicas:` field at all.** Day 58's conflict — an HPA is defined in `05-hpa.yaml`, so leaving `replicas:` here would mean every `kubectl apply` briefly resets the count.

The database connection comes from the ConfigMap:

```yaml
            - name: WORDPRESS_DB_HOST
              valueFrom:
                configMapKeyRef:
                  name: wordpress-config
                  key: WORDPRESS_DB_HOST     # "mysql:3306"
```

`mysql:3306` is Kubernetes DNS (Day 53) — the Service name resolves within the namespace. No IPs anywhere.

**A startup probe** because WordPress writes its files on first boot and can be slow:

```yaml
          startupProbe:
            httpGet:
              path: /
              port: 80
            failureThreshold: 30
            periodSeconds: 2
```

Up to 60 seconds to start, with liveness and readiness held off until it passes. Day 57's exact use case.

**A PVC for uploads:**

```yaml
          volumeMounts:
            - name: uploads
              mountPath: /var/www/html/wp-content/uploads
```

Only `uploads`, not the whole of `/var/www/html`. WordPress core comes from the image and should stay immutable; only user-uploaded media needs to persist.

**This is also the honest limitation of the setup.** The PVC is `ReadWriteOnce`, so all WordPress replicas must land on the same node to share it. With the HPA scaling to 6 pods, some will end up on another node and fail to mount:

```
Warning  FailedAttachVolume  pod has unbound immediate PersistentVolumeClaims
```

Day 55's access-mode lesson, in a real design. Fixing it properly needs `ReadWriteMany` — NFS, EFS, or Longhorn — or moving media to S3, which is what a production WordPress does.

```
devops@testvm:~/day-60$ kubectl apply -f manifests/03-wordpress.yaml -f manifests/04-service.yaml
deployment.apps/wordpress created
persistentvolumeclaim/wordpress-uploads created
service/wordpress created

devops@testvm:~/day-60$ kubectl get pods -n capstone
NAME                        READY   STATUS    RESTARTS   AGE
mysql-0                     1/1     Running   0          3m
wordpress-6d9f4b8c7a-k7wqz  1/1     Running   0          52s
wordpress-6d9f4b8c7a-p2nvx  1/1     Running   0          52s
```

---

## Task 4: Exposing it

```yaml
apiVersion: v1
kind: Service
metadata:
  name: wordpress
  namespace: capstone
spec:
  type: NodePort
  selector:
    app: wordpress
  ports:
    - port: 80
      targetPort: 80
      nodePort: 30080
```

NodePort because kind has no cloud provider — `type: LoadBalancer` would sit at `<pending>` (Day 53). The `extraPortMappings` from the Day 50 cluster config publishes 30080 to the host.

```
devops@testvm:~$ curl -sI http://localhost:30080 | head -2
HTTP/1.1 302 Found
Location: http://localhost:30080/wp-admin/install.php
```

A 302 to the installer — WordPress is running and has reached MySQL. Completed the setup in the browser and published a test post.

```
devops@testvm:~/day-60$ kubectl get all -n capstone
NAME                             READY   STATUS    RESTARTS   AGE
pod/mysql-0                      1/1     Running   0          12m
pod/wordpress-6d9f4b8c7a-k7wqz   1/1     Running   0          9m
pod/wordpress-6d9f4b8c7a-p2nvx   1/1     Running   0          9m

NAME                TYPE        CLUSTER-IP     EXTERNAL-IP   PORT(S)        AGE
service/mysql       ClusterIP   None           <none>        3306/TCP       12m
service/wordpress   NodePort    10.96.88.142   <none>        80:30080/TCP   9m

NAME                        READY   UP-TO-DATE   AVAILABLE   AGE
deployment.apps/wordpress   2/2     2            2           9m

NAME                                   DESIRED   CURRENT   READY   AGE
replicaset.apps/wordpress-6d9f4b8c7a   2         2         2       9m

NAME                       READY   AGE
statefulset.apps/mysql     1/1     12m

NAME                                                REFERENCE              TARGETS       MINPODS   MAXPODS   REPLICAS
horizontalpodautoscaler.../wordpress                Deployment/wordpress   cpu: 2%/60%   2         6         2
```

The whole stack in one listing.

---

## Task 5: Self-healing and persistence

**Kill a WordPress pod:**

```
devops@testvm:~/day-60$ kubectl delete pod -n capstone wordpress-6d9f4b8c7a-k7wqz
pod "wordpress-6d9f4b8c7a-k7wqz" deleted

devops@testvm:~/day-60$ kubectl get pods -n capstone -l app=wordpress
NAME                         READY   STATUS    RESTARTS   AGE
wordpress-6d9f4b8c7a-p2nvx   1/1     Running   0          11m
wordpress-6d9f4b8c7a-vz9lt   1/1     Running   0          14s
```

Replaced in seconds, and **the site never went down** — the other replica kept serving, and the new pod only joined the Service endpoints once readiness passed.

**Kill the database:**

```
devops@testvm:~/day-60$ kubectl delete pod -n capstone mysql-0
pod "mysql-0" deleted

devops@testvm:~/day-60$ kubectl get pods -n capstone -w
mysql-0   0/1   Pending             0     0s
mysql-0   0/1   ContainerCreating   0     1s
mysql-0   0/1   Running             0     6s
mysql-0   1/1   Running             0     28s
```

**Same name, `mysql-0`** — the StatefulSet guarantee. During those 28 seconds WordPress returned database errors, which is expected with a single database replica. Real high availability needs replication, which a StatefulSet enables but does not provide (Day 56).

```
devops@testvm:~$ curl -s http://localhost:30080 | grep -o "<title>[^<]*</title>"
<title>Capstone Test Site &#8211; Day 60</title>
```

**The site title and the test post survived.** The data is in the `data-mysql-0` PVC, not the pod.

**The harder test — delete the whole StatefulSet:**

```
devops@testvm:~/day-60$ kubectl delete statefulset mysql -n capstone
statefulset.apps "mysql" deleted

devops@testvm:~/day-60$ kubectl get pvc -n capstone
NAME               STATUS   VOLUME                CAPACITY   STORAGECLASS   AGE
data-mysql-0       Bound    pvc-8a3f91c4-...      2Gi        standard       18m
wordpress-uploads  Bound    pvc-2e5f8a1b-...      1Gi        standard       15m

devops@testvm:~/day-60$ kubectl apply -f manifests/02-mysql.yaml
devops@testvm:~$ curl -s http://localhost:30080 | grep -o "<title>[^<]*</title>"
<title>Capstone Test Site &#8211; Day 60</title>
```

The workload was deleted and recreated and the data came back, because the PVC outlived it. That is the whole point of the storage/workload split.

---

## Task 6: HPA

```
devops@testvm:~/day-60$ kubectl apply -f manifests/05-hpa.yaml
horizontalpodautoscaler.autoscaling/wordpress created

devops@testvm:~/day-60$ kubectl get hpa -n capstone
NAME        REFERENCE              TARGETS       MINPODS   MAXPODS   REPLICAS
wordpress   Deployment/wordpress   cpu: 2%/60%   2         6         2
```

Under load:

```
devops@testvm:~/day-60$ kubectl run load -n capstone --rm -it --image=busybox:1.36 --restart=Never -- \
    /bin/sh -c "while sleep 0.01; do wget -q -O- http://wordpress; done"
```

```
NAME        REFERENCE              TARGETS         REPLICAS
wordpress   Deployment/wordpress   cpu: 2%/60%     2
wordpress   Deployment/wordpress   cpu: 143%/60%   2
wordpress   Deployment/wordpress   cpu: 143%/60%   5
wordpress   Deployment/wordpress   cpu: 71%/60%    5
wordpress   Deployment/wordpress   cpu: 58%/60%    5
```

`ceil(2 × 143/60) = ceil(4.77) = 5`. Exactly Day 58's formula.

**And the RWO problem appeared, as predicted:**

```
devops@testvm:~/day-60$ kubectl get pods -n capstone -l app=wordpress
NAME                         READY   STATUS              RESTARTS   AGE
wordpress-6d9f4b8c7a-4jx2p   0/1     ContainerCreating   0          38s
...
devops@testvm:~/day-60$ kubectl describe pod -n capstone wordpress-6d9f4b8c7a-4jx2p | tail -3
  Warning  FailedAttachVolume  35s  attachdetach-controller
           Multi-Attach error for volume "pvc-2e5f8a1b" Volume is already exclusively attached to one node
```

The pods scheduled onto `worker` came up; those on `worker2` could not attach the uploads PVC. **A design flaw that only appears under scale**, and a good demonstration of why access modes matter before you need them rather than after.

---

## Task 7: Comparison with Helm

```
devops@testvm:~/day-60$ helm install wp bitnami/wordpress -n capstone-helm --create-namespace \
    --set wordpressUsername=admin \
    --set mariadb.primary.persistence.size=2Gi \
    --set service.type=NodePort
```

**One command against six manifests and about 250 lines.**

The trade-off is real in both directions. Helm is faster and encodes a lot of expertise — the Bitnami chart handles secret generation, init containers, pod anti-affinity, network policies and metrics exporters that I did not write. But `helm show values bitnami/wordpress` is over 1,500 lines, and when something breaks you are debugging templates you did not write.

Writing the manifests by hand first was worth it. Every field is there because I decided it should be, and having hit the RWO problem myself means I know what the chart's `ReadWriteMany` note is actually about.

**Where I would use which:** Helm for third-party software — databases, ingress controllers, monitoring stacks, where the chart authors know the software better than I do. Hand-written manifests, or a small chart of my own like Day 59's, for my own applications.

---

## Task 8: Cleanup and reflection

```
devops@testvm:~/day-60$ kubectl delete namespace capstone
namespace "capstone" deleted
devops@testvm:~/day-60$ helm uninstall wp -n capstone-helm && kubectl delete ns capstone-helm
```

Deleting the namespace removes everything including the PVCs — Day 52's warning about how total that is.

### The architecture

```
                    host :30080
                         │
              ┌──────────▼──────────┐
              │  Service wordpress  │  NodePort 30080 → 80
              │  (day 53)           │
              └──────────┬──────────┘
                         │  selector: app=wordpress
         ┌───────────────┼───────────────┐
         ▼               ▼               ▼
  ┌────────────┐  ┌────────────┐  ┌────────────┐
  │ wordpress  │  │ wordpress  │  │ wordpress  │   Deployment, no replicas:
  │ pod        │  │ pod        │  │ pod        │   HPA 2-6 @ 60% CPU (day 58)
  │            │  │            │  │            │   startup/ready/live (day 57)
  └─────┬──────┘  └─────┬──────┘  └─────┬──────┘
        │  uploads PVC (RWO - the bottleneck, day 55)
        │
        │  WORDPRESS_DB_HOST = mysql:3306   (ConfigMap, day 54)
        │  WORDPRESS_DB_PASSWORD            (Secret, day 54)
        ▼
  ┌─────────────────────┐
  │ Service mysql       │  clusterIP: None - headless (day 56)
  └──────────┬──────────┘
             ▼
      ┌─────────────┐
      │  mysql-0    │   StatefulSet, stable name
      │             │   exec probes (day 57)
      └──────┬──────┘
             │  volumeClaimTemplates → data-mysql-0 (day 56)
             ▼
      ┌─────────────┐
      │ PVC 2Gi     │   survives pod AND statefulset deletion
      └─────────────┘

  namespace: capstone (day 52)   ·   Metrics Server feeding the HPA (day 58)
```

### What each day contributed

| Day | In this stack |
|---|---|
| 50 | The kind cluster, with `extraPortMappings` for the NodePort |
| 51 | Manifest structure — apiVersion, kind, metadata, spec |
| 52 | Namespace; Deployment with zero-downtime rolling update |
| 53 | Headless Service for MySQL, NodePort for WordPress, DNS by name |
| 54 | ConfigMap for non-secret config, Secret via `stringData` |
| 55 | PVC for uploads; the RWO access mode that later bit |
| 56 | StatefulSet with `volumeClaimTemplates` for the database |
| 57 | Requests/limits everywhere; exec probes for MySQL, startup probe for WordPress |
| 58 | Metrics Server and the HPA; no `replicas:` in the Deployment |
| 59 | The Helm comparison |

### What I would fix before calling this production

**The RWO uploads volume is the real bug.** It limits WordPress to one node, which defeats the HPA. Fix: `ReadWriteMany` storage, or an S3 offload plugin so pods hold no state at all.

**MySQL is a single point of failure.** 28 seconds of downtime when the pod was deleted, and a lost node means real data-loss risk. A StatefulSet provides identity, not replication — this needs an operator or configured replication.

**No Ingress.** NodePort works locally but means one port per service and no TLS. One Ingress controller with a single LoadBalancer is the cloud answer (Day 53).

**No backups.** A PVC protects against pod deletion, not against a dropped table. `mysqldump` on a CronJob to object storage.

**Secrets are in git.** Fine for throwaway values, wrong for anything real. Sealed Secrets or External Secrets, which Days 84–86 will need for GitOps.

**No NetworkPolicy.** Any pod in the cluster can reach MySQL on 3306. Namespaces isolate names, not traffic (Day 52).

**No resource quotas** on the namespace, so one bad deployment could starve the node.

---

## What I learned

**1. Storage lifecycle is separate from workload lifecycle, and that is the whole point.** Deleting the StatefulSet and re-applying it brought the site back with its content intact, because the PVC never left. Once that clicked, the split between PV, PVC and pod stopped feeling like ceremony.

**2. Access modes constrain the architecture, not just the storage.** The RWO uploads volume quietly capped WordPress at one node, and the failure only appeared when the HPA scaled past it. Access mode is a design decision made at the start that determines whether horizontal scaling is possible at all.

**3. Readiness probes are what make rolling updates and scaling safe.** MySQL sat `Running` but `0/1` for 26 seconds while initialising. Without the probe, WordPress would have connected to a database that was not listening — and the ordering guarantees in StatefulSets and the zero-downtime promise of `maxUnavailable: 0` both depend entirely on readiness meaning something real.

**Two extras:**

- Number your manifest files. `kubectl apply -f dir/` is alphabetical, so `00-namespace.yaml` first is not cosmetic.
- Liveness should be much more relaxed than readiness. Readiness reacts fast to steer traffic; liveness kills the container and should be reluctant.
