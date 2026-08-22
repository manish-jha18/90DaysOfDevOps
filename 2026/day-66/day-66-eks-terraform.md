# Day 66 – Provision an EKS Cluster with Terraform

Config in `terraform/` in this folder. This is the shape of devboard's `mega-project` Terraform, trimmed to what today needs.

**Cost warning up front:** an EKS control plane is **$0.10/hour** whether or not anything runs on it, plus two `t3.medium` nodes and a NAT gateway. Roughly **$0.28/hour, about $200/month** if left running. Task 6 destroys it.

---

## Task 1: Project setup

```
terraform/
├── versions.tf     version pins
├── providers.tf    aws + kubernetes providers, locals
├── variables.tf    inputs
├── vpc.tf          networking
├── eks.tf          the cluster
├── storage.tf      default gp3 storage class
└── outputs.tf
```

One file per concern rather than one large `main.tf`. Terraform concatenates every `.tf` in the directory, so file layout is purely for humans — and with ~30 resources it matters.

---

## Task 2: The VPC

```hcl
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 6.0"

  name = var.cluster_name
  cidr = local.vpc_cidr
  azs  = local.azs

  public_subnets  = local.public_subnets
  private_subnets = local.private_subnets
  intra_subnets   = local.intra_subnets

  enable_nat_gateway = true
  single_nat_gateway = true

  public_subnet_tags  = { "kubernetes.io/role/elb" = 1 }
  private_subnet_tags = { "kubernetes.io/role/internal-elb" = 1 }
}
```

**Three subnet tiers, not two:**

| Tier | Holds | Route to internet |
|---|---|---|
| **public** | Load balancers, NAT gateway | Direct, via IGW |
| **private** | Worker nodes | Outbound only, via NAT |
| **intra** | EKS control plane ENIs | **None at all** |

Intra subnets are the interesting one. The EKS control plane places network interfaces in your VPC to reach the nodes, and those need no internet access whatsoever. Putting them in their own routeless tier is least privilege applied to networking.

**Worker nodes go in private subnets.** They pull images and reach AWS APIs outbound through the NAT gateway; nothing reaches in except through a load balancer in the public tier. This is Day 15's public/private split, and it is the single most important security decision in the file.

**The subnet tags are load-bearing.** `kubernetes.io/role/elb` on public subnets and `kubernetes.io/role/internal-elb` on private is how the AWS Load Balancer Controller discovers where to place a load balancer. Without them a `type: LoadBalancer` Service sits at `<pending>` forever — the exact symptom from Day 53, but for a completely different reason and much harder to diagnose.

---

## Task 3: The cluster

```hcl
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.0"

  name               = var.cluster_name
  kubernetes_version = var.kubernetes_version

  endpoint_public_access  = true
  endpoint_private_access = true

  enable_cluster_creator_admin_permissions = true

  enabled_log_types                      = ["audit", "authenticator"]
  cloudwatch_log_group_retention_in_days = 7

  vpc_id                   = module.vpc.vpc_id
  subnet_ids               = module.vpc.private_subnets
  control_plane_subnet_ids = module.vpc.intra_subnets

  addons = {
    coredns                = {}
    kube-proxy             = {}
    vpc-cni                = { before_compute = true }
    eks-pod-identity-agent = { before_compute = true }
    metrics-server         = {}
    aws-ebs-csi-driver     = {}
  }

  eks_managed_node_groups = {
    default = {
      ami_type       = "AL2023_x86_64_STANDARD"
      instance_types = [var.node_instance_type]
      min_size       = var.node_min_size
      max_size       = var.node_max_size
      desired_size   = var.node_desired_size

      block_device_mappings = {
        xvda = {
          device_name = "/dev/xvda"
          ebs = {
            volume_size = var.node_disk_size
            volume_type = "gp3"
            encrypted   = true
          }
        }
      }
    }
  }
}
```

### Four lines that are easy to get wrong

**`enable_cluster_creator_admin_permissions = true`.** Without it, the IAM identity that *created* the cluster has no Kubernetes access to it. `kubectl get nodes` returns a permissions error on a cluster you just built. EKS authentication is IAM for the AWS API and RBAC for the Kubernetes API, and they are separate systems — creating a cluster grants nothing inside it.

**`before_compute = true` on the CNI.** The VPC CNI assigns pod IPs. If nodes join before it is installed they register `NotReady` with no pod networking, and the cluster comes up broken in a way that looks like a node problem.

**`block_device_mappings`, not `disk_size`.** Module v21 silently ignores `disk_size`, so nodes get the 20 GiB default. That is genuinely tight once a few images and an observability stack are on disk, and the failure is disk-pressure eviction — pods evicted for reasons nothing obviously explains. devboard's `eks.tf` carries a comment about exactly this.

**`enabled_log_types` is a cost decision.** Enabling `api` and `controllerManager` on a busy cluster produces a large CloudWatch bill for logs nobody reads. `audit` and `authenticator` are the two worth having.

**Addons versus Helm charts.** Managed addons are installed and upgraded by EKS rather than by me — one less thing to version. `metrics-server` here means Day 58's HPA works immediately, without the `--kubelet-insecure-tls` patch kind needed.

### The kubernetes provider

```hcl
provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", var.region]
  }
}
```

**The `exec` block matters.** It shells out to `aws eks get-token` at apply time, so the token is short-lived and **never written to state**. A `token = "..."` attribute would put a live cluster credential in the state file in plain text — Day 61's warning, with the worst possible value.

There is a real chicken-and-egg wrinkle here: this provider is configured from outputs of a module in the same config, so a plan against an empty state has to defer those values. It works for creation, but destroying the cluster and its Kubernetes resources in one apply can fail. The clean answer is two separate configs — infrastructure, then cluster contents. Day 67's structure would fix it.

---

## Task 4: Apply and connect

```
devops@testvm:~/day-66/terraform$ terraform init
Initializing modules...
Downloading registry.terraform.io/terraform-aws-modules/eks/aws 21.0.4 for eks...
Downloading registry.terraform.io/terraform-aws-modules/vpc/aws 6.1.0 for vpc...

devops@testvm:~/day-66/terraform$ terraform plan | tail -3
Plan: 63 to add, 0 to change, 0 to destroy.
```

**Sixty-three resources.** The VPC module accounts for about 25, and the EKS module the rest — IAM roles and policy attachments, security groups and rules, the cluster, the node group, launch template, addons and access entries.

```
devops@testvm:~/day-66/terraform$ time terraform apply -auto-approve
module.vpc.aws_vpc.this[0]: Creation complete after 3s
module.vpc.aws_nat_gateway.this[0]: Still creating... [1m20s elapsed]
module.eks.aws_eks_cluster.this[0]: Still creating... [8m30s elapsed]
module.eks.aws_eks_cluster.this[0]: Creation complete after 9m12s
module.eks.module.eks_managed_node_group["default"].aws_eks_node_group.this[0]: Still creating... [2m10s elapsed]
module.eks.module.eks_managed_node_group["default"].aws_eks_node_group.this[0]: Creation complete after 2m41s

Apply complete! Resources: 63 added, 0 changed, 0 destroyed.

real    14m22s
```

**About 14 minutes**, and most of it is AWS, not Terraform. The control plane alone takes 9 minutes. Worth knowing before assuming something has hung.

```
Outputs:
cluster_endpoint  = "https://8A3F91C4D2E58B1A6C9E0D4A1F27B8A3.gr7.us-west-2.eks.amazonaws.com"
cluster_name      = "devboard"
configure_kubectl = "aws eks update-kubeconfig --region us-west-2 --name devboard"
```

The `configure_kubectl` output is a small thing that saves looking up the syntax:

```
devops@testvm:~$ aws eks update-kubeconfig --region us-west-2 --name devboard
Added new context arn:aws:eks:us-west-2:381492154712:cluster/devboard to /home/devops/.kube/config

devops@testvm:~$ kubectl get nodes
NAME                                       STATUS   ROLES    AGE     VERSION
ip-10-0-4-118.us-west-2.compute.internal   Ready    <none>   3m21s   v1.31.0-eks-a737599
ip-10-0-5-201.us-west-2.compute.internal   Ready    <none>   3m19s   v1.31.0-eks-a737599
```

**Both Ready.** Node names are private IPs, confirming they are in the private subnets.

That command wrote a **new context** into the same kubeconfig as the kind cluster from Day 50 — the structure from that day, with two clusters in it now:

```
devops@testvm:~$ kubectl config get-contexts
CURRENT   NAME                                                       CLUSTER
          kind-devops-cluster                                        kind-devops-cluster
*         arn:aws:eks:us-west-2:381492154712:cluster/devboard        devboard
```

**Two clusters, one config file.** This is precisely why Day 50 made a point of `kubectl config current-context` — the difference between a local throwaway and a $200/month AWS cluster is one line in a file.

```
devops@testvm:~$ kubectl get pods -A
NAMESPACE     NAME                             READY   STATUS    RESTARTS   AGE
kube-system   aws-node-8prlv                   2/2     Running   0          4m
kube-system   aws-node-l2mnr                   2/2     Running   0          4m
kube-system   coredns-7c65d6cfc9-4jx2p         1/1     Running   0          6m
kube-system   ebs-csi-controller-6d4f8b9c6d-x  6/6     Running   0          3m
kube-system   eks-pod-identity-agent-2fhqx     1/1     Running   0          4m
kube-system   kube-proxy-9dwtc                 1/1     Running   0          4m
kube-system   metrics-server-587b667b55-p2nvx  1/1     Running   0          3m
```

Day 50's `kube-system` listing, with EKS differences: `aws-node` is the VPC CNI in place of kind's `kindnet`, and there is no `etcd`, `kube-apiserver` or `kube-scheduler` pod — **the control plane is managed by AWS and simply not visible.** That is what you are paying $0.10/hour for.

```
devops@testvm:~$ kubectl top nodes
NAME                                       CPU(cores)   CPU%   MEMORY(bytes)   MEMORY%
ip-10-0-4-118.us-west-2.compute.internal   52m          2%     712Mi           21%
ip-10-0-5-201.us-west-2.compute.internal   48m          2%     684Mi           20%
```

`kubectl top` works immediately, unlike Day 58's TLS fight on kind.

---

## Task 5: A workload

```
devops@testvm:~$ kubectl create deployment nginx --image=nginx:1.25-alpine --replicas=3
devops@testvm:~$ kubectl expose deployment nginx --port=80 --type=LoadBalancer

devops@testvm:~$ kubectl get svc nginx
NAME    TYPE           CLUSTER-IP      EXTERNAL-IP                             PORT(S)
nginx   LoadBalancer   172.20.184.201  a8f2c91d4e7-1284471.us-west-2.elb...   80:31447/TCP
```

**A real EXTERNAL-IP.** Day 53's `type: LoadBalancer` sat at `<pending>` on kind forever because there was no cloud provider. Here AWS provisioned a Classic Load Balancer in the public subnets — found via the `kubernetes.io/role/elb` tag from Task 2.

```
devops@testvm:~$ curl -sI http://a8f2c91d4e7-1284471.us-west-2.elb.amazonaws.com | head -1
HTTP/1.1 200 OK
```

Testing the storage class:

```
devops@testvm:~$ kubectl get storageclass
NAME            PROVISIONER             RECLAIMPOLICY   VOLUMEBINDINGMODE      DEFAULT
gp2             kubernetes.io/aws-ebs   Delete          WaitForFirstConsumer   false
gp3 (default)   ebs.csi.aws.com         Delete          WaitForFirstConsumer   true
```

**`gp2` exists and is not default.** That is EKS out of the box, and it is why `storage.tf` creates a `gp3` class marked default — otherwise every PVC without an explicit `storageClassName` hangs `Pending` with no obvious reason. devboard's `storage.tf` has the same fix with the same comment.

```
devops@testvm:~$ kubectl apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: test-pvc
spec:
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 4Gi
EOF

devops@testvm:~$ kubectl get pvc test-pvc
NAME       STATUS    VOLUME   CAPACITY   STORAGECLASS   AGE
test-pvc   Pending                       gp3            8s
```

`Pending` is correct — `WaitForFirstConsumer` from Day 55. It binds once a pod uses it, so the EBS volume is created in the right AZ.

---

## Task 6: Destroy

```
devops@testvm:~$ kubectl delete svc nginx
service "nginx" deleted
devops@testvm:~$ kubectl delete pvc test-pvc
```

**Delete Kubernetes-created AWS resources first.** A `type: LoadBalancer` Service creates an ELB that Terraform does not know about, because Kubernetes made it, not Terraform. Leave it and `terraform destroy` fails:

```
Error: deleting EC2 Subnet: DependencyViolation: The subnet has dependencies and cannot be deleted
```

Terraform tries to delete the subnet, AWS refuses because a load balancer still lives in it, and the destroy stops half-finished. The same applies to PVCs, which create EBS volumes.

**This is the single most common way an EKS teardown gets stuck**, and the recovery is finding and deleting the orphans by hand in the console.

```
devops@testvm:~/day-66/terraform$ time terraform destroy -auto-approve
module.eks.module.eks_managed_node_group["default"].aws_eks_node_group.this[0]: Destroying...
module.eks.module.eks_managed_node_group["default"].aws_eks_node_group.this[0]: Destruction complete after 4m12s
module.eks.aws_eks_cluster.this[0]: Destruction complete after 3m48s
module.vpc.aws_nat_gateway.this[0]: Destruction complete after 1m34s

Destroy complete! Resources: 63 destroyed.

real    11m47s
```

Confirming nothing is left billing:

```
devops@testvm:~$ aws eks list-clusters --region us-west-2
{ "clusters": [] }

devops@testvm:~$ aws ec2 describe-vpcs --filters "Name=tag:Project,Values=devboard" --query 'Vpcs[].VpcId' --region us-west-2
[]

devops@testvm:~$ aws ec2 describe-nat-gateways --filter "Name=state,Values=available" --query 'NatGateways[].NatGatewayId' --region us-west-2
[]
```

The NAT gateway check matters — it is $33/month on its own and easy to leave behind.

**Total for this exercise: about 40 minutes running, roughly $0.19.** Cheap, provided you actually destroy it. An EKS cluster forgotten over a weekend is about $14.

---

## Files in this folder

| Path | What it is |
|---|---|
| `terraform/versions.tf` | Provider pins |
| `terraform/providers.tf` | AWS + kubernetes with `exec` auth, locals |
| `terraform/variables.tf` | Region, cluster name, node sizing |
| `terraform/vpc.tf` | Three-tier VPC with the load balancer discovery tags |
| `terraform/eks.tf` | Cluster, addons, managed node group |
| `terraform/storage.tf` | Default gp3 storage class |
| `terraform/outputs.tf` | Endpoint plus the `configure_kubectl` helper |

---

## What I learned

**1. Creating an EKS cluster grants you no access to it.** Without `enable_cluster_creator_admin_permissions`, `kubectl get nodes` fails on a cluster you just built. IAM controls the AWS API; RBAC controls the Kubernetes API; they are separate systems and EKS bridges them with access entries.

**2. Kubernetes creates AWS resources that Terraform does not track, and they block the destroy.** A `type: LoadBalancer` Service makes an ELB in a Terraform-managed subnet, so the subnet cannot be deleted. Delete the Kubernetes objects before running `terraform destroy` or the teardown stops half-finished.

**3. Sensible-looking defaults are frequently wrong on EKS.** `disk_size` is silently ignored by module v21 so nodes get 20 GiB. `gp2` exists but is not the default class, so PVCs hang. Subnet tags are what load balancer placement depends on. Each of these fails in a way that points somewhere other than the cause.

**Two extras:**

- Use `exec` auth on the kubernetes provider. A static token would be written to state in plain text.
- Check for orphaned NAT gateways and load balancers after destroying. `default_tags` from Day 61 is what makes that a one-line query.
