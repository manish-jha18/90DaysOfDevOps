# Day 81 – Introduction to Amazon EKS with Terraform

Config in `terraform/` in this folder. Day 66's EKS setup with the production pieces added — Pod Identity and Secrets Manager.

Using **DevBoard** rather than AI-BankApp, for the reason given on Day 78. The `mega-project` branch already carries this Terraform.

**Cost:** roughly **$0.28/hour** — control plane $0.10, two `t3.medium` at $0.083 each, one NAT gateway $0.045. About **$200/month** if left running. Task 6 and Day 83's teardown script deal with that.

---

## Task 1: EKS architecture

**What AWS runs and what you run:**

```
┌──── AWS-MANAGED (you cannot see or ssh to any of this) ────┐
│                                                            │
│   kube-apiserver ×N     etcd ×3      scheduler             │
│   controller-manager    across 3 AZs                       │
│                                                            │
│   $0.10/hour, patched and scaled by AWS                    │
└────────────────────────┬───────────────────────────────────┘
                         │  ENIs placed in YOUR vpc
                         │  (this is what "intra" subnets are for)
┌────────────────────────▼───────────────────────────────────┐
│  YOUR VPC                                                  │
│                                                            │
│   worker nodes (EC2)  ← you pay for these, you patch them  │
│     kubelet, kube-proxy, containerd, VPC CNI               │
│                                                            │
│   load balancers, EBS volumes, NAT gateway                 │
└────────────────────────────────────────────────────────────┘
```

**Day 66's observation, restated because it is the defining feature:** `kubectl get pods -n kube-system` on EKS shows no `etcd`, no `kube-apiserver`, no `kube-scheduler`. They exist and are simply not yours. That is what the $0.10/hour buys.

### The three things EKS does differently from a self-managed cluster

**1. Authentication is IAM, then RBAC.** Two separate systems. IAM decides whether you may call the EKS API; RBAC decides what you may do inside the cluster. EKS bridges them with **access entries**, and creating a cluster grants you nothing inside it — which is why `enable_cluster_creator_admin_permissions` exists and why forgetting it produces a cluster you cannot `kubectl` into.

**2. Networking is the VPC CNI.** Every pod gets a **real VPC IP**, not an overlay address. Pods are routable from anywhere in the VPC, security groups can apply to them, and there is no encapsulation overhead. The cost is that a node can only hold as many pods as its instance type supports ENIs — a `t3.medium` caps at **17 pods**, which is a real limit you hit before you hit CPU or memory.

**3. Addons are managed.** CoreDNS, kube-proxy, VPC CNI, EBS CSI and metrics-server are installed and upgraded by EKS rather than by you.

### Node group types

| | Managed node group | Self-managed | Fargate |
|---|---|---|---|
| Who patches the AMI | AWS rolls it, you approve | You | No nodes at all |
| Spot support | Yes | Yes | No |
| DaemonSets | Yes | Yes | **No** |
| Cost model | Per instance | Per instance | Per pod |
| Good for | Almost everything | Custom AMIs, GPU tuning | Bursty, isolated workloads |

Managed node groups for anything normal. **Fargate's lack of DaemonSet support is the disqualifier** for most real clusters — no node exporter, no log collector, no CNI-level tooling.

---

## Task 2: The Terraform

Day 66 covered the VPC and cluster. Two files are new here, and they are what make the cluster production-shaped rather than a demo.

### Pod Identity

```hcl
module "external_secrets_pod_identity" {
  source  = "terraform-aws-modules/eks-pod-identity/aws"
  version = "~> 2.0"

  name                           = "${var.cluster_name}-external-secrets"
  attach_external_secrets_policy = true

  external_secrets_create_permission = false

  external_secrets_secrets_manager_arns = [
    "arn:aws:secretsmanager:${var.region}:${local.account_id}:secret:${var.postgres_secret_name}-*",
  ]

  associations = {
    this = {
      cluster_name    = module.eks.cluster_name
      namespace       = "external-secrets"
      service_account = "external-secrets"
    }
  }
}
```

**The problem this solves:** a pod needs AWS permissions. The naive answers are an access key in a Secret — which is Day 27's leak — or an IAM role on the node, which gives *every* pod on that node the same permissions.

**IRSA** was the old fix: an OIDC provider, a trust policy referencing it, and an annotation on the ServiceAccount. Three things that must agree, in two different systems.

**Pod Identity** replaces all of it with one association object. No annotation on the ServiceAccount at all — the association names the namespace and service account, and the `eks-pod-identity-agent` addon injects credentials at pod start.

**The detail that matters for GitOps:** an association may name a **namespace and service account that do not exist yet**. That is exactly the case here — Terraform creates the association, and Helm or ArgoCD creates the ServiceAccount later. With IRSA the annotation has to be applied by whatever creates the ServiceAccount, which couples the two.

**Two least-privilege choices in that block:**

`external_secrets_create_permission = false` — the operator only *reads* secrets. It has no business creating or modifying them.

The ARN is scoped to `devboard/postgres-*`, not `secret:*`. The trailing `-*` is required because Secrets Manager appends a random suffix to every secret's ARN — omitting it means the policy matches nothing and the operator fails with an access denied that looks like a permissions bug rather than a pattern bug.

### The secret container

```hcl
resource "aws_secretsmanager_secret" "postgres" {
  name                    = var.postgres_secret_name
  recovery_window_in_days = 0
}
```

**Terraform creates the secret but never its value.** A `aws_secretsmanager_secret_version` with the password in it would put that password in **Terraform state in plain text** — Day 61's warning, with the worst possible value. The value is set out of band:

```
devops@testvm:~$ aws secretsmanager put-secret-value \
    --secret-id devboard/postgres \
    --secret-string '{"username":"devboard","password":"'"$(openssl rand -base64 24)"'","dbname":"devboard"}'
```

Generated on the fly, never typed, never stored anywhere but Secrets Manager.

**`recovery_window_in_days = 0`** because the 30-day default soft-delete blocks recreating a secret with the same name for a month. On a learning account that turns one teardown into a month of `InvalidRequestException`. Wrong for production, right here — and devboard's config carries the same comment.

---

## Task 3: Provisioning

```
devops@testvm:~/day-81/terraform$ terraform init
devops@testvm:~/day-81/terraform$ terraform plan | tail -3
Plan: 71 to add, 0 to change, 0 to destroy.
```

71 resources — Day 66's 63, plus the two Pod Identity modules and the Secrets Manager secret.

```
devops@testvm:~/day-81/terraform$ time terraform apply -auto-approve
module.eks.aws_eks_cluster.this[0]: Still creating... [8m40s elapsed]
module.eks.aws_eks_cluster.this[0]: Creation complete after 9m18s
...
Apply complete! Resources: 71 added, 0 changed, 0 destroyed.

Outputs:
cluster_endpoint      = "https://8A3F91C4....gr7.us-west-2.eks.amazonaws.com"
configure_kubectl     = "aws eks update-kubeconfig --region us-west-2 --name devboard"
estimated_hourly_cost = "~$0.31/hr : control plane $0.10 + 2 x t3.medium + 1 NAT gateway $0.045"
postgres_secret_arn   = "arn:aws:secretsmanager:us-west-2:381492154712:secret:devboard/postgres-a3F9c1"

real    14m52s
```

**The `estimated_hourly_cost` output** is a small addition and worth having. It puts the number in front of you every apply rather than in a billing dashboard three weeks later.

Note the secret ARN ends in `-a3F9c1` — that random suffix is why the IAM policy needs the trailing `-*`.

---

## Task 4: Connecting

```
devops@testvm:~$ aws eks update-kubeconfig --region us-west-2 --name devboard
Added new context arn:aws:eks:us-west-2:381492154712:cluster/devboard to /home/devops/.kube/config

devops@testvm:~$ kubectl config get-contexts
CURRENT   NAME                                                  CLUSTER
          kind-devops-cluster                                   kind-devops-cluster
*         arn:aws:eks:us-west-2:381492154712:cluster/devboard    devboard
```

**Two clusters in one kubeconfig**, one free and one $200/month. Day 50's point about `kubectl config current-context` before anything destructive is not academic here.

```
devops@testvm:~$ kubectl get nodes -o wide
NAME                                       STATUS   ROLES    VERSION               INTERNAL-IP
ip-10-0-4-118.us-west-2.compute.internal   Ready    <none>   v1.31.0-eks-a737599   10.0.4.118
ip-10-0-5-201.us-west-2.compute.internal   Ready    <none>   v1.31.0-eks-a737599   10.0.5.201
```

Private IPs — the nodes are in private subnets, as intended.

**Verifying Pod Identity actually works**, which is the thing most likely to be subtly wrong:

```
devops@testvm:~$ aws eks list-pod-identity-associations --cluster-name devboard \
    --query 'associations[].[namespace,serviceAccount]' --output table
------------------------------------------------
|  kube-system        |  ebs-csi-controller-sa  |
|  external-secrets   |  external-secrets       |
------------------------------------------------
```

**The `external-secrets` namespace does not exist yet** and the association is happily registered anyway. That is the property that makes this work with GitOps.

```
devops@testvm:~$ kubectl get pods -n kube-system
NAME                                 READY   STATUS    RESTARTS   AGE
aws-node-8prlv                       2/2     Running   0          4m
coredns-7c65d6cfc9-4jx2p             1/1     Running   0          6m
ebs-csi-controller-6d4f8b9c6d-x2mk   6/6     Running   0          3m
eks-pod-identity-agent-2fhqx         1/1     Running   0          4m
kube-proxy-9dwtc                     1/1     Running   0          4m
metrics-server-587b667b55-p2nvx      1/1     Running   0          3m
```

`eks-pod-identity-agent` is the DaemonSet that injects credentials. `aws-node` is the VPC CNI. No control plane pods, per Task 1.

```
devops@testvm:~$ kubectl top nodes
NAME                                       CPU(cores)   CPU%   MEMORY(bytes)   MEMORY%
ip-10-0-4-118.us-west-2.compute.internal   52m          2%     712Mi           21%
```

`kubectl top` works immediately — the managed metrics-server addon, no `--kubelet-insecure-tls` fight (Day 58).

---

## Task 5: Deploying by hand, before GitOps

Deliberately before ArgoCD, so the manual path is understood first.

```
devops@testvm:~$ aws secretsmanager put-secret-value --secret-id devboard/postgres \
    --secret-string '{"username":"devboard","password":"'"$(openssl rand -base64 24)"'","dbname":"devboard"}'

devops@testvm:~$ helm upgrade --install external-secrets external-secrets/external-secrets \
    -n external-secrets --create-namespace --set installCRDs=true --wait

devops@testvm:~$ kubectl apply -f ../day-82/manifests/external-secrets/cluster-secret-store.yaml
devops@testvm:~$ kubectl get clustersecretstore aws-secrets-manager \
    -o jsonpath='{.status.conditions[0].status}'
True
```

**`True` means the operator authenticated to AWS**, which proves the whole Pod Identity chain: association → agent → credentials → Secrets Manager. If this says `False`, the IAM policy ARN pattern is the first thing to check.

```
devops@testvm:~$ kubectl create namespace devboard
devops@testvm:~$ kubectl apply -f ../day-82/manifests/external-secrets/externalsecret.yaml
devops@testvm:~$ kubectl get externalsecret -n devboard
NAME               STORE                 REFRESH INTERVAL   STATUS         READY
devboard-secrets   aws-secrets-manager   1h                 SecretSynced   True

devops@testvm:~$ kubectl get secret devboard-secrets -n devboard -o jsonpath='{.data}' | jq 'keys'
[
  "POSTGRES_DB",
  "POSTGRES_PASSWORD",
  "POSTGRES_URL",
  "POSTGRES_USER"
]
```

**An ordinary Kubernetes Secret, created from AWS.** The password exists in Secrets Manager and in etcd, and in **no git repository, no values file, and no Terraform state**. That is what Day 80 flagged as the gap in the Helm chart's `secret.yaml`.

```
devops@testvm:~$ helm upgrade --install devboard ../day-80/helm/devboard \
    -n devboard -f ../day-80/helm/devboard/values-prod.yaml \
    --set postgres.storage.storageClassName=gp3 --atomic --timeout 10m

devops@testvm:~$ kubectl get pods -n devboard
NAME                                  READY   STATUS    RESTARTS   AGE
devboard-devboard-backend-7d4f8b-2xk  1/1     Running   0          2m
devboard-devboard-frontend-6b8d9f-k7w 1/1     Running   0          2m
devboard-devboard-frontend-6b8d9f-p2n 1/1     Running   0          2m
devboard-devboard-frontend-6b8d9f-vz9 1/1     Running   0          2m
devboard-devboard-postgres-0          1/1     Running   0          2m
```

Three frontend replicas from `values-prod.yaml`, one backend, one Postgres. `--atomic` so a failure would have rolled itself back rather than leaving half a release.

---

## Task 6: Cost and cleanup

```
devops@testvm:~$ aws ce get-cost-and-usage --time-period Start=2026-08-16,End=2026-08-17 \
    --granularity DAILY --metrics UnblendedCost \
    --group-by Type=DIMENSION,Key=SERVICE \
    --query 'ResultsByTime[0].Groups[?Metrics.UnblendedCost.Amount>`0.01`].[Keys[0],Metrics.UnblendedCost.Amount]' \
    --output table
--------------------------------------------------
|  Amazon Elastic Compute Cloud - Compute  | 3.99 |
|  Amazon Elastic Container Service for K8s| 2.40 |
|  EC2 - Other                             | 1.31 |
|  AWS Secrets Manager                     | 0.01 |
--------------------------------------------------
```

**`EC2 - Other` is the line to watch.** That is the NAT gateway, the EBS volumes and the Elastic IP — the costs that are easy to forget because they are not an obvious running thing.

### Costs per month, roughly

| | Cost |
|---|---|
| EKS control plane | $73 |
| 2 × t3.medium | $60 |
| NAT gateway | $33 + data |
| EBS, 2 × 30 GiB + 20 GiB PVC | $8 |
| Load balancer (Day 82) | $16 |
| **Total** | **~$190/month** |

**Ways to reduce it,** roughly in order of value:

- **Destroy it.** A learning cluster used for two hours a day costs about $17/month if torn down each time.
- **Spot instances** for worker nodes — 60–70% off, with interruption.
- **A single NAT gateway** rather than one per AZ, which Day 66's config already does with a comment saying not to copy it to production.
- **VPC endpoints** for S3 and ECR if NAT data transfer becomes significant.

### The teardown order

**Kubernetes creates AWS resources Terraform does not know about.** A `type: LoadBalancer` Service or a Gateway creates an ELB; a PVC creates an EBS volume. Terraform did not make them, so it does not delete them — and it cannot delete the subnet they live in:

```
Error: deleting EC2 Subnet: DependencyViolation: The subnet has dependencies and cannot be deleted
```

That leaves the VPC half-destroyed and the rest has to be cleaned up by hand in the console.

**The order that works:**

1. Delete Gateways and LoadBalancer Services
2. Wait for AWS to actually remove the load balancers
3. `helm uninstall`, then delete PVCs — remembering that StatefulSet PVCs are not owned by Helm (Day 56)
4. Delete the namespace
5. `terraform destroy`
6. Verify no NAT gateways, Elastic IPs, unattached volumes or load balancers remain

Day 83's `teardown.sh` automates exactly that.

---

## Files in this folder

| Path | What it is |
|---|---|
| `terraform/vpc.tf`, `eks.tf`, `storage.tf` | Day 66's cluster — three subnet tiers, addons, default gp3 class |
| `terraform/pod-identity.tf` | EBS CSI and External Secrets roles, scoped ARNs |
| `terraform/secrets.tf` | The Secrets Manager container, value set out of band |
| `terraform/outputs.tf` | Endpoint, kubectl command, cost estimate |

---

## What I learned

**1. Pod Identity can reference a namespace and service account that do not exist yet.** IRSA cannot — its annotation has to be applied by whatever creates the ServiceAccount, which couples Terraform to Helm. That decoupling is what makes Pod Identity the right choice when ArgoCD creates the workloads later.

**2. Terraform must create the secret container, never its value.** An `aws_secretsmanager_secret_version` with a real password puts it in state in plain text. Setting it with the CLI from `openssl rand` means the password exists in exactly one place.

**3. Secrets Manager appends a random suffix to every ARN, so an IAM policy needs a trailing `-*`.** Without it the pattern matches nothing and the operator fails with an access denied that reads like a permissions problem rather than a pattern problem.

**Two extras:**

- The VPC CNI gives pods real VPC IPs, and the trade is a per-instance-type pod cap — a `t3.medium` holds 17 pods regardless of how much CPU is free.
- `recovery_window_in_days = 0` on a learning account. The 30-day soft-delete default makes a name unusable for a month after teardown.
