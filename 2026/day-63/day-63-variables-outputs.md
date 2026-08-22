# Day 63 – Variables, Outputs, Data Sources and Expressions

Config in `terraform/` in this folder. Day 62's config with every hardcoded value pulled out.

---

## Task 1: Extracting variables

Day 62 had `10.0.0.0/16`, `t3.micro` and `us-west-2` written directly into resources. That config can build exactly one thing.

**`terraform/variables.tf`** — every type Terraform supports:

```hcl
variable "region" {
  description = "AWS region to deploy into"
  type        = string
  default     = "us-west-2"
}

variable "environment" {
  description = "Environment name"
  type        = string

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be one of: dev, staging, prod."
  }
}

variable "instance_count" {
  type    = number
  default = 1

  validation {
    condition     = var.instance_count > 0 && var.instance_count <= 5
    error_message = "instance_count must be between 1 and 5."
  }
}

variable "allowed_cidrs" {
  type    = list(string)
  default = ["0.0.0.0/0"]
}

variable "extra_tags" {
  type    = map(string)
  default = {}
}

variable "backup" {
  type = object({
    enabled        = bool
    retention_days = number
  })
  default = {
    enabled        = false
    retention_days = 7
  }
}
```

**`environment` deliberately has no default.** Terraform prompts for it if it is missing, which is right for a value that must be a conscious choice — a default of `"dev"` would let someone forget and deploy dev config to a prod account.

**`validation` blocks catch mistakes at plan time:**

```
devops@testvm:~/day-63/terraform$ terraform plan -var="environment=produciton"

Error: Invalid value for variable

  on variables.tf line 13:
  13: variable "environment" {

environment must be one of: dev, staging, prod.
```

Caught before a single API call. Without it, the typo would build a complete parallel environment named `produciton` and nobody would notice for a week.

`can(cidrhost(var.vpc_cidr, 0))` on the CIDR is a neat pattern — `can()` returns true if an expression evaluates without error, so it validates the format by trying to use it.

**Object types document their own shape.** Passing a `backup` value missing `retention_days` is a plan-time error, not a runtime surprise.

---

## Task 2: Variable files and precedence

Two example files, `dev.tfvars.example` and `prod.tfvars.example`:

```hcl
# dev
environment       = "dev"
instance_type     = "t3.micro"
instance_count    = 1
enable_monitoring = false

# prod
environment       = "prod"
vpc_cidr          = "10.10.0.0/16"
instance_count    = 3
enable_monitoring = true
allowed_cidrs     = ["10.0.0.0/8", "192.168.0.0/16"]
```

```
devops@testvm:~/day-63/terraform$ terraform plan -var-file=dev.tfvars
devops@testvm:~/day-63/terraform$ terraform plan -var-file=prod.tfvars
```

**One config, two environments.** No duplicated directories to keep in sync.

**Note the `.example` suffix.** The `.gitignore` excludes `*.tfvars` because that is where credentials end up, and these are committed as templates — the same `.env.example` pattern from Day 33.

### Precedence, lowest to highest

1. Variable `default`
2. `TF_VAR_name` environment variables
3. `terraform.tfvars`, then `*.auto.tfvars` alphabetically
4. `-var-file=` on the command line
5. `-var=` on the command line

Later wins:

```
devops@testvm:~/day-63/terraform$ terraform plan -var-file=prod.tfvars -var="instance_count=1"
  # instance_count = 1, not 3
```

**`terraform.tfvars` is loaded automatically** — no flag needed, which is convenient and occasionally surprising. A leftover `terraform.tfvars` silently overriding a default has caught me out.

**`TF_VAR_` is how CI passes secrets:**

```
devops@testvm:~$ export TF_VAR_db_password="$DB_PASSWORD"
devops@testvm:~$ terraform apply
```

The value never appears in a file or in shell history, which is Day 44's secrets reasoning applied here.

---

## Task 3: Outputs

```hcl
output "instance_urls" {
  description = "Ready-to-click URLs"
  value       = [for ip in aws_instance.web[*].public_ip : "http://${ip}"]
}

output "account_id" {
  value     = data.aws_caller_identity.current.account_id
  sensitive = true
}

output "summary" {
  value = format(
    "%s: %d instance(s) of %s across %d AZs in %s",
    local.name_prefix,
    var.instance_count,
    local.effective_instance_type,
    length(local.azs),
    data.aws_region.current.name,
  )
}
```

```
devops@testvm:~/day-63/terraform$ terraform apply -var-file=dev.tfvars

Outputs:

account_id = <sensitive>
effective_instance_type = "t3.micro"
instance_public_ips = [
  "44.238.114.92",
]
instance_urls = [
  "http://44.238.114.92",
]
subnet_cidrs = [
  "10.0.0.0/24",
  "10.0.1.0/24",
]
summary = "devboard-dev: 1 instance(s) of t3.micro across 2 AZs in us-west-2"
vpc_id = "vpc-0a3f91c4d2e58b1a6"
```

**`sensitive = true` hides it from CLI output — and only from CLI output.**

```
devops@testvm:~/day-63/terraform$ terraform output account_id
381492154712

devops@testvm:~/day-63/terraform$ grep -o '"account_id".\{0,60\}' terraform.tfstate
"account_id": { "value": "381492154712", "type": "string", "sensitive": true
```

`terraform output <name>` prints it, and it is plain text in state. Day 61's point again: `sensitive` is a display convenience, not protection.

`-raw` and `-json` are what make outputs scriptable:

```
devops@testvm:~/day-63/terraform$ IP=$(terraform output -raw instance_public_ips | jq -r '.[0]')
devops@testvm:~/day-63/terraform$ terraform output -json | jq -r '.summary.value'
devboard-dev: 1 instance(s) of t3.micro across 2 AZs in us-west-2
```

The devboard bootstrap config uses exactly this to generate its backend config:

```
terraform output -raw backend_hcl > ../backend.hcl
```

Outputs also feed **other configurations** through `terraform_remote_state`, which is how a networking config hands its VPC ID to an application config.

---

## Task 4: Data sources

```hcl
data "aws_availability_zones" "available" {
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

data "aws_caller_identity" "current" {}

data "aws_region" "current" {}

data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }
}
```

**`resource` creates and owns; `data` only reads.** Deleting a data source block deletes nothing.

`aws_caller_identity` is the most useful of these — it gives the account ID for building ARNs without hardcoding it:

```hcl
"arn:aws:secretsmanager:${var.region}:${data.aws_caller_identity.current.account_id}:secret:devboard/*"
```

That exact line is in devboard's `pod-identity.tf`. Hardcoding an account ID makes a config work in one account only, which defeats the point.

**Data sources are read during plan**, so a resource depending on one waits for it. And a data source referencing something that does not exist yet is a common failure — reading a security group created in the same apply fails, because the read happens at plan time. The fix is a direct resource reference instead.

---

## Task 5: Locals

```hcl
locals {
  name_prefix = "${var.project}-${var.environment}"

  common_tags = merge(
    {
      Project     = var.project
      Environment = var.environment
      ManagedBy   = "terraform"
    },
    var.extra_tags,
  )

  effective_instance_type = var.environment == "prod" ? "t3.medium" : var.instance_type

  azs = slice(data.aws_availability_zones.available.names, 0, 2)

  public_subnet_cidrs = [
    for i in range(length(local.azs)) : cidrsubnet(var.vpc_cidr, 8, i)
  ]
}
```

**Variables are inputs; locals are computed values.** A local cannot be set from outside, which makes it right for anything derived.

**`name_prefix` is the highest-value one.** `${local.name_prefix}-vpc` appears everywhere, so changing the naming convention is a one-line edit rather than a search and replace across every resource.

**`merge()` for tags** lets callers add their own without losing the mandatory ones.

**A local can reference a data source**, which a variable's `default` cannot. That is why `azs` is a local.

---

## Task 6: Functions and conditionals

### `cidrsubnet` — the one worth knowing

```hcl
public_subnet_cidrs = [
  for i in range(length(local.azs)) : cidrsubnet(var.vpc_cidr, 8, i)
]
```

```
subnet_cidrs = [
  "10.0.0.0/24",
  "10.0.1.0/24",
]
```

`cidrsubnet(prefix, newbits, netnum)` carves a subnet out of a larger block. Adding 8 bits to a `/16` gives `/24`, and `netnum` picks which one.

**This is Day 15's subnetting, automated.** Switching `vpc_cidr` to `10.10.0.0/16` in `prod.tfvars` regenerates every subnet automatically:

```
devops@testvm:~/day-63/terraform$ terraform plan -var-file=prod.tfvars | grep cidr_block
      + cidr_block = "10.10.0.0/24"
      + cidr_block = "10.10.1.0/24"
```

No hardcoded subnet list to keep in sync, and no arithmetic done by hand.

### Conditional

```hcl
effective_instance_type = var.environment == "prod" ? "t3.medium" : var.instance_type
```

```
devops@testvm:~/day-63/terraform$ terraform plan -var-file=prod.tfvars | grep instance_type
      + instance_type = "t3.medium"
```

`prod.tfvars` says `t3.small` and the conditional overrode it — a floor that a tfvars typo cannot go below.

### `count` vs `for_each`

Both are here, deliberately:

```hcl
resource "aws_instance" "web" {
  count = var.instance_count
  ...
}

resource "aws_vpc_security_group_ingress_rule" "http" {
  for_each = toset(var.allowed_cidrs)
  cidr_ipv4 = each.value
  ...
}
```

**The difference matters and it bites.** `count` indexes by position, so resources are `aws_instance.web[0]`, `[1]`, `[2]`. Removing the **first** item from a list shifts everything down, and Terraform destroys and recreates every resource after it.

`for_each` keys by value: `aws_vpc_security_group_ingress_rule.http["10.0.0.0/8"]`. Removing one leaves the others untouched.

```
# with count, removing allowed_cidrs[0]:
  - aws_vpc_security_group_ingress_rule.http[0] destroyed
  ~ aws_vpc_security_group_ingress_rule.http[1] replaced   # just shifted position
  - aws_vpc_security_group_ingress_rule.http[2] destroyed

# with for_each:
  - aws_vpc_security_group_ingress_rule.http["10.0.0.0/8"] destroyed
  # the others are not mentioned
```

**Rule: `count` for "N identical things", `for_each` for "one per item in a set".** Instances are interchangeable so `count` is fine; rules have identity so `for_each` is correct.

### Other functions used

| Function | Purpose |
|---|---|
| `merge(a, b)` | Combine maps, b wins on conflict |
| `slice(list, 0, 2)` | Take the first two AZs |
| `toset(list)` | List to set, required by `for_each` |
| `format(...)` | printf-style string building |
| `range(n)` | `[0, 1, ... n-1]` for comprehensions |
| `can(expr)` | True if the expression evaluates — for validation |
| `try(a, b)` | First value that works, else the fallback |

`terraform console` is the fastest way to experiment:

```
devops@testvm:~/day-63/terraform$ terraform console
> cidrsubnet("10.0.0.0/16", 8, 5)
"10.0.5.0/24"
> [for i in range(3) : cidrsubnet("172.16.0.0/12", 12, i)]
[
  "172.16.0.0/24",
  "172.16.1.0/24",
  "172.16.2.0/24",
]
```

---

## Files in this folder

| Path | What it is |
|---|---|
| `terraform/variables.tf` | Every type, with validation blocks |
| `terraform/locals.tf` | `name_prefix`, tag merge, conditional, `cidrsubnet` loop |
| `terraform/data.tf` | AZs, caller identity, region, AMI |
| `terraform/main.tf` | Same infrastructure as Day 62, fully parameterised |
| `terraform/outputs.tf` | Lists, comprehensions, `sensitive`, `format` |
| `terraform/dev.tfvars.example` | Small, cheap, permissive |
| `terraform/prod.tfvars.example` | Bigger, monitored, restricted CIDRs |

---

## What I learned

**1. `count` and `for_each` differ in how they identify resources, and it shows up as unnecessary destruction.** Removing an item from a `count` list shifts every index after it, so Terraform recreates resources that did not change. `for_each` keys by value and touches only what moved. Use `count` for identical replicas, `for_each` for anything with identity.

**2. `validation` blocks catch typos before any API call.** `-var="environment=produciton"` failed at plan time. Without it, that builds a complete parallel environment nobody notices.

**3. `sensitive = true` hides an output from the CLI and nothing else.** `terraform output account_id` prints it and the state file holds it in plain text. Day 61's lesson again — real protection is encrypted remote state and access control.

**Two extras:**

- `cidrsubnet()` turns Day 15's subnetting into a function. Change the VPC CIDR and every subnet recalculates.
- `terraform console` evaluates expressions against real state, which is far faster than a plan cycle when working out what a function does.
