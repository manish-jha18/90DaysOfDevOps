# Day 50 – Kubernetes Architecture and Cluster Setup

---

## Task 1: The Kubernetes story

Written from memory first, then checked.

**Why it exists.** Docker solves running one container on one machine. It does not answer what happens when that machine dies, when you need forty copies of a container spread across ten servers, or when you want to replace a running version with no downtime. Day 34 hit this exactly — `docker compose up --scale web=3` failed with "port is already allocated", and even with the port removed there was nothing to load balance across the replicas. Compose can start containers; it cannot keep a desired state true across a fleet.

Kubernetes is a **control loop**. You declare what you want — three replicas of this image — and it continuously works to make reality match, restarting what dies and rescheduling what a failed node was running.

**Who made it.** Google, open-sourced in 2014. It grew out of **Borg**, their internal cluster manager, which had been running Google's workloads for about a decade. It is now maintained by the CNCF.

**The name.** Greek — κυβερνήτης, *kubernetes*, meaning **helmsman** or pilot. The ship's-wheel logo follows from that. K8s is the numeronym: K, eight letters, s.

Checking against the docs afterwards, the one thing I had not remembered is that Borg's lessons went in deliberately — the paper "Borg, Omega, and Kubernetes" describes what they kept and what they fixed.

---

## Task 2: The architecture

```
┌──────────────────── CONTROL PLANE ────────────────────┐
│                                                       │
│   ┌─────────────────────────────────────────────┐     │
│   │           kube-apiserver                    │     │
│   │   the only component anything talks to      │◀────┼──── kubectl
│   │   REST API, authn/authz, validation         │     │
│   └───┬───────────┬──────────────┬──────────────┘     │
│       │           │              │                    │
│   ┌───▼────┐  ┌───▼───────┐  ┌───▼─────────────────┐  │
│   │  etcd  │  │ scheduler │  │ controller-manager  │  │
│   │        │  │           │  │                     │  │
│   │ the    │  │ picks a   │  │ deployment, replica │  │
│   │ only   │  │ node for  │  │ set, node, job      │  │
│   │ state  │  │ each new  │  │ controllers - each  │  │
│   │ store  │  │ pod       │  │ a reconcile loop    │  │
│   └────────┘  └───────────┘  └─────────────────────┘  │
└───────────────────────────┬───────────────────────────┘
                            │
        ┌───────────────────┼───────────────────┐
        ▼                   ▼                   ▼
┌───── WORKER NODE ───┐  ┌── WORKER NODE ──┐  ┌── WORKER NODE ──┐
│                     │  │                 │  │                 │
│  kubelet            │  │  kubelet        │  │  kubelet        │
│   asks the API      │  │                 │  │                 │
│   what to run,      │  │                 │  │                 │
│   reports status    │  │                 │  │                 │
│                     │  │                 │  │                 │
│  kube-proxy         │  │  kube-proxy     │  │  kube-proxy     │
│   iptables/IPVS     │  │                 │  │                 │
│   rules for Service │  │                 │  │                 │
│   traffic           │  │                 │  │                 │
│                     │  │                 │  │                 │
│  containerd         │  │  containerd     │  │  containerd     │
│   actually runs     │  │                 │  │                 │
│   the containers    │  │                 │  │                 │
│                     │  │                 │  │                 │
│  ┌─────┐  ┌─────┐   │  │  ┌─────┐        │  │  ┌─────┐        │
│  │ pod │  │ pod │   │  │  │ pod │        │  │  │ pod │        │
│  └─────┘  └─────┘   │  │  └─────┘        │  │  └─────┘        │
└─────────────────────┘  └─────────────────┘  └─────────────────┘
```

### What happens on `kubectl apply -f pod.yaml`

1. **kubectl** reads the file, converts it to JSON and POSTs it to the API server. It does nothing else — kubectl is just an HTTP client.
2. **API server** authenticates me (client cert from kubeconfig), authorises the action (RBAC), runs admission controllers, and validates the object against the schema.
3. **API server writes to etcd.** At this point the pod *exists* as a record, with no node assigned. `kubectl get pods` would show it Pending.
4. **Scheduler** is watching for pods with no `nodeName`. It filters nodes that cannot take it (insufficient CPU, taints, node selectors), scores the rest, picks the best, and writes the binding back to the API server.
5. **kubelet on that node** is watching for pods assigned to itself. It sees this one, pulls the image via containerd, creates the container, and starts reporting status back.
6. **kubelet keeps reporting** — the status shown by `kubectl get pods` is what kubelet last told the API server.

**Nothing talks to anything except the API server.** The scheduler does not talk to kubelet; it writes to the API server and kubelet reads from it. Every component watches the API server and reacts. That hub-and-spoke design is the thing to internalise, because it explains most of the failure behaviour below.

### If the API server goes down

**Running workloads keep running.** Containers are already started; kubelet does not need the API server to keep them alive, and kube-proxy's iptables rules stay in place, so existing traffic still flows.

**Everything else stops.** No `kubectl` at all. No new pods scheduled. No self-healing — if a pod crashes, kubelet restarts the container locally, but if a *node* dies nothing reschedules its pods. No scaling, no deployments, no rollouts.

So the cluster freezes in its current state and serves traffic, but stops being managed.

### If a worker node goes down

1. The node stops sending heartbeats.
2. After `node-monitor-grace-period` (about 40s) the node controller marks it `NotReady`.
3. After a further eviction timeout (default 5 minutes) it marks the pods for deletion.
4. The ReplicaSet controller notices it now has fewer running pods than the desired count and creates replacements.
5. The scheduler places them on healthy nodes.

**Pods managed by a Deployment come back somewhere else. A bare Pod does not** — nothing owns it, so nothing recreates it. That is the practical reason to almost never create bare Pods, which Day 51 covers.

The multi-minute delay surprised me. Recovery is automatic but not instant, which is why you run more than one replica rather than relying on rescheduling.

---

## Task 3: Install kubectl

```
devops@testvm:~$ curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
devops@testvm:~$ chmod +x kubectl && sudo mv kubectl /usr/local/bin/

devops@testvm:~$ kubectl version --client
Client Version: v1.31.1
Kustomize Version: v5.4.2
```

Autocomplete is worth setting up immediately — the resource names are long:

```
devops@testvm:~$ echo 'source <(kubectl completion bash)' >> ~/.bashrc
devops@testvm:~$ echo 'alias k=kubectl' >> ~/.bashrc
devops@testvm:~$ echo 'complete -o default -F __start_kubectl k' >> ~/.bashrc
```

---

## Task 4: The cluster

**I chose kind.**

Reasoning: kind runs each Kubernetes node as a **Docker container**, so it needs nothing beyond the Docker I already have from Day 29. minikube by default wants a VM driver, which means either nested virtualisation or another hypervisor on the VM.

Two other reasons that mattered:

- **Multi-node clusters are trivial** with kind. Days 55–57 involve scheduling and node pressure, and a single-node cluster hides half of that.
- **It starts in about 30 seconds** and deleting it is instant, so experimenting is cheap.

minikube's advantage is a built-in addon system — `minikube addons enable metrics-server` on Day 58 is one command, where kind needs a manual apply. Worth knowing, not enough to switch.

```
devops@testvm:~$ curl -Lo ./kind https://kind.sigs.k8s.io/dl/latest/kind-linux-amd64
devops@testvm:~$ chmod +x ./kind && sudo mv ./kind /usr/local/bin/kind

devops@testvm:~$ kind version
kind v0.24.0 go1.22.6 linux/amd64
```

A multi-node cluster from config:

```yaml
# kind-config.yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
    extraPortMappings:
      - containerPort: 30080
        hostPort: 30080
        protocol: TCP
  - role: worker
  - role: worker
```

```
devops@testvm:~$ kind create cluster --name devops-cluster --config kind-config.yaml
Creating cluster "devops-cluster" ...
 ✓ Ensuring node image (kindest/node:v1.31.0) 🖼
 ✓ Preparing nodes 📦 📦 📦
 ✓ Writing configuration 📜
 ✓ Starting control-plane 🕹️
 ✓ Installing CNI 🔌
 ✓ Installing StorageClass 💾
 ✓ Joining worker nodes 🚜
Set kubectl context to "kind-devops-cluster"

devops@testvm:~$ kubectl cluster-info
Kubernetes control plane is running at https://127.0.0.1:36421
CoreDNS is running at https://127.0.0.1:36421/api/v1/namespaces/kube-system/services/kube-dns:dns/proxy

devops@testvm:~$ kubectl get nodes
NAME                           STATUS   ROLES           AGE   VERSION
devops-cluster-control-plane   Ready    control-plane   68s   v1.31.0
devops-cluster-worker          Ready    <none>          52s   v1.31.0
devops-cluster-worker2         Ready    <none>          52s   v1.31.0
```

**Three nodes, all Ready.** The `extraPortMappings` block is worth including now — without it a NodePort service on Day 53 is unreachable from the host, because the "nodes" are containers on a Docker network.

Confirming what kind actually is:

```
devops@testvm:~$ docker ps --format "table {{.Names}}\t{{.Image}}"
NAMES                          IMAGE
devops-cluster-worker2         kindest/node:v1.31.0
devops-cluster-worker          kindest/node:v1.31.0
devops-cluster-control-plane   kindest/node:v1.31.0
```

The "nodes" are three Docker containers. Containers running containers.

---

## Task 5: Exploring

```
devops@testvm:~$ kubectl get nodes -o wide
NAME                           STATUS   ROLES           VERSION   INTERNAL-IP   OS-IMAGE                         CONTAINER-RUNTIME
devops-cluster-control-plane   Ready    control-plane   v1.31.0   172.18.0.4    Debian GNU/Linux 12 (bookworm)   containerd://1.7.18
devops-cluster-worker          Ready    <none>          v1.31.0   172.18.0.2    Debian GNU/Linux 12 (bookworm)   containerd://1.7.18
devops-cluster-worker2         Ready    <none>          v1.31.0   172.18.0.3    Debian GNU/Linux 12 (bookworm)   containerd://1.7.18
```

**containerd, not Docker.** Kubernetes removed the Docker shim in 1.24 — it talks to any runtime implementing the CRI, and containerd is the usual choice. Docker builds the images; containerd runs them.

```
devops@testvm:~$ kubectl describe node devops-cluster-worker | head -30
Name:               devops-cluster-worker
Roles:              <none>
Labels:             kubernetes.io/arch=amd64
                    kubernetes.io/hostname=devops-cluster-worker
                    kubernetes.io/os=linux
Conditions:
  Type             Status  Reason                       Message
  ----             ------  ------                       -------
  MemoryPressure   False   KubeletHasSufficientMemory   kubelet has sufficient memory available
  DiskPressure     False   KubeletHasNoDiskPressure     kubelet has no disk pressure
  PIDPressure      False   KubeletHasSufficientPID      kubelet has sufficient PID available
  Ready            True    KubeletReady                 kubelet is posting ready status
Capacity:
  cpu:                2
  memory:             3997420Ki
  pods:               110
Allocatable:
  cpu:                2
  memory:             3997420Ki
  pods:               110
```

Those **Conditions** are how the control plane knows a node is healthy, and `Allocatable` is what the scheduler works against — Day 57's territory.

```
devops@testvm:~$ kubectl get namespaces
NAME                 STATUS   AGE
default              Active   4m
kube-node-lease      Active   4m
kube-public          Active   4m
kube-system          Active   4m
local-path-storage   Active   3m
```

```
devops@testvm:~$ kubectl get pods -n kube-system
NAME                                                   READY   STATUS    RESTARTS   AGE
coredns-7c65d6cfc9-4jx2p                               1/1     Running   0          4m
coredns-7c65d6cfc9-nqz8k                               1/1     Running   0          4m
etcd-devops-cluster-control-plane                      1/1     Running   0          4m
kindnet-8prlv                                          1/1     Running   0          4m
kindnet-l2mnr                                          1/1     Running   0          4m
kindnet-w4kdc                                          1/1     Running   0          4m
kube-apiserver-devops-cluster-control-plane            1/1     Running   0          4m
kube-controller-manager-devops-cluster-control-plane   1/1     Running   0          4m
kube-proxy-2fhqx                                       1/1     Running   0          4m
kube-proxy-9dwtc                                       1/1     Running   0          4m
kube-proxy-mkr7j                                       1/1     Running   0          4m
kube-scheduler-devops-cluster-control-plane            1/1     Running   0          4m
```

### Matching pods to the diagram

| Pod | Component | Notes |
|---|---|---|
| `kube-apiserver-...` | API server | One, on the control plane |
| `etcd-...` | etcd | One. In production, 3 or 5 for quorum |
| `kube-scheduler-...` | Scheduler | One |
| `kube-controller-manager-...` | Controller manager | One |
| `kube-proxy-*` | kube-proxy | **Three — one per node.** A DaemonSet |
| `kindnet-*` | CNI plugin | **Three.** kind's networking, also a DaemonSet |
| `coredns-*` | Cluster DNS | Two, for redundancy |

**kubelet is missing from this list**, and that is the interesting part:

```
devops@testvm:~$ docker exec devops-cluster-worker systemctl status kubelet --no-pager | head -5
● kubelet.service - kubelet: The Kubernetes Node Agent
     Loaded: loaded (/etc/systemd/system/kubelet.service; enabled)
     Active: active (running) since Mon 2026-07-27 09:14:02 UTC; 6min ago
```

kubelet runs as a **systemd service on the host**, not as a pod. It has to — something must exist to start pods in the first place, so it cannot itself be one. Everything else can be a pod because kubelet is there to run it. Day 02's systemd knowledge turning up again.

The control-plane components are **static pods**: kubelet watches `/etc/kubernetes/manifests/` and runs whatever YAML is there, no API server involved. That is the bootstrap.

```
devops@testvm:~$ docker exec devops-cluster-control-plane ls /etc/kubernetes/manifests/
etcd.yaml
kube-apiserver.yaml
kube-controller-manager.yaml
kube-scheduler.yaml
```

**Three of each per-node component**, one per node, which is what a DaemonSet guarantees:

```
devops@testvm:~$ kubectl get daemonsets -n kube-system
NAME         DESIRED   CURRENT   READY   NODE SELECTOR            AGE
kindnet      3         3         3       <none>                   5m
kube-proxy   3         3         3       kubernetes.io/os=linux   5m
```

---

## Task 6: Cluster lifecycle

```
devops@testvm:~$ kind delete cluster --name devops-cluster
Deleting cluster "devops-cluster" ...
Deleted nodes: ["devops-cluster-worker2" "devops-cluster-worker" "devops-cluster-control-plane"]

devops@testvm:~$ kubectl get nodes
E0727 09:22:14.882104 kubectl] couldn't get current server API group list:
Get "https://127.0.0.1:36421/api?timeout=32s": dial tcp 127.0.0.1:36421: connect: connection refused

devops@testvm:~$ kind create cluster --name devops-cluster --config kind-config.yaml
devops@testvm:~$ kubectl get nodes
NAME                           STATUS   ROLES           AGE   VERSION
devops-cluster-control-plane   Ready    control-plane   41s   v1.31.0
devops-cluster-worker          Ready    <none>          28s   v1.31.0
devops-cluster-worker2         Ready    <none>          28s   v1.31.0
```

Under a minute to rebuild from nothing. That is the argument for a local cluster — breaking it costs nothing.

```
devops@testvm:~$ kubectl config current-context
kind-devops-cluster

devops@testvm:~$ kubectl config get-contexts
CURRENT   NAME                  CLUSTER               AUTHINFO              NAMESPACE
*         kind-devops-cluster   kind-devops-cluster   kind-devops-cluster
```

### What is a kubeconfig, and where does it live

`~/.kube/config`, overridable with `$KUBECONFIG`.

It holds three lists and a pointer:

```
devops@testvm:~$ kubectl config view
apiVersion: v1
clusters:
- cluster:
    certificate-authority-data: DATA+OMITTED
    server: https://127.0.0.1:36421
  name: kind-devops-cluster
contexts:
- context:
    cluster: kind-devops-cluster
    user: kind-devops-cluster
  name: kind-devops-cluster
current-context: kind-devops-cluster
users:
- name: kind-devops-cluster
  user:
    client-certificate-data: DATA+OMITTED
    client-key-data: DATA+OMITTED
```

- **clusters** — where the API server is, and the CA cert to trust it
- **users** — credentials, here a client certificate
- **contexts** — a pairing of cluster + user + optional default namespace
- **current-context** — which pairing kubectl uses right now

A context is what `kubectl config use-context` switches. On a machine with staging and production clusters, this one file is what stands between the two — which is why `kubectl config current-context` is worth checking before anything destructive, in exactly the way `pwd` is before `rm -rf`.

**It contains a private key.** `DATA+OMITTED` is `kubectl config view` being polite; the real file has the base64 key in it. `chmod 600 ~/.kube/config`, and never commit it.

---

## What I learned

**1. Every component talks only to the API server.** The scheduler does not contact kubelet — it writes a binding and kubelet reads it. That hub-and-spoke design explains why a dead API server leaves workloads running but freezes all management, and why the whole system is a set of independent reconcile loops rather than a chain of commands.

**2. kubelet cannot be a pod.** Something has to exist to start pods, so kubelet is a systemd service on the host, and the control plane runs as static pods it reads from a directory on disk. Seeing `systemctl status kubelet` inside a kind node made the bootstrap concrete.

**3. Node failure recovery is automatic but slow.** About 40 seconds to mark a node NotReady, then a 5-minute eviction timeout before pods are rescheduled. Kubernetes is self-healing on a timescale of minutes, which is why availability comes from running replicas rather than from fast recovery.

**Two extras:**

- Kubernetes runs containerd, not Docker. Docker builds images; the CRI runtime runs them.
- kind's nodes are Docker containers, so a NodePort needs `extraPortMappings` to be reachable from the host.
