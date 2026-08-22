# Day 53 – Kubernetes Services

Three service manifests in `manifests/` in this folder.

---

## Why Services exist

Day 52 showed pod IPs changing constantly — delete a pod and the replacement gets a different address. So nothing can hardcode a pod IP.

A Service is a **stable name and virtual IP in front of a changing set of pods**, selected by label. It is the same problem Day 32 solved with Docker's custom-network DNS, except Kubernetes also has to handle the set of backends changing underneath.

---

## Task 1: The application

```
devops@testvm:~/day-53$ kubectl apply -f ../day-52/manifests/frontend-deployment.yaml
deployment.apps/devboard-frontend created

devops@testvm:~/day-53$ kubectl get pods -n devboard-dev -o wide
NAME                                 READY   STATUS    AGE   IP            NODE
devboard-frontend-7d4f8b9c6d-2xk4p   1/1     Running   22s   10.244.1.7    devops-cluster-worker
devboard-frontend-7d4f8b9c6d-8mnq7   1/1     Running   22s   10.244.2.4    devops-cluster-worker2
devboard-frontend-7d4f8b9c6d-vz9lt   1/1     Running   22s   10.244.1.8    devops-cluster-worker
```

Three pods, three IPs, two nodes.

---

## Task 2: ClusterIP

**`manifests/clusterip-service.yaml`**

```yaml
apiVersion: v1
kind: Service
metadata:
  name: devboard-frontend-clusterip
  namespace: devboard-dev
spec:
  type: ClusterIP
  selector:
    app: devboard-frontend
  ports:
    - protocol: TCP
      port: 80
      targetPort: 4173
```

```
devops@testvm:~/day-53$ kubectl apply -f manifests/clusterip-service.yaml
service/devboard-frontend-clusterip created

devops@testvm:~/day-53$ kubectl get svc -n devboard-dev
NAME                          TYPE        CLUSTER-IP      EXTERNAL-IP   PORT(S)   AGE
devboard-frontend-clusterip   ClusterIP   10.96.184.201   <none>        80/TCP    9s
```

**`port` versus `targetPort`** is the pair to get right. `port: 80` is what the Service listens on; `targetPort: 4173` is the container's port. They are independent — clients use 80, pods serve 4173.

### The endpoints are the real check

```
devops@testvm:~/day-53$ kubectl get endpoints devboard-frontend-clusterip -n devboard-dev
NAME                          ENDPOINTS                                        AGE
devboard-frontend-clusterip   10.244.1.7:4173,10.244.1.8:4173,10.244.2.4:4173  40s
```

Three endpoints, matching the three pod IPs. **This is the first thing to check when a Service does not work** — a Service with no endpoints means the selector matches nothing:

```
devops@testvm:~/day-53$ kubectl get endpoints broken-service -n devboard-dev
NAME             ENDPOINTS   AGE
broken-service   <none>      5s
```

`<none>` and no error anywhere. The Service exists, has a ClusterIP, and routes to nothing. A label typo produces exactly this, which is Day 51's point about labels being functional.

### Testing from inside

```
devops@testvm:~/day-53$ kubectl run tester -n devboard-dev --rm -it \
    --image=busybox:1.36 --restart=Never -- sh

/ # wget -qO- http://devboard-frontend-clusterip | head -3
<!doctype html>
<html lang="en">
  <head>

/ # for i in 1 2 3 4 5 6; do wget -qO- http://devboard-frontend-clusterip/ >/dev/null && echo "req $i ok"; done
req 1 ok
req 2 ok
req 3 ok
req 4 ok
req 5 ok
req 6 ok
```

Reached by **name**, and load balanced across all three pods.

`--rm -it --restart=Never` gives a throwaway debug pod that deletes itself on exit — the Kubernetes equivalent of `docker run --rm -it`.

**From outside the cluster it is unreachable**, which is the definition of ClusterIP:

```
devops@testvm:~$ curl --max-time 3 http://10.96.184.201
curl: (28) Connection timed out after 3001 milliseconds
```

That address only exists inside the cluster network. It is not even a real interface anywhere — kube-proxy programs iptables rules that rewrite traffic destined for it to one of the endpoint IPs.

---

## Task 3: DNS

```
/ # nslookup devboard-frontend-clusterip
Server:    10.96.0.10
Address:   10.96.0.10:53

Name:      devboard-frontend-clusterip.devboard-dev.svc.cluster.local
Address:   10.96.184.201

/ # cat /etc/resolv.conf
search devboard-dev.svc.cluster.local svc.cluster.local cluster.local
nameserver 10.96.0.10
options ndots:5
```

The resolver is CoreDNS at `10.96.0.10`, one of the `kube-system` pods from Day 50.

**The full name is `<service>.<namespace>.svc.cluster.local`.** The `search` list is why a short name works: a pod in `devboard-dev` looking up `devboard-frontend-clusterip` gets `devboard-dev.svc.cluster.local` appended automatically.

Which means the short name only works **within the same namespace**:

```
/ # nslookup devboard-frontend-clusterip.devboard-dev.svc.cluster.local
Address: 10.96.184.201

/ # nslookup postgres
** server can't find postgres: NXDOMAIN
```

Cross-namespace needs at least `<service>.<namespace>`. This is the practical reason a config value should be `postgres.devboard-dev` rather than bare `postgres` when anything might move.

`ndots:5` means any name with fewer than five dots gets the search list applied first. It is also a known performance quirk — `api.github.com` has two dots, so it tries four cluster-internal names and fails before trying the real one. Fully-qualifying external names with a trailing dot avoids it.

---

## Task 4: NodePort

**`manifests/nodeport-service.yaml`**

```yaml
spec:
  type: NodePort
  selector:
    app: devboard-frontend
  ports:
    - protocol: TCP
      port: 80
      targetPort: 4173
      nodePort: 30080
```

```
devops@testvm:~/day-53$ kubectl get svc -n devboard-dev
NAME                          TYPE        CLUSTER-IP      EXTERNAL-IP   PORT(S)        AGE
devboard-frontend-clusterip   ClusterIP   10.96.184.201   <none>        80/TCP         6m
devboard-frontend-nodeport    NodePort    10.96.72.118    <none>        80:30080/TCP   11s
```

`80:30080/TCP` — port 80 inside, 30080 on every node.

```
devops@testvm:~$ curl -s http://localhost:30080 | head -3
<!doctype html>
<html lang="en">
  <head>
```

Reachable from the host, because of the `extraPortMappings` in the Day 50 kind config. Without that, kind's nodes are Docker containers on their own network and 30080 is not published to the host.

**Every node listens on the nodePort, including nodes with no pod on them:**

```
devops@testvm:~$ docker exec devops-cluster-worker2 curl -s -o /dev/null -w "%{http_code}\n" http://localhost:30080
200
devops@testvm:~$ docker exec devops-cluster-control-plane curl -s -o /dev/null -w "%{http_code}\n" http://localhost:30080
200
```

The control plane runs none of these pods and still answers — kube-proxy forwards to a node that does. That is why a NodePort works behind a simple round-robin load balancer pointed at any node.

**A NodePort is also a ClusterIP.** It has a CLUSTER-IP of its own, and the internal name still resolves. NodePort is ClusterIP plus a node-level port; LoadBalancer is NodePort plus an external IP. Each type layers on the previous one.

The port range is **30000–32767**. Omitting `nodePort:` gets a random one from that range, which is usually better — a hardcoded port is one more thing that can collide.

---

## Task 5: LoadBalancer

**`manifests/loadbalancer-service.yaml`**

```yaml
spec:
  type: LoadBalancer
  selector:
    app: devboard-frontend
  ports:
    - protocol: TCP
      port: 80
      targetPort: 4173
```

```
devops@testvm:~/day-53$ kubectl get svc devboard-frontend-lb -n devboard-dev
NAME                   TYPE           CLUSTER-IP     EXTERNAL-IP   PORT(S)        AGE
devboard-frontend-lb   LoadBalancer   10.96.31.204   <pending>     80:31447/TCP   2m
```

**`EXTERNAL-IP` stuck at `<pending>`, permanently.** Not a bug.

`type: LoadBalancer` asks the **cloud provider** to provision a real load balancer. On EKS that creates an AWS NLB, on GKE a Google load balancer. kind has no cloud provider, so nothing answers the request and it waits forever.

The rest of it still works — note it was allocated node port 31447, because a LoadBalancer is a NodePort underneath.

```
devops@testvm:~$ curl -s -o /dev/null -w "%{http_code}\n" http://localhost:31447
200
```

On a real cloud this is the normal way to expose a service, and the cost is worth knowing: **one load balancer per Service**. Ten services means ten load balancers and ten bills. That is the argument for an **Ingress** — one load balancer, routing by hostname and path to many services.

MetalLB can provide LoadBalancer support on bare metal or kind, if the `<pending>` matters locally.

---

## Task 6: The types side by side

| | ClusterIP | NodePort | LoadBalancer |
|---|---|---|---|
| Reachable from inside the cluster | Yes | Yes | Yes |
| Reachable from outside | No | Yes, via `<node-ip>:<30000-32767>` | Yes, via a real external IP |
| Gets a cluster IP | Yes | Yes | Yes |
| Opens a port on every node | No | Yes | Yes |
| Needs a cloud provider | No | No | **Yes** |
| Cost | Free | Free | One cloud load balancer, billed |
| Typical use | Internal services — databases, backends | Local dev, on-prem behind your own LB | Public-facing services on a cloud |

```
     ClusterIP  ⊂  NodePort  ⊂  LoadBalancer

   internal only   + node port   + external IP
```

Each type is a superset of the previous one.

**What I would actually use:**

- **ClusterIP** for everything internal. DevBoard's Postgres and backend should never be reachable from outside; the frontend calls the backend by name.
- **NodePort** for local development, or on-prem where an external load balancer already exists.
- **LoadBalancer** for one entry point per cluster, usually an **Ingress controller** rather than the application itself. Then Ingress rules route `app.example.com` and `api.example.com` through that single load balancer.

DevBoard's own manifests use NodePort 30080 for the frontend and plain ClusterIP for the backend — correct for a local cluster, and the frontend would become an Ingress on a real one.

---

## Task 7: Cleanup

```
devops@testvm:~/day-53$ kubectl delete -f manifests/
service "devboard-frontend-clusterip" deleted
service "devboard-frontend-lb" deleted
service "devboard-frontend-nodeport" deleted
```

Left the Deployment running for Day 54.

---

## Files in this folder

| Path | Type |
|---|---|
| `manifests/clusterip-service.yaml` | Internal only |
| `manifests/nodeport-service.yaml` | Fixed nodePort 30080 |
| `manifests/loadbalancer-service.yaml` | Stays `<pending>` without a cloud provider |

---

## What I learned

**1. Check endpoints before anything else when a Service does not work.** `kubectl get endpoints` showing `<none>` means the selector matches no pods, and there is no error message anywhere else. The Service will happily exist with a ClusterIP and route to nothing.

**2. The three types are nested, not alternatives.** NodePort is a ClusterIP with a node port added; LoadBalancer is a NodePort with an external IP added. Seeing the LoadBalancer service get node port 31447 while its EXTERNAL-IP stayed pending made that concrete.

**3. Short DNS names only work inside the same namespace.** The `search` path in `/etc/resolv.conf` appends the pod's own namespace. Cross-namespace needs `<service>.<namespace>`, which is worth defaulting to in config values.

**Two extras:**

- `type: LoadBalancer` sitting at `<pending>` on a local cluster is expected — there is no cloud provider to satisfy the request.
- One LoadBalancer per Service gets expensive fast, which is the practical reason Ingress exists.
