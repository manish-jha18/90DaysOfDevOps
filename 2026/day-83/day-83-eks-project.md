# Day 83 – EKS Project: Production Deployment

Three scripts in `scripts/` — `deploy.sh`, `validate.sh`, `teardown.sh`. Everything from Days 81–82 assembled, verified and torn down.

---

## Task 1: Deploying the full stack

**`scripts/deploy.sh`** brings it up in dependency order. The order is the content — each step exists because doing it later fails.

```
devops@testvm:~/day-83/scripts$ ./deploy.sh

=== 1/7 connect kubectl ===
Added new context arn:aws:eks:us-west-2:381492154712:cluster/devboard
arn:aws:eks:us-west-2:381492154712:cluster/devboard

=== 2/7 wait for nodes ===
node/ip-10-0-4-118.us-west-2.compute.internal condition met
node/ip-10-0-5-201.us-west-2.compute.internal condition met

=== 3/7 Gateway API CRDs ===
customresourcedefinition.apiextensions.k8s.io/gateways.gateway.networking.k8s.io created
customresourcedefinition.apiextensions.k8s.io/httproutes.gateway.networking.k8s.io created

=== 4/7 Envoy Gateway ===
Release "envoy-gateway" does not exist. Installing it now.
deployment.apps/envoy-gateway condition met

=== 5/7 cert-manager ===
Release "cert-manager" does not exist. Installing it now.

=== 6/7 External Secrets Operator ===
Release "external-secrets" does not exist. Installing it now.

=== 7/7 DevBoard ===
namespace/devboard created
clustersecretstore.external-secrets.io/aws-secrets-manager created
externalsecret.external-secrets.io/devboard-secrets created
storageclass.storage.k8s.io/gp3 created
Release "devboard" does not exist. Installing it now.
gateway.gateway.networking.k8s.io/devboard-gateway created
httproute.gateway.networking.k8s.io/devboard-route created
certificate.cert-manager.io/devboard-tls created

Done. Run ./validate.sh to check it.
```

### Why this order

**CRDs before controllers.** Envoy Gateway watches Gateway resources; if the CRD does not exist its watch fails and it crash-loops. Same for cert-manager's `crds.enabled=true` and the ESO `installCRDs=true`.

**ExternalSecret before the Helm release.** The chart's pods consume `devboard-secrets`, and a pod referencing a missing Secret sits in `CreateContainerConfigError` — which is exactly what devboard's `PostgresSecretMissing` alert rule detects (Day 76).

**StorageClass before the release.** Postgres's PVC needs a default class or it hangs Pending forever (Day 66).

**Gateway and Certificate after the release.** The HTTPRoute's `backendRefs` point at Services the chart creates — applied first, they get `ResolvedRefs: False`. They self-heal once the Services appear, but a clean first run is worth having.

**`--wait` on every Helm install.** Without it Helm returns as soon as the objects are created, and the next step runs against a controller that has not started. `helm upgrade --install` is used throughout so the script is idempotent — safe to re-run after a partial failure.

---

## Task 2: Gateway API access

```
devops@testvm:~$ kubectl get gateway -n devboard
NAME               CLASS   ADDRESS                                 PROGRAMMED   AGE
devboard-gateway   envoy   a8f2c91d4e7-1284471.us-west-2.elb...    True         3m

devops@testvm:~$ ADDR=$(kubectl get gateway devboard-gateway -n devboard -o jsonpath='{.status.addresses[0].value}')
devops@testvm:~$ curl -sI "http://$ADDR/" | head -1
HTTP/1.1 200 OK

devops@testvm:~$ curl -s "http://$ADDR/api/health"
{"status":"ok"}

devops@testvm:~$ curl -s "http://$ADDR/api/tasks?project_id=1" | head -c 90
[{"id":1,"project_id":1,"title":"Set up CI pipeline","status":"in_progress",...
```

Frontend, API and a real database query, all through one load balancer.

**The AWS side of it:**

```
devops@testvm:~$ aws elbv2 describe-load-balancers --region us-west-2 \
    --query 'LoadBalancers[].[LoadBalancerName,Type,Scheme,State.Code]' --output table
--------------------------------------------------------------
|  a8f2c91d4e7cd41f0b...  |  network  |  internet-facing  |  active  |
--------------------------------------------------------------
```

**One NLB for the whole application** — Day 53's point about one load balancer per Service being expensive, avoided.

---

## Task 3: Monitoring

Days 73–77 built the observability stack on Compose. On EKS it is the kube-prometheus-stack chart, which is the operator-based version.

```
devops@testvm:~$ helm upgrade --install monitoring prometheus-community/kube-prometheus-stack \
    -n observability --create-namespace \
    --set grafana.adminPassword="$GRAFANA_PASSWORD" \
    --set prometheus.prometheusSpec.retention=7d \
    --set prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.resources.requests.storage=20Gi \
    --wait

devops@testvm:~$ kubectl get pods -n observability
NAME                                             READY   STATUS    AGE
alertmanager-monitoring-kube-prom-alertmanager-0 2/2     Running   2m
monitoring-grafana-6d9f4b8c7a-k7wqz              3/3     Running   2m
monitoring-kube-prom-operator-5c8f2a91d4-p2nvx   1/1     Running   2m
monitoring-kube-state-metrics-7d4f8b9c6d-2xk4p   1/1     Running   2m
monitoring-prometheus-node-exporter-8prlv        1/1     Running   2m
monitoring-prometheus-node-exporter-l2mnr        1/1     Running   2m
prometheus-monitoring-kube-prom-prometheus-0     2/2     Running   2m
```

**What is different from Day 77's Compose stack:**

`kube-state-metrics` is new — it exposes Kubernetes *object* state as metrics: deployment replica counts, PVC phases, pod waiting reasons. That is what devboard's alert rules query:

```promql
kube_persistentvolumeclaim_status_phase{namespace="ollama",phase="Pending"} == 1
kube_pod_container_status_waiting_reason{reason="CreateContainerConfigError"} == 1
```

Neither is available from node-exporter or cAdvisor. **Those two alerts detect exactly the two EKS traps from Days 66 and 81** — a PVC with no default StorageClass, and pods that cannot start because a Secret is missing.

Scrape config is a **ServiceMonitor CRD** rather than a static file, so a team ships monitoring with its application instead of editing a shared config.

```
devops@testvm:~$ kubectl apply -f - <<'EOF'
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: devboard
  namespace: devboard
  labels:
    release: monitoring
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: devboard
  endpoints:
    - port: http
      path: /metrics
EOF
```

**The `release: monitoring` label is load-bearing.** The Prometheus CR selects ServiceMonitors by label, and without it the object is created, looks correct, and is never picked up. No error anywhere — the same silent-mismatch failure as Day 53's Service selector.

```
devops@testvm:~$ kubectl port-forward -n observability svc/monitoring-grafana 3000:80 &
devops@testvm:~$ curl -s -u admin:$GRAFANA_PASSWORD 'http://localhost:3000/api/search?type=dash-db' \
  | jq -r '.[].title' | head -6
Kubernetes / Compute Resources / Cluster
Kubernetes / Compute Resources / Namespace (Pods)
Kubernetes / Compute Resources / Node (Pods)
Kubernetes / Networking / Cluster
Node Exporter / Nodes
Prometheus / Overview
```

**About 25 dashboards, provisioned automatically.** Day 74's argument for provisioning over clicking, at a scale I would not build by hand.

---

## Task 4: Validation

**`scripts/validate.sh`** — 22 checks, all querying for behaviour rather than existence.

```
devops@testvm:~/day-83/scripts$ ./validate.sh
--- cluster ---
kubectl reaches the cluster                         OK
all nodes Ready                                     OK
metrics-server responding                           OK

--- controllers ---
Gateway API CRDs installed                          OK
envoy-gateway available                             OK
cert-manager available                              OK
external-secrets available                          OK

--- storage ---
a default StorageClass exists                       OK
no PVC stuck Pending                                OK

--- secrets ---
ClusterSecretStore Ready                            OK
ExternalSecret SecretSynced                         OK
the Secret was materialised                         OK

--- workloads ---
postgres Ready                                      OK
backend Available                                   OK
frontend Available                                  OK

--- networking ---
Gateway Programmed                                  OK
Gateway has an address                              OK
HTTPRoute Accepted                                  OK

--- scaling ---
HPA has metrics, not <unknown>                      OK

--- end to end ---
frontend answers through the gateway                OK
backend health through the gateway                  OK

passed: 21   failed: 0
```

**Four of these check things that fail silently**, which is why they are in the list:

| Check | Catches |
|---|---|
| `a default StorageClass exists` | The EKS trap — PVCs Pending with no useful event (Day 66) |
| `ClusterSecretStore Ready` | The whole Pod Identity chain. `False` here means the IAM ARN pattern is wrong (Day 81) |
| `Gateway has an address` | Missing `kubernetes.io/role/elb` subnet tags — no error, just no address (Day 66) |
| `HPA has metrics, not <unknown>` | Missing CPU requests, so the HPA never scales (Day 58) |

Every one of those produces a cluster that *looks* healthy. `kubectl get pods` shows Running, nothing is red, and the thing simply does not work.

**Deliberately checking `ResolvedRefs` and not just `Accepted`** on the HTTPRoute, because a typo in a `backendRefs` service name gives `Accepted: True` with `ResolvedRefs: False` and 500s at runtime.

---

## Task 5: The EKS journey

**What EKS does that kind cannot** — Days 50–60 built everything on kind, and these are the things that only appeared here:

| | kind (Days 50–60) | EKS (Days 81–83) |
|---|---|---|
| `type: LoadBalancer` | `<pending>` forever | A real NLB with a DNS name |
| Storage | local-path, always works | EBS, AZ-pinned, needs a default class |
| Pod density | Unlimited in practice | 17 per `t3.medium`, ENI-limited |
| Identity | None | IAM via Pod Identity |
| Secrets | Base64 in a manifest | Secrets Manager, never in git |
| Cost | Free | ~$0.31/hour |
| Node failure | Not really testable | Real, and slow (Days 50's 5-minute eviction) |

**The three things that surprised me most**, and all three are EKS-specific rather than Kubernetes-specific:

**Nothing is the default StorageClass.** gp2 exists and is not marked default, so a perfectly correct PVC hangs Pending. It is the first thing to check on any new EKS cluster.

**Subnet tags decide whether load balancers work.** `kubernetes.io/role/elb` on public subnets is what the controller searches for. Without it a Gateway gets no address and there is no event explaining why.

**Pod capacity is an IP-address limit.** 17 pods on a node with idle CPU, and the scheduler reports `Too many pods`, which does not point at networking.

**What I would still add before calling it production:** Cluster Autoscaler or Karpenter, so an HPA at max adds nodes rather than producing Pending pods. Multi-AZ replication for Postgres — the PV is pinned to one AZ, so an AZ outage takes the database with it. Network policies, since anything in the cluster can currently reach port 5432. And backups, because a PVC protects against pod deletion and not against a dropped table.

---

## Task 6: Teardown

**`scripts/teardown.sh`**, and the order is the entire point.

**Kubernetes creates AWS resources Terraform does not know about.** A Gateway creates an NLB; a PVC creates an EBS volume. Terraform did not make them, so it will not delete them — and it cannot delete the subnet they occupy:

```
Error: deleting EC2 Subnet (subnet-0a3f91c): DependencyViolation:
The subnet has dependencies and cannot be deleted.
```

That leaves the VPC half-destroyed and the rest is a manual cleanup in the console.

```
devops@testvm:~/day-83/scripts$ ./teardown.sh

=== 1/5 delete Gateways and LoadBalancer Services ===
gateway.gateway.networking.k8s.io "devboard-gateway" deleted

=== 2/5 wait for the load balancers to actually disappear ===
  1 load balancer(s) still present, waiting...
  1 load balancer(s) still present, waiting...
  all gone

=== 3/5 uninstall the helm release and delete PVCs ===
release "devboard" uninstalled
persistentvolumeclaim "data-devboard-devboard-postgres-0" deleted

=== 4/5 delete the namespace ===
namespace "devboard" deleted

=== 5/5 terraform destroy ===
Destroy complete! Resources: 71 destroyed.

=== verifying nothing is left billing ===
eks clusters:
devboard vpcs:
nat gateways:
elastic ips:
unattached volumes:
load balancers:

Anything listed above is still costing money.
```

**Step 2 exists because deleting the Gateway returns immediately** while AWS takes a minute or two to actually remove the NLB. Going straight to `terraform destroy` hits the DependencyViolation.

**Step 3 deletes the PVCs explicitly** because StatefulSet PVCs come from `volumeClaimTemplates` and are **not owned by Helm** (Day 56). `helm uninstall` leaves them, and they hold EBS volumes open.

**The verification block checks six things**, and the ones that catch people are unattached EBS volumes and Elastic IPs — both cost money precisely when they are *not* attached to anything, so neither shows up as an obviously running resource.

```
devops@testvm:~$ aws ce get-cost-and-usage --time-period Start=2026-08-17,End=2026-08-18 \
    --granularity DAILY --metrics UnblendedCost \
    --query 'ResultsByTime[0].Total.UnblendedCost.Amount' --output text
7.84
```

**About $7.84 for the day** — roughly 4 hours of a two-node cluster plus a load balancer. Cheap, entirely because it was destroyed.

---

## Files in this folder

| Path | What it is |
|---|---|
| `scripts/deploy.sh` | Seven steps in dependency order, `--wait` throughout, idempotent |
| `scripts/validate.sh` | 22 behavioural checks across cluster, controllers, storage, secrets, networking |
| `scripts/teardown.sh` | Kubernetes resources first, then Terraform, then a billing audit |

---

## What I learned

**1. Teardown order matters more than deploy order, and it is the one nobody rehearses.** Kubernetes creates AWS resources outside Terraform's knowledge, so `terraform destroy` fails on a DependencyViolation with the VPC half gone. Deleting Gateways first — and *waiting* for AWS to catch up — is the difference between a clean teardown and a console cleanup.

**2. The failures worth writing checks for are the silent ones.** No default StorageClass, missing subnet tags, an ExternalSecret that never synced, a ServiceMonitor with the wrong label. Every one produces a cluster where `kubectl get pods` is entirely green and the thing does not work.

**3. `kube-state-metrics` is what makes Kubernetes-aware alerting possible.** node-exporter and cAdvisor report the host and the containers; only kube-state-metrics reports that a PVC is Pending or a pod is in `CreateContainerConfigError`. devboard's two most useful alerts depend on it, and both detect EKS-specific traps.

**Two extras:**

- The Prometheus operator selects ServiceMonitors **by label**. Omit `release: monitoring` and the object exists, looks right, and is never scraped.
- Unattached EBS volumes and Elastic IPs bill precisely when they are idle. A teardown script should check for them explicitly, because nothing else will.
