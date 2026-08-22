# Day 67 – TerraWeek Capstone: Multi-Environment with Workspaces and Modules

Everything from Days 61–66 in one project. Config in `terraform/`.

```
terraform/
├── main.tf              workspace-aware config
├── variables.tf
├── outputs.tf
├── versions.tf
└── modules/
    ├── network/         VPC, subnets, optional NAT
    └── compute/         security group + instances
```

---

## Task 1: Workspaces

A workspace is **a separate state file for the same configuration**. One set of `.tf` files, three independent sets of real infrastructure.

```
devops@testvm:~/day-67/terraform$ terraform init
devops@testvm:~/day-67/terraform$ terraform workspace list
* default

devops@testvm:~/day-67/terraform$ terraform workspace new dev
Created and switched to workspace "dev"!
devops@testvm:~/day-67/terraform$ terraform workspace new staging
devops@testvm:~/day-67/terraform$ terraform workspace new prod

devops@testvm:~/day-67/terraform$ terraform workspace list
  default
  dev
* prod
  staging
```

State is separated on disk (or by key prefix in S3):

```
devops@testvm:~/day-67/terraform$ find terraform.tfstate.d -type d
terraform.tfstate.d
terraform.tfstate.d/dev
terraform.tfstate.d/staging
terraform.tfstate.d/prod
```

**`terraform.workspace` is the whole mechanism** — a built-in variable holding the current workspace name, which the config branches on.

### Where workspaces stop being a good idea

Worth being clear about, because they are frequently misused.

**Good for:** environments that are genuinely identical apart from sizing, in the same AWS account and region. Dev/staging/prod that differ only in instance size and replica count. Exactly this exercise.

**Bad for:** anything where the environments differ structurally, or live in different AWS accounts. And there is one specific hazard:

**The backend is shared across all workspaces.** One bucket, one set of credentials. A production workspace whose state sits in the same bucket as dev, reachable with the same permissions, is not real isolation. Separate accounts are the standard answer for anything with a real production, and that means separate configs with separate backends rather than workspaces.

**The other hazard is human.** `terraform apply` uses whichever workspace happens to be selected, and nothing in the command names it. Running a destroy in `prod` when you thought you were in `dev` is one forgotten `workspace select` away — the same class of mistake as Day 66's two kubeconfig contexts.

I would use workspaces exactly as here — a learning project or a genuinely uniform set of environments — and separate directories with separate backends for anything where prod matters.

---

## Task 2 and 3: Project structure and modules

Two modules, each doing one thing (Day 65's rule).

### `modules/network`

The interesting part is that subnets are **derived**, not passed in:

```hcl
locals {
  azs = slice(data.aws_availability_zones.available.names, 0, var.az_count)

  public_cidrs  = [for i in range(var.az_count) : cidrsubnet(var.vpc_cidr, 8, i)]
  private_cidrs = [for i in range(var.az_count) : cidrsubnet(var.vpc_cidr, 8, i + 10)]
}
```

Day 63's `cidrsubnet()`. A caller supplies one non-overlapping `/16` per environment and every subnet follows. The `+ 10` offset keeps private subnets clear of public ones — `10.30.0.0/24` and `10.30.1.0/24` public, `10.30.10.0/24` and `10.30.11.0/24` private.

**The NAT gateway is optional**, which is a real cost decision:

```hcl
resource "aws_eip" "nat" {
  count  = var.enable_nat_gateway ? 1 : 0
  domain = "vpc"
}

resource "aws_nat_gateway" "this" {
  count = var.enable_nat_gateway ? 1 : 0

  allocation_id = aws_eip.nat[0].id
  subnet_id     = aws_subnet.public[0].id

  depends_on = [aws_internet_gateway.this]
}
```

`count = 0` creates nothing at all. Dev skips it and saves about $33/month; staging and prod get it.

`depends_on` on the internet gateway is Day 62's explicit-dependency case — a NAT gateway needs the IGW to exist, and nothing in its arguments references it.

### `modules/compute`

Security group plus instances, with `for_each` over the allowed CIDRs so removing one does not disturb the others (Day 63).

---

## Task 4: Workspace-aware configuration

The core of the capstone:

```hcl
locals {
  env = terraform.workspace

  env_config = {
    dev = {
      vpc_cidr            = "10.10.0.0/16"
      instance_type       = "t3.micro"
      instance_count      = 1
      az_count            = 2
      enable_nat_gateway  = false
      detailed_monitoring = false
      allowed_http_cidrs  = ["0.0.0.0/0"]
    }

    staging = {
      vpc_cidr            = "10.20.0.0/16"
      instance_type       = "t3.small"
      instance_count      = 2
      az_count            = 2
      enable_nat_gateway  = true
      detailed_monitoring = false
      allowed_http_cidrs  = ["0.0.0.0/0"]
    }

    prod = {
      vpc_cidr            = "10.30.0.0/16"
      instance_type       = "t3.medium"
      instance_count      = 3
      az_count            = 3
      enable_nat_gateway  = true
      detailed_monitoring = true
      allowed_http_cidrs  = ["10.0.0.0/8"]
    }
  }

  cfg = lookup(local.env_config, local.env, null)
}
```

**A map of environment to configuration, indexed by workspace.** Every difference between environments is visible in one block, which is the thing to optimise for — a reviewer can see at a glance that prod is the only one not open to the world.

**Non-overlapping CIDRs are deliberate.** `10.10`, `10.20`, `10.30`. If these VPCs are ever peered, overlapping ranges make that impossible, and it cannot be fixed without rebuilding.

### The guard

```hcl
resource "terraform_data" "workspace_guard" {
  lifecycle {
    precondition {
      condition     = local.cfg != null
      error_message = "Unknown workspace '${terraform.workspace}'. Run: terraform workspace select dev|staging|prod"
    }
  }
}
```

**This is the most important eight lines in the file.**

Without it, running in the `default` workspace makes `local.cfg` null, and the first attempt to read `local.cfg.vpc_cidr` fails with something like `Attempt to get attribute from null value` — technically accurate and completely unhelpful.

```
devops@testvm:~/day-67/terraform$ terraform workspace select default
devops@testvm:~/day-67/terraform$ terraform plan

Error: Resource precondition failed

  on main.tf line 68:
  68:       condition     = local.cfg != null

Unknown workspace 'default'. Run: terraform workspace select dev|staging|prod
```

Fails immediately, in plain language, before any API call. That is Day 63's `validation` idea applied to something a variable cannot express.

---

## Task 5: Deploying all three

```
devops@testvm:~/day-67/terraform$ terraform workspace select dev
devops@testvm:~/day-67/terraform$ terraform apply -auto-approve

Apply complete! Resources: 12 added, 0 changed, 0 destroyed.

Outputs:
instance_ips = ["44.238.114.92"]
summary      = "devboard-dev: 1 x t3.micro across 2 AZs, NAT=false, CIDR=10.10.0.0/16"
vpc_cidr     = "10.10.0.0/16"
workspace    = "dev"
```

```
devops@testvm:~/day-67/terraform$ terraform workspace select staging
devops@testvm:~/day-67/terraform$ terraform apply -auto-approve

Apply complete! Resources: 16 added, 0 changed, 0 destroyed.

Outputs:
summary = "devboard-staging: 2 x t3.small across 2 AZs, NAT=true, CIDR=10.20.0.0/16"
```

```
devops@testvm:~/day-67/terraform$ terraform workspace select prod
devops@testvm:~/day-67/terraform$ terraform apply -auto-approve

Apply complete! Resources: 21 added, 0 changed, 0 destroyed.

Outputs:
summary = "devboard-prod: 3 x t3.medium across 3 AZs, NAT=true, CIDR=10.30.0.0/16"
```

**12, 16 and 21 resources from the identical configuration.** The differences are entirely from the map — dev has no NAT gateway or Elastic IP, prod has a third AZ.

```
devops@testvm:~$ aws ec2 describe-vpcs --region us-west-2 \
    --filters "Name=tag:Project,Values=devboard" \
    --query 'Vpcs[].[CidrBlock,Tags[?Key==`Name`].Value|[0]]' --output table
------------------------------------------
|  10.10.0.0/16  |  devboard-dev-vpc      |
|  10.20.0.0/16  |  devboard-staging-vpc  |
|  10.30.0.0/16  |  devboard-prod-vpc     |
------------------------------------------
```

Three isolated environments, three state files, one config.

**Switching workspaces changes what a plan sees, with nothing else changing:**

```
devops@testvm:~/day-67/terraform$ terraform workspace select dev
devops@testvm:~/day-67/terraform$ terraform plan
No changes. Your infrastructure matches the configuration.
```

Dev is untouched by having applied prod. Separate state means separate reality.

---

## Task 6: Best practice

What I would carry out of TerraWeek.

### Structure

**One directory per concern, not one giant `main.tf`.** Terraform concatenates every `.tf` in the directory, so the split is purely for humans — and it matters at anything above about twenty resources.

**Modules small and single-purpose.** Two modules here rather than one "environment" module, because a network module is reusable and an environment module is not.

**Variables and outputs are the module's API** (Day 65). Nothing else is reachable, so designing that interface is the real work.

### Safety

**`plan` before `apply`, always, and read the symbols.** `-/+ forces replacement` on a stateful resource is the moment to stop (Day 61).

**`prevent_destroy` on anything holding data** — a database, a state bucket. An accidental destroy errors instead of proceeding.

**Preconditions for anything a variable cannot express.** The workspace guard is the example here.

**`terraform plan -detailed-exitcode` on a schedule** to detect drift (Day 64).

### State

**Remote, encrypted, versioned, locked.** Day 64's bucket has all four, and versioning is the only real undo.

**Never commit state or tfvars.** Both hold secrets. `.gitignore` covers `*.tfstate*` and `*.tfvars` with an exception for `*.tfvars.example`.

**A `moved` block rather than `terraform state mv`.** It is committed and travels with the code.

### Versions

**Pin everything** — `required_version`, provider versions, module versions, and `.terraform.lock.hcl` committed. An unpinned dependency is Day 45's `latest` problem with infrastructure blast radius.

### Cost

**`default_tags` on the provider** so nothing is untagged, which makes cost attribution and orphan-hunting possible.

**Name the deliberate compromises.** `single_nat_gateway = true` with a comment saying it is not production advice, the way devboard's `vpc.tf` does. A cost trade-off recorded in a comment is a decision; the same line with no comment is a bug someone will eventually "fix" and triple the bill.

**Destroy learning environments.** This capstone ran for about 90 minutes across three environments — roughly $1.20. The same thing left for a month is around $250.

### Where this goes next

The gap between this and devboard's `mega-project` config is instructive. That one adds a **bootstrap layer** for the state bucket, **Pod Identity modules** so workloads get IAM roles without stored credentials, **Secrets Manager** for the database password, and a `.tflint.hcl`. It also uses one config rather than workspaces, because the environments there differ structurally.

The natural next step is CI: `terraform plan` on a pull request, posting the plan as a comment, and `terraform apply` of the **saved plan** on merge (Day 61's `-out=tfplan`). That is Day 48's pipeline shape, with infrastructure as the artefact.

---

## Task 7: Destroying everything

```
devops@testvm:~/day-67/terraform$ for ws in prod staging dev; do
>   terraform workspace select "$ws"
>   terraform destroy -auto-approve
> done

Destroy complete! Resources: 21 destroyed.
Destroy complete! Resources: 16 destroyed.
Destroy complete! Resources: 12 destroyed.
```

**Each workspace destroys only its own resources** — separate state, separate reality.

```
devops@testvm:~/day-67/terraform$ terraform workspace select default
devops@testvm:~/day-67/terraform$ terraform workspace delete dev
Deleted workspace "dev"!
```

A workspace cannot be deleted while it holds resources, and you cannot delete the one you are in. Both are sensible guards.

```
devops@testvm:~$ aws ec2 describe-vpcs --region us-west-2 --filters "Name=tag:Project,Values=devboard" --query 'Vpcs[].VpcId'
[]
devops@testvm:~$ aws ec2 describe-nat-gateways --region us-west-2 --filter "Name=state,Values=available" --query 'NatGateways[]' --output text
devops@testvm:~$ aws ec2 describe-addresses --region us-west-2 --query 'Addresses[].PublicIp'
[]
```

VPCs, NAT gateways and Elastic IPs all clear. **Unassociated Elastic IPs are the sneaky one** — they cost money precisely when they are *not* attached to anything.

---

## Files in this folder

| Path | What it is |
|---|---|
| `terraform/main.tf` | The env-config map, workspace guard, module calls |
| `terraform/modules/network/` | VPC with derived subnets and an optional NAT gateway |
| `terraform/modules/compute/` | Security group with `for_each` rules, instances |
| `terraform/outputs.tf` | Workspace, resolved config, summary line |

---

## What I learned

**1. Workspaces share a backend, which means they are not real isolation.** Separate state files, one bucket, one set of credentials. Fine for environments that differ only in sizing; wrong for anything where production needs a genuine boundary — that means separate accounts and separate configs.

**2. A precondition turns a confusing null-dereference into a clear instruction.** Running in the `default` workspace would otherwise fail with "attempt to get attribute from null value" somewhere deep in a module. Eight lines turn it into a message that says which command to run.

**3. Putting every environment difference in one map is what makes the config reviewable.** Instance size, AZ count, NAT, allowed CIDRs — all in one block, so "prod is the only one not open to the world" is visible at a glance rather than scattered across three directories.

**Two extras:**

- `count = var.enabled ? 1 : 0` makes a whole resource optional, which is how dev skips a $33/month NAT gateway from the same code that gives prod one.
- Non-overlapping CIDRs per environment cost nothing to choose now and cannot be fixed later without a rebuild.
