# Day 58 – Metrics Server and Horizontal Pod Autoscaler

Manifest in `manifests/` in this folder. Day 34 ended with `--scale web=3` failing on a port collision and no way to load balance. This is the answer to both.

---

## Task 1: Installing the Metrics Server

```
devops@testvm:~/day-58$ kubectl top nodes
error: Metrics API not available
```

Nothing collects resource usage by default. The Metrics Server scrapes kubelet on each node and serves the data through the metrics API — HPAs consume it, and so does `kubectl top`.

```
devops@testvm:~/day-58$ kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
serviceaccount/metrics-server created
clusterrole.rbac.authorization.k8s.io/system:aggregated-metrics-reader created
service/metrics-server created
deployment.apps/metrics-server created
apiservice.apiregistration.k8s.io/v1beta1.metrics.k8s.io created

devops@testvm:~/day-58$ kubectl get pods -n kube-system -l k8s-app=metrics-server
NAME                              READY   STATUS    RESTARTS   AGE
metrics-server-587b667b55-4jx2p   0/1     Running   0          62s
```

**`0/1` and staying that way.**

```
devops@testvm:~/day-58$ kubectl logs -n kube-system -l k8s-app=metrics-server | tail -3
E0803 09:22:41.882104  scraper.go:149] "Failed to scrape node" err="Get \"https://172.18.0.2:10250/metrics/resource\":
  tls: failed to verify certificate: x509: cannot validate certificate for 172.18.0.2
  because it doesn't contain any IP SANs" node="devops-cluster-worker"
```

**A certificate problem, and it is expected on kind.** kubelet serves metrics over TLS with a self-signed certificate that has no IP SAN. On a managed cluster the certificates are properly signed; on kind and minikube they are not.

The fix is one flag:

```
devops@testvm:~/day-58$ kubectl patch deployment metrics-server -n kube-system --type=json \
    -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'
deployment.apps/metrics-server patched

devops@testvm:~/day-58$ kubectl get pods -n kube-system -l k8s-app=metrics-server
NAME                              READY   STATUS    RESTARTS   AGE
metrics-server-6d4f8b9c6d-p2nvx   1/1     Running   0          38s
```

`--kubelet-insecure-tls` skips verification. Acceptable on a local cluster, **not on a real one** — it disables authentication of the thing you are scraping.

(minikube avoids all of this with `minikube addons enable metrics-server`. The one place minikube is genuinely easier than kind, as noted on Day 50.)

---

## Task 2: `kubectl top`

```
devops@testvm:~/day-58$ kubectl top nodes
NAME                           CPU(cores)   CPU%   MEMORY(bytes)   MEMORY%
devops-cluster-control-plane   184m         9%     712Mi           18%
devops-cluster-worker          51m          2%     388Mi           9%
devops-cluster-worker2         43m          2%     341Mi           8%

devops@testvm:~/day-58$ kubectl top pods -n devboard-dev
NAME                                 CPU(cores)   MEMORY(bytes)
devboard-frontend-7d4f8b9c6d-2xk4p   1m           28Mi
devboard-frontend-7d4f8b9c6d-8mnq7   1m           27Mi
devboard-frontend-7d4f8b9c6d-vz9lt   1m           28Mi
```

Actual usage, against the requests and limits from Day 57. The frontend pods use 1m of CPU while requesting 100m — over-requested by a factor of 100, which is worth knowing because requests are what consume schedulable capacity.

```
devops@testvm:~/day-58$ kubectl top pods -A --sort-by=memory | head -5
NAMESPACE     NAME                                                   CPU(cores)   MEMORY(bytes)
kube-system   etcd-devops-cluster-control-plane                      42m          104Mi
kube-system   kube-apiserver-devops-cluster-control-plane            61m          298Mi
kube-system   kube-controller-manager-devops-cluster-control-plane   18m          54Mi
```

**Metrics Server is not monitoring.** It keeps roughly the last minute in memory, with no history and no storage — it exists to feed the HPA. Prometheus is what stores time series, which is Days 73–77.

---

## Task 3: A Deployment with CPU requests

**This is the prerequisite everyone misses.** An HPA targeting CPU *utilisation* computes a percentage of the pod's **request**. With no request there is no denominator, and the HPA reports `<unknown>` forever.

```
devops@testvm:~/day-58$ kubectl create deployment php-apache -n devboard-dev \
    --image=registry.k8s.io/hpa-example
devops@testvm:~/day-58$ kubectl set resources deployment php-apache -n devboard-dev \
    --requests=cpu=100m --limits=cpu=500m
devops@testvm:~/day-58$ kubectl expose deployment php-apache -n devboard-dev --port=80
```

`hpa-example` is a small PHP page that burns CPU on every request — built for this demonstration.

---

## Task 4: An HPA, imperatively

```
devops@testvm:~/day-58$ kubectl autoscale deployment php-apache -n devboard-dev \
    --cpu-percent=50 --min=1 --max=5
horizontalpodautoscaler.autoscaling/php-apache autoscaled

devops@testvm:~/day-58$ kubectl get hpa -n devboard-dev
NAME         REFERENCE               TARGETS       MINPODS   MAXPODS   REPLICAS   AGE
php-apache   Deployment/php-apache   cpu: 0%/50%   1         5         1          32s
```

**`0%/50%`** — current utilisation over target. It took about 30 seconds to appear; before that it showed `<unknown>` while the HPA waited for its first metrics.

**50% means 50% of the request**, which is 100m. So the HPA scales up when average CPU passes **50m**, not half a core.

---

## Task 5: Load and autoscaling

```
devops@testvm:~/day-58$ kubectl run load-generator -n devboard-dev --rm -it \
    --image=busybox:1.36 --restart=Never -- \
    /bin/sh -c "while sleep 0.01; do wget -q -O- http://php-apache; done"
```

In another terminal:

```
devops@testvm:~/day-58$ kubectl get hpa php-apache -n devboard-dev -w
NAME         REFERENCE               TARGETS         MINPODS   MAXPODS   REPLICAS   AGE
php-apache   Deployment/php-apache   cpu: 0%/50%     1         5         1          2m
php-apache   Deployment/php-apache   cpu: 187%/50%   1         5         1          2m15s
php-apache   Deployment/php-apache   cpu: 187%/50%   1         5         4          2m30s
php-apache   Deployment/php-apache   cpu: 92%/50%    1         5         4          2m45s
php-apache   Deployment/php-apache   cpu: 61%/50%    1         5         4          3m
php-apache   Deployment/php-apache   cpu: 47%/50%    1         5         4          3m15s
```

**1 → 4 replicas in about 15 seconds**, and utilisation settled just under the target.

The four is not arbitrary:

```
desired = ceil( current_replicas × (current_metric / target_metric) )
        = ceil( 1 × (187 / 50) )
        = ceil( 3.74 )
        = 4
```

```
devops@testvm:~/day-58$ kubectl get pods -n devboard-dev -l app=php-apache
NAME                          READY   STATUS    RESTARTS   AGE
php-apache-7d9f4c8b2a-4jx2p   1/1     Running   0          1m
php-apache-7d9f4c8b2a-8mnq7   1/1     Running   0          1m
php-apache-7d9f4c8b2a-k7wqz   1/1     Running   0          4m
php-apache-7d9f4c8b2a-p2nvx   1/1     Running   0          1m
```

**And the Service load balances across all four automatically** — new pods match its selector, so they are added to the endpoints as soon as they are ready. That is the piece Docker Compose could not do on Day 34: Compose could start three replicas but had nothing to distribute traffic to them.

### Scaling back down

Stopping the load generator:

```
NAME         REFERENCE               TARGETS      REPLICAS   AGE
php-apache   Deployment/php-apache   cpu: 0%/50%  4          8m
php-apache   Deployment/php-apache   cpu: 0%/50%  4          11m
php-apache   Deployment/php-apache   cpu: 0%/50%  4          12m
php-apache   Deployment/php-apache   cpu: 0%/50%  1          13m
```

**CPU dropped instantly; replicas stayed at 4 for five minutes.**

That is the **stabilisation window** — 300 seconds by default for scaling down, 0 for scaling up. Deliberately asymmetric: scaling up late means dropped requests, scaling down early means thrashing. Traffic that dips for thirty seconds should not trigger a scale-down followed immediately by a scale-up.

```
devops@testvm:~/day-58$ kubectl describe hpa php-apache -n devboard-dev | grep -A5 Events
Events:
  Type    Reason             Age    From                       Message
  Normal  SuccessfulRescale  11m    horizontal-pod-autoscaler  New size: 4; reason: cpu resource utilization above target
  Normal  SuccessfulRescale  1m     horizontal-pod-autoscaler  New size: 1; reason: All metrics below target
```

---

## Task 6: An HPA from YAML

**`manifests/hpa.yaml`**

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: devboard-frontend-hpa
  namespace: devboard-dev
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: devboard-frontend
  minReplicas: 1
  maxReplicas: 5
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 50
  behavior:
    scaleUp:
      stabilizationWindowSeconds: 0
    scaleDown:
      stabilizationWindowSeconds: 300
```

**`autoscaling/v2`, not `v1`.** v1 supports only CPU. v2 adds memory, multiple metrics, custom metrics and the `behavior` block. Plenty of older examples still show v1.

```
devops@testvm:~/day-58$ kubectl apply -f manifests/hpa.yaml
horizontalpodautoscaler.autoscaling/devboard-frontend-hpa created

devops@testvm:~/day-58$ kubectl get hpa -n devboard-dev
NAME                    REFERENCE                      TARGETS       MINPODS   MAXPODS   REPLICAS
devboard-frontend-hpa   Deployment/devboard-frontend   cpu: 1%/50%   1         5         3
```

Several metrics can be combined, and **the highest wins**:

```yaml
  metrics:
    - type: Resource
      resource:
        name: cpu
        target: {type: Utilization, averageUtilization: 50}
    - type: Resource
      resource:
        name: memory
        target: {type: Utilization, averageUtilization: 70}
```

### The conflict with `replicas:`

Something worth being explicit about. The Deployment manifest says `replicas: 3` and the HPA now owns that field. Re-applying the manifest sets it back to 3, and the HPA changes it again a few seconds later — a slow fight between git and the controller.

**Once a Deployment has an HPA, remove `replicas:` from its manifest.** Otherwise every `kubectl apply` or GitOps sync briefly resets the replica count, which in production means dropping capacity under load. This is the Day 52 imperative/declarative divergence, in a form that bites automatically.

### HPA, VPA and Cluster Autoscaler

| | Changes | Use for |
|---|---|---|
| **HPA** | Number of pods | Stateless apps under variable load |
| **VPA** | Requests/limits of existing pods | Right-sizing a single-instance workload |
| **Cluster Autoscaler** | Number of nodes | When pods are Pending because the cluster is full |

They compose: an HPA adds pods, and when there is nowhere to put them the Cluster Autoscaler adds nodes. **HPA and VPA should not both manage CPU on the same workload** — they fight, since the VPA changes the request that the HPA measures against.

---

## Task 7: Cleanup

```
devops@testvm:~/day-58$ kubectl delete hpa php-apache devboard-frontend-hpa -n devboard-dev
devops@testvm:~/day-58$ kubectl delete deployment php-apache -n devboard-dev
devops@testvm:~/day-58$ kubectl delete svc php-apache -n devboard-dev
```

Left the Metrics Server installed — Day 60 uses it.

---

## Files in this folder

| Path | What it is |
|---|---|
| `manifests/hpa.yaml` | `autoscaling/v2` HPA with an explicit `behavior` block |

---

## What I learned

**1. HPA utilisation is a percentage of the request, not of a core.** A 100m request with a 50% target scales at 50m of actual CPU. And with **no request set the HPA never works at all** — it shows `<unknown>` forever, because there is no denominator. That single prerequisite is the most common reason an HPA does nothing.

**2. Scale-up is immediate; scale-down waits five minutes.** The asymmetry is deliberate — being slow to scale up drops requests, being quick to scale down causes thrashing. Watching replicas sit at 4 with 0% CPU for five minutes looked broken until I understood the stabilisation window.

**3. An HPA and a `replicas:` field in git fight each other.** The HPA owns the replica count once it exists, so leaving `replicas:` in the manifest means every apply resets it. Remove the field.

**Two extras:**

- The Metrics Server fails on kind with a TLS error, because kubelet's self-signed certificate has no IP SAN. `--kubelet-insecure-tls` fixes it locally and must not be used on a real cluster.
- Metrics Server is not monitoring — about a minute of data, held in memory, existing to feed the HPA. Prometheus is the one that stores history.
