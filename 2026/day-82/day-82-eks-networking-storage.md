# Day 82 – EKS Networking with Gateway API and Persistent Storage

Manifests in `manifests/` in this folder.

---

## Task 1: Gateway API vs Ingress

Day 53 used Services; Day 79's chart used an Ingress. Gateway API is the replacement for Ingress, and it exists because Ingress has three problems that could not be fixed compatibly.

**Ingress is one object owned by everyone.** The hostname, TLS config, path rules and controller behaviour all live in a single resource, so a platform team and an app team edit the same object. There is no way to say "you may add routes, but you may not change the TLS certificate".

**Everything beyond basic path routing is an annotation.** Timeouts, rewrites, retries, canary weights — all vendor-specific strings, and none of them portable. An Ingress written for nginx does not work on Traefik.

**No cross-namespace control.** Any Ingress in any namespace can claim any hostname.

**Gateway API splits one object into three, along ownership lines:**

```
GatewayClass   cluster-scoped    "envoy implements gateways here"
                                  ← infrastructure provider
     │
  Gateway      namespaced        listeners, ports, TLS, who may attach
                                  ← platform team
     │
 HTTPRoute     namespaced        paths, rewrites, timeouts, backends
                                  ← application team
```

The app team writes HTTPRoutes and cannot touch the certificate or open a new port. The platform team owns the Gateway and controls which namespaces may attach:

```yaml
      allowedRoutes:
        namespaces:
          from: Same
```

`Same`, `All`, or a label selector. **That single field is what Ingress never had.**

| | Ingress | Gateway API |
|---|---|---|
| Objects | 1 | 3, split by role |
| Rewrites, timeouts | Vendor annotations | Typed fields in the spec |
| Cross-namespace | Uncontrolled | `allowedRoutes` |
| Portable across controllers | Barely | Yes, it is a conformance spec |
| Protocols | HTTP(S) | HTTP, TCP, UDP, TLS, gRPC |

**The CRDs are not part of Kubernetes.** They install separately, before any controller that implements them — which is step 3 of Day 83's deploy script, and getting the order wrong crash-loops the controller.

---

## Task 2: Envoy Gateway

```
devops@testvm:~$ kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.1.0/standard-install.yaml
customresourcedefinition.apiextensions.k8s.io/gatewayclasses.gateway.networking.k8s.io created
customresourcedefinition.apiextensions.k8s.io/gateways.gateway.networking.k8s.io created
customresourcedefinition.apiextensions.k8s.io/httproutes.gateway.networking.k8s.io created
...

devops@testvm:~$ helm upgrade --install envoy-gateway oci://docker.io/envoyproxy/gateway-helm \
    --version v1.1.2 -n envoy-gateway-system --create-namespace --wait

devops@testvm:~$ kubectl get pods -n envoy-gateway-system
NAME                             READY   STATUS    RESTARTS   AGE
envoy-gateway-5c8f2a91d4-p2nvx   1/1     Running   0          64s
```

**`standard-install.yaml` versus `experimental-install.yaml`** — standard has GatewayClass, Gateway and HTTPRoute at v1 (stable). Experimental adds TCPRoute, UDPRoute and TLSRoute, still v1alpha2. Start with standard.

**`manifests/gateway/gatewayclass.yaml`**

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: envoy
spec:
  controllerName: gateway.envoyproxy.io/gatewayclass-controller
```

```
devops@testvm:~$ kubectl get gatewayclass
NAME    CONTROLLER                                      ACCEPTED   AGE
envoy   gateway.envoyproxy.io/gatewayclass-controller   True       12s
```

**`ACCEPTED: True`** means a controller claimed it. `False` or blank means the `controllerName` does not match any installed controller — a typo there produces a Gateway that sits Unknown forever with no other error.

---

## Task 3: Deploying with Gateway API

**`manifests/gateway/gateway.yaml`**

```yaml
spec:
  gatewayClassName: envoy
  listeners:
    - name: http
      protocol: HTTP
      port: 80
      allowedRoutes:
        namespaces:
          from: Same

    - name: https
      protocol: HTTPS
      port: 443
      hostname: devboard.example.com
      tls:
        mode: Terminate
        certificateRefs:
          - kind: Secret
            name: devboard-tls
      allowedRoutes:
        namespaces:
          from: Same
```

```
devops@testvm:~$ kubectl apply -f manifests/gateway/gateway.yaml
devops@testvm:~$ kubectl get gateway -n devboard
NAME               CLASS   ADDRESS                                    PROGRAMMED   AGE
devboard-gateway   envoy   a8f2c91d4e7-1284471.us-west-2.elb...       True         92s
```

**`PROGRAMMED: True` and an address.** Envoy Gateway created a Service of type LoadBalancer behind the scenes, and AWS provisioned an NLB — found via the `kubernetes.io/role/elb` subnet tags from Day 66. **Those tags are the reason this works**, and without them the address stays empty with no useful event.

```
devops@testvm:~$ kubectl get svc -n envoy-gateway-system
NAME                              TYPE           EXTERNAL-IP                       PORT(S)
envoy-devboard-devboard-gateway   LoadBalancer   a8f2c91d4e7-1284471.us-west-2...  80:31447/TCP,443:32109/TCP
```

**One load balancer serves every route attached to this Gateway** — the Ingress cost problem from Day 53, solved by design.

### The HTTPRoute, and the security incident in it

**`manifests/gateway/httproute.yaml`**

```yaml
  rules:
    # ---------------------------------------------------------------
    # Exact, NOT PathPrefix.
    #
    # A PathPrefix on /api/ai once exposed /api/ai/metrics to the
    # internet, because the prefix matched every path under it including
    # ones nobody meant to publish.
    # ---------------------------------------------------------------
    - matches:
        - path:
            type: Exact
            value: /api/ai/summarise
      filters:
        - type: URLRewrite
          urlRewrite:
            path:
              type: ReplaceFullPath
              replaceFullPath: /summarise
      timeouts:
        request: "300s"
        backendRequest: "300s"
      backendRefs:
        - name: ai-service
          port: 3005
```

**This comment is from devboard's own manifests and it is the most useful thing in the file.** A `PathPrefix: /api/ai` looks obviously correct and quietly publishes every endpoint the service will ever have — including a `/metrics` endpoint added later by someone who assumed it was internal.

**`Exact` inverts the default.** New endpoints are private until explicitly listed. The cost is one rule per endpoint; the benefit is that forgetting to add a rule fails closed.

Day 49's least-privilege principle, applied to routing. And exactly the reasoning behind Day 47's `paths:` allow-list versus `paths-ignore:` deny-list — allow-list when the set is small and known.

**`timeouts: 300s`** because LLM generation is slow and the Envoy default of 15s cuts it off mid-response. A typed field in the spec, not a vendor annotation — which is Gateway API's whole argument.

**`URLRewrite` with `ReplaceFullPath`** strips the public prefix, so `/api/ai/summarise` reaches the service as `/summarise`. Same job as Day 72's nginx trailing slash, expressed as a typed field rather than a character everyone forgets.

```
devops@testvm:~$ kubectl get httproute -n devboard
NAME             HOSTNAMES                    AGE
devboard-route   ["devboard.example.com"]     30s

devops@testvm:~$ kubectl get httproute devboard-route -n devboard \
    -o jsonpath='{.status.parents[0].conditions[*].type}{"\n"}{.status.parents[0].conditions[*].status}'
Accepted ResolvedRefs
True True
```

**Two conditions, both needed.** `Accepted` means the Gateway took the route. `ResolvedRefs` means every `backendRefs` Service actually exists — a typo in a service name gives `Accepted: True` and `ResolvedRefs: False`, and requests return 500. That second condition is the one to check when a route is attached and still not working.

---

## Task 4: TLS with cert-manager

```
devops@testvm:~$ helm upgrade --install cert-manager jetstack/cert-manager \
    --version v1.16.1 -n cert-manager --create-namespace \
    --set crds.enabled=true \
    --set config.enableGatewayAPI=true --wait
```

**`enableGatewayAPI=true` is off by default** and is required. Without it the http01 solver cannot create the HTTPRoute it needs, and every Certificate stays Pending with an unhelpful event.

**`manifests/cert-manager/clusterissuers.yaml`**

```yaml
# Staging FIRST. Let's Encrypt production allows only 5 authorisation
# FAILURES per hostname per hour.
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-staging
spec:
  acme:
    server: https://acme-staging-v02.api.letsencrypt.org/directory
    email: manishkumar181999@gmail.com
    privateKeySecretRef:
      name: letsencrypt-staging-account-key
    solvers:
      - http01:
          gatewayHTTPRoute:
            parentRefs:
              - kind: Gateway
                name: devboard-gateway
                namespace: devboard
```

**Use staging first, always.** Production Let's Encrypt allows **5 authorisation failures per hostname per hour**, and getting DNS or the solver wrong twice while iterating locks you out for the rest of the hour. Staging has generous limits and issues an untrusted certificate — which proves the plumbing without spending quota.

**Two details from devboard's version, both non-obvious:**

**The solver creates its HTTPRoute in the *Certificate's* namespace.** So the Certificate must live in a namespace the Gateway accepts routes from. With `allowedRoutes: from: Same`, that means the Certificate has to be in `devboard`. Put it in `cert-manager` and the Gateway silently rejects the solver route and the challenge times out.

**No `sectionName` on the parentRef**, deliberately. Omitting it attaches the solver route to **both** the `:80` and `:443` listeners, so a renewal works whichever one is reachable. Pinning it to `http` breaks renewal once the HTTPS redirect is in place.

```
devops@testvm:~$ kubectl apply -f manifests/cert-manager/
devops@testvm:~$ kubectl get certificate -n devboard
NAME           READY   SECRET         AGE
devboard-tls   False   devboard-tls   15s

devops@testvm:~$ kubectl get certificaterequest,order,challenge -n devboard
NAME                                        APPROVED   READY   AGE
certificaterequest.../devboard-tls-1        True       False   18s
NAME                             STATE     AGE
order.acme.../devboard-tls-1-2   pending   18s
NAME                                 STATE     DOMAIN                  AGE
challenge.acme.../devboard-tls-1-2   pending   devboard.example.com    17s
```

**The chain is Certificate → CertificateRequest → Order → Challenge**, and debugging means walking down it. `kubectl describe challenge` is where the actual error lives — everything above it just says "not ready".

```
devops@testvm:~$ kubectl get certificate -n devboard
NAME           READY   SECRET         AGE
devboard-tls   True    devboard-tls   94s
```

**`manifests/gateway/httproute-redirect.yaml`**

```yaml
spec:
  parentRefs:
    - name: devboard-gateway
      sectionName: http
  rules:
    - filters:
        - type: RequestRedirect
          requestRedirect:
            scheme: https
            statusCode: 301
```

**`sectionName: http` here, unlike the solver.** This route must attach to the `:80` listener only — attaching it to `:443` as well would redirect HTTPS to HTTPS, which is an infinite loop.

A rule with a filter and **no `backendRefs`** is legal: the redirect is terminal, so there is nothing to proxy to.

---

## Task 5: EBS storage

Day 66 established that **EKS ships gp2 and marks nothing default**, so a PVC with no explicit class hangs Pending forever. `manifests/storage/storageclass.yaml` fixes it:

```yaml
metadata:
  name: gp3
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: ebs.csi.aws.com
allowVolumeExpansion: true
volumeBindingMode: WaitForFirstConsumer
parameters:
  type: gp3
  encrypted: "true"
```

**`gp3` over `gp2`** — about 20% cheaper, and baseline IOPS and throughput are configurable independently of size. On gp2 the only way to get more IOPS is a bigger volume.

**`WaitForFirstConsumer` is the field that matters on a multi-AZ cluster.** An EBS volume lives in one AZ and can only attach to a node in that AZ. With `Immediate` binding the volume is created as soon as the PVC exists, in an arbitrary AZ — and if the pod is later scheduled elsewhere it can never attach:

```
Warning  FailedScheduling  0/2 nodes are available: 2 node(s) had volume node affinity conflict.
```

`WaitForFirstConsumer` schedules the pod first, then creates the volume in that node's AZ. Day 55 explained the mechanism; this is where getting it wrong actually bites.

**`allowVolumeExpansion: true`** because you cannot add it later without recreating the StorageClass. Costs nothing now, saves a migration later.

**`encrypted: "true"`** — quoted, because Day 38's rule applies and StorageClass parameters are all strings.

```
devops@testvm:~$ kubectl apply -f manifests/storage/
devops@testvm:~$ kubectl get sc
NAME            PROVISIONER             RECLAIMPOLICY   VOLUMEBINDINGMODE      ALLOWVOLUMEEXPANSION
gp2             kubernetes.io/aws-ebs   Delete          WaitForFirstConsumer   false
gp3 (default)   ebs.csi.aws.com         Delete          WaitForFirstConsumer   true

devops@testvm:~$ kubectl get pvc -n devboard
NAME                                     STATUS   VOLUME        CAPACITY   STORAGECLASS
data-devboard-devboard-postgres-0        Bound    pvc-8a3f91c   50Gi       gp3
```

```
devops@testvm:~$ kubectl get pv pvc-8a3f91c -o jsonpath='{.spec.nodeAffinity}' | jq -c
{"required":{"nodeSelectorTerms":[{"matchExpressions":[{"key":"topology.ebs.csi.aws.com/zone","operator":"In","values":["us-west-2a"]}]}]}}
```

**The PV carries node affinity pinning it to `us-west-2a`.** That is `WaitForFirstConsumer`'s output, and it is also the constraint: this Postgres pod can only ever run in that AZ. An AZ outage means it cannot be rescheduled. Genuine HA needs replication, not a rescheduled pod — Day 56's point that a StatefulSet gives identity, not replication.

**Expanding a volume in place:**

```
devops@testvm:~$ kubectl patch pvc data-devboard-devboard-postgres-0 -n devboard \
    -p '{"spec":{"resources":{"requests":{"storage":"60Gi"}}}}'
devops@testvm:~$ kubectl get pvc -n devboard
NAME                                STATUS   CAPACITY
data-devboard-devboard-postgres-0   Bound    60Gi
```

No downtime. **And it only goes one way** — EBS volumes cannot shrink, so over-provisioning is permanent.

---

## Task 6: HPA and node capacity

```
devops@testvm:~$ kubectl get hpa -n devboard
NAME                         REFERENCE                     TARGETS       MINPODS   MAXPODS   REPLICAS
devboard-devboard-frontend   Deployment/...-frontend       cpu: 3%/60%   3         10        3
```

`cpu: 3%/60%` rather than `<unknown>`, because the managed metrics-server addon is present and the deployment has CPU requests (Day 58's prerequisite).

**The capacity limit that is specific to EKS:**

```
devops@testvm:~$ kubectl get nodes -o custom-columns=NAME:.metadata.name,PODS:.status.allocatable.pods
NAME                                       PODS
ip-10-0-4-118.us-west-2.compute.internal   17
ip-10-0-5-201.us-west-2.compute.internal   17
```

**17 pods per node, on a `t3.medium` with 2 vCPU and 4 GiB.** That is not a CPU or memory limit — it is the VPC CNI. Each pod gets a real VPC IP from an ENI, and a `t3.medium` supports 3 ENIs × 6 IPs, minus one, which is 17.

```
devops@testvm:~$ kubectl get pods -A --no-headers | wc -l
23
```

23 pods across 34 slots, and 7 of those are DaemonSets. **Scaling the HPA to 10 frontend replicas plus everything else would hit the IP limit before it hit CPU** — and the failure is `Pending` with `too many pods`, which reads like a resource shortage rather than an addressing one.

Ways round it: a larger instance type, or enabling **prefix delegation** on the VPC CNI (`ENABLE_PREFIX_DELEGATION=true`), which assigns /28 blocks instead of individual IPs and raises a `t3.medium` to 110 pods.

**Node scaling** is the other half. The HPA adds pods; when there is nowhere to put them, something has to add nodes — Cluster Autoscaler or Karpenter. Without one, an HPA at max just produces Pending pods:

```
devops@testvm:~$ kubectl get pods -n devboard --field-selector status.phase=Pending
NAME                              READY   STATUS    AGE
devboard-devboard-frontend-x9k2   0/1     Pending   45s

devops@testvm:~$ kubectl describe pod devboard-devboard-frontend-x9k2 -n devboard | tail -2
  Warning  FailedScheduling  40s  default-scheduler  0/2 nodes are available: 2 Too many pods.
```

Day 58's HPA/VPA/Cluster Autoscaler table, met in practice.

---

## Files in this folder

| Path | What it is |
|---|---|
| `manifests/gateway/gatewayclass.yaml` | Binds the `envoy` class to its controller |
| `manifests/gateway/gateway.yaml` | HTTP and HTTPS listeners, `allowedRoutes: Same` |
| `manifests/gateway/httproute.yaml` | Exact matches, rewrites, 300s timeouts |
| `manifests/gateway/httproute-redirect.yaml` | HTTP→HTTPS, pinned to the `:80` listener |
| `manifests/cert-manager/clusterissuers.yaml` | Staging and prod, Gateway API solver |
| `manifests/cert-manager/certificate.yaml` | In the devboard namespace, for the solver's sake |
| `manifests/external-secrets/` | ClusterSecretStore and ExternalSecret |
| `manifests/storage/storageclass.yaml` | Default gp3, encrypted, expandable, WaitForFirstConsumer |

---

## What I learned

**1. `PathPrefix` on an API namespace publishes endpoints you have not written yet.** devboard's comment records a real incident — a prefix on `/api/ai` exposed `/api/ai/metrics` to the internet. `Exact` matches mean a new internal endpoint is private by default, at the cost of one rule each. Fail closed.

**2. The http01 solver creates its HTTPRoute in the Certificate's namespace.** So with `allowedRoutes: from: Same`, the Certificate must live where the Gateway is or the challenge silently times out. And omitting `sectionName` on the solver's parentRef is deliberate — it attaches to both listeners so renewals survive the HTTPS redirect.

**3. Pod density on EKS is limited by IP addresses, not CPU.** A `t3.medium` caps at 17 pods because of ENI limits in the VPC CNI. An HPA can hit that ceiling with plenty of CPU free, and the error says `Too many pods`, which does not point at networking at all.

**Two extras:**

- `WaitForFirstConsumer` is not optional on a multi-AZ cluster. `Immediate` binding puts the EBS volume in an arbitrary AZ and the pod gets `volume node affinity conflict` forever.
- `allowVolumeExpansion: true` cannot be added to an existing StorageClass in a useful way. Set it at creation; EBS volumes grow in place and never shrink.
